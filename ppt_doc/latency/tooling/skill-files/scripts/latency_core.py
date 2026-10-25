#!/usr/bin/env python3
"""TrackEvent latency.v1 evidence engine. Standard library only.
No log inference, no inferred Flow edges, no automatic critical-path/lock verdict.
Inputs are rows exported from the package's PerfettoSQL files, or synthetic test rows.
Times remain integer nanoseconds; missing evidence is never made zero-duration.
"""
from collections import defaultdict, Counter
import math

KEYS = ('run_id', 'stream_id', 'request_id')
TERMINAL = {'SUCCESS', 'ERROR', 'DROP', 'TIMEOUT', 'CANCELLED'}
BOUNDARIES = {'capture_start_in_flight', 'capture_stop_in_flight'}

def identity(e):
    k=tuple(str(e.get(x) if e.get(x) is not None else '') for x in KEYS)
    return k if all(k) else None

def overlap(ts, dur, a, b):
    if dur < 0 or b < a:
        return 0
    return max(0, min(ts+dur,b)-max(ts,a))

def union_duration(intervals):
    end=None; total=0
    for a,b in sorted(intervals):
        if b<a: raise ValueError('reversed interval')
        if end is None or a>end: total+=b-a;end=b
        elif b>end: total+=b-end;end=b
    return total

def nearest_rank(values,q):
    if not 0<q<=1: raise ValueError('q must be in (0,1]')
    if not values:return None
    v=sorted(values)
    return v[max(0,math.ceil(q*len(v))-1)]

def _int(v):
    if v is None or v in ('','[NULL]'):return None
    if isinstance(v,bool):raise ValueError('boolean is not a count/timestamp')
    if isinstance(v,float) and (not math.isfinite(v) or not v.is_integer()):raise ValueError('noninteger value')
    return int(v)

def analyze_records(events, flows, trace_bounds=None, quality_loss=False):
    """Deterministic classifier, with metric-specific and overall integrity.
    Declarations at request terminal verify observed counts, not semantic DAG completeness.
    Explicit boundary witnesses come from instrumentation, not guessed from missing events.
    """
    events=[dict(e) for e in events]
    groups=defaultdict(list);orphans=0
    for e in events:
        for n in ('ts','dur','slice_id','track_id','thread_utid','thread_dur','frame_seq',
                  'expected_stage_count','expected_queue_count','expected_link_count'):
            if n in e:e[n]=_int(e[n])
        if e.get('kind','').startswith('lat.request') or e.get('kind') in (
            'lat.stage','lat.stage.result','lat.queue','lat.send','lat.receive'):
            k=identity(e)
            if k:groups[k].append(e)
            else:orphans+=1
    by_id={e.get('slice_id'):e for e in events if e.get('slice_id') is not None}
    flow_rows=[];valid_links=defaultdict(set);bad_flow_keys=set()
    for f in flows:
        a=by_id.get(_int(f.get('slice_out')));b=by_id.get(_int(f.get('slice_in')))
        ka=identity(a) if a else None; kb=identity(b) if b else None
        status='VALID'
        if not a or not b:status='MISSING_ENDPOINT'
        elif a.get('kind')!='lat.send' or b.get('kind')!='lat.receive':status='UNRELATED_EDGE'
        elif not ka or ka!=kb:status='INVALID_IDENTITY'
        elif not a.get('link_id') or a.get('link_id')!=b.get('link_id'):status='INVALID_LINK'
        elif a['ts']>b['ts']:status='INVALID_TIME'
        elif a.get('flow_scope')=='process' and a.get('process_instance_id')!=b.get('process_instance_id'):status='INVALID_SCOPE'
        row=dict(f,status=status,identity=list(ka) if ka else None,
                 link_id=a.get('link_id') if a else None,
                 from_ts=a.get('ts') if a else None,to_ts=b.get('ts') if b else None)
        flow_rows.append(row)
        if status=='VALID':valid_links[ka].add(str(a['link_id']))
        elif status.startswith('INVALID'):
            if ka:bad_flow_keys.add(ka)
            if kb:bad_flow_keys.add(kb)
    reqs=[];stages=[];queues=[]
    for key, es in sorted(groups.items()):
        es.sort(key=lambda e:(e.get('ts',0),e.get('slice_id') or 0))
        starts=[e for e in es if e['kind']=='lat.request.begin']
        ends=[e for e in es if e['kind']=='lat.request.end']
        witnesses=[e for e in es if e['kind']=='lat.request.boundary' and e.get('boundary') in BOUNDARIES]
        invalid=[];missing=[]
        if any(e.get('contract_version')!='latency.v1' for e in es):invalid.append('CONTRACT_VERSION_MISSING_OR_UNSUPPORTED')
        if len(starts)>1:invalid.append('DUPLICATE_REQUEST_BEGIN')
        if len(ends)>1:invalid.append('DUPLICATE_REQUEST_END')
        if not starts:missing.append('REQUEST_BEGIN_MISSING')
        if not ends:missing.append('REQUEST_END_MISSING')
        a=starts[0]['ts'] if len(starts)==1 else None
        b=ends[0]['ts'] if len(ends)==1 else None
        if a is not None and b is not None and b<a:invalid.append('REVERSED_LIFECYCLE')
        outcome=ends[0].get('status','UNKNOWN') if len(ends)==1 else 'UNKNOWN'
        if ends and outcome not in TERMINAL:invalid.append('INVALID_OUTCOME')
        lifecycle=('INVALID' if invalid else 'CENSORED' if witnesses else
                   'COMPLETE' if a is not None and b is not None else 'INCOMPLETE')
        if trace_bounds and a is not None and b is not None:
            if a<trace_bounds[0] or b>trace_bounds[1]:invalid.append('OUTSIDE_TRACE_BOUNDS')
        # Each repeated stage invocation has its own stable instance ID.
        ss=[e for e in es if e['kind']=='lat.stage']; sr=[e for e in es if e['kind']=='lat.stage.result']
        per=defaultdict(list);res=defaultdict(list)
        for e in ss:per[str(e.get('stage_instance_id',''))].append(e)
        for e in sr:res[str(e.get('stage_instance_id',''))].append(e)
        for inst, values in per.items():
            if not inst:invalid.append('STAGE_INSTANCE_MISSING')
            if len(values)!=1:invalid.append('DUPLICATE_STAGE_INSTANCE')
            s=values[0];d=s.get('dur');results=res.get(inst,[]);why=[]
            if not s.get('stage_id'):invalid.append('STAGE_ID_MISSING')
            if len(results)==0:missing.append('STAGE_RESULT_MISSING');why.append('RESULT_MISSING')
            if len(results)>1:invalid.append('DUPLICATE_STAGE_RESULT')
            if d is None or d==-1:missing.append('OPEN_STAGE');why.append('OPEN_SLICE')
            elif d<0:invalid.append('NEGATIVE_STAGE_DURATION');why.append('INVALID_DURATION')
            if len(results)==1:
                if results[0].get('stage_id')!=s.get('stage_id'):invalid.append('STAGE_ID_CONFLICT')
                if results[0].get('status') not in TERMINAL:invalid.append('INVALID_STAGE_OUTCOME')
                if d is not None and d>=0 and results[0]['ts']<s['ts']+d:invalid.append('RESULT_BEFORE_STAGE_END')
            if d is not None and d>=0 and a is not None and b is not None:
                if s['ts']<a or s['ts']+d>b:invalid.append('STAGE_OUTSIDE_REQUEST')
            tc=s.get('thread_dur')
            tc=tc if s.get('thread_utid') is not None and tc is not None and tc>=0 else None
            stages.append(dict(zip(KEYS,key),stage_id=s.get('stage_id'),stage_instance_id=inst,
                ts=s['ts'],duration_ns=d if d is not None and d>=0 else None,
                attempt_id=s.get('attempt_id'),thread_utid=s.get('thread_utid'),thread_cpu_ns=tc,
                status=results[0].get('status') if len(results)==1 else 'UNKNOWN',notes=why))
        if set(res)-set(per):missing.append('STAGE_SLICE_MISSING')
        qs=[e for e in es if e['kind']=='lat.queue'];qp=Counter()
        for q in qs:
            visit=str(q.get('queue_visit_id',''));qid=str(q.get('queue_id',''));d=q.get('dur')
            if not visit or not qid:invalid.append('QUEUE_ID_MISSING')
            qp[(qid,visit)]+=1
            if d is None or d==-1:missing.append('OPEN_QUEUE')
            elif d<0:invalid.append('NEGATIVE_QUEUE_DURATION')
            elif a is not None and b is not None and (q['ts']<a or q['ts']+d>b):invalid.append('QUEUE_OUTSIDE_REQUEST')
            queues.append(dict(zip(KEYS,key),queue_id=qid,queue_visit_id=visit,ts=q['ts'],duration_ns=d if d is not None and d>=0 else None))
        if any(n>1 for n in qp.values()):invalid.append('DUPLICATE_QUEUE_VISIT')
        sends=Counter(str(e.get('link_id','')) for e in es if e['kind']=='lat.send')
        receives=Counter(str(e.get('link_id','')) for e in es if e['kind']=='lat.receive')
        if '' in sends or '' in receives:invalid.append('LINK_ID_MISSING')
        if any(n>1 for n in list(sends.values())+list(receives.values())):invalid.append('DUPLICATE_LINK_ENDPOINT')
        if sends!=receives or set(sends)!=valid_links[key]:missing.append('FLOW_EDGE_MISSING')
        if key in bad_flow_keys:invalid.append('INVALID_FLOW')
        # An actual arrow is not enough: its declared business endpoints must exist.
        send_events={str(e.get('link_id')):e for e in es if e['kind']=='lat.send'}
        receive_events={str(e.get('link_id')):e for e in es if e['kind']=='lat.receive'}
        for link in valid_links[key]:
            se=send_events.get(link,{});re=receive_events.get(link,{})
            fr=se.get('from_instance');to=se.get('to_instance')
            if not fr or not to or fr!=re.get('from_instance') or to!=re.get('to_instance'):
                missing.append('FLOW_BUSINESS_ENDPOINT_UNRESOLVED');continue
            if fr!='input' and fr not in per:invalid.append('FLOW_SOURCE_STAGE_UNKNOWN')
            if to!='output' and to not in per:invalid.append('FLOW_DEST_STAGE_UNKNOWN')
            if fr in per:
                st=per[fr][0];du=st.get('dur')
                if du is not None and du>=0 and st['ts']+du>se['ts']:invalid.append('FLOW_BEFORE_SOURCE_END')
            if to in per and per[to][0]['ts']<re['ts']:invalid.append('FLOW_AFTER_DEST_START')

        if len(ends)==1:
            for field,actual in [('expected_stage_count',len(ss)),('expected_queue_count',len(qs)),('expected_link_count',len(valid_links[key]))]:
                expected=ends[0].get(field)
                if expected is None:missing.append('DECLARATION_MISSING:'+field)
                elif expected<0:invalid.append('NEGATIVE_DECLARATION')
                elif expected!=actual:missing.append('COUNT_MISMATCH:'+field)
        integrity=('INVALID' if invalid else 'CENSORED' if witnesses else 'INCOMPLETE' if missing else 'COMPLETE')
        if invalid:lifecycle='INVALID'
        r=dict(zip(KEYS,key),integrity_status=integrity,lifecycle_status=lifecycle,
          outcome_status=outcome,e2e_ns=b-a if lifecycle=='COMPLETE' else None,
          start_ts=a,end_ts=b,quality_loss=bool(quality_loss),eligible=(integrity=='COMPLETE' and outcome=='SUCCESS' and not quality_loss and not orphans),
          reasons=sorted(set(invalid+missing)),stage_count=len(ss),queue_count=len(qs),flow_count=len(valid_links[key]),
          critical_path_status='NOT_COMPUTED')
        durations=[(s['ts'],s['ts']+s['dur']) for s in ss if s.get('dur') is not None and s['dur']>=0]
        r['stage_work_wall_sum_ns']=sum(b-a for a,b in durations)
        r['stage_wall_union_ns']=union_duration(durations)
        r['stage_overlap_ns']=r['stage_work_wall_sum_ns']-r['stage_wall_union_ns']
        # Queue sum can overlap other stages; it is NEVER summed with work into e2e.
        r['queue_wall_sum_ns']=sum(q['dur'] for q in qs if q.get('dur') is not None and q['dur']>=0)
        origin=starts[0] if len(starts)==1 else (ends[0] if len(ends)==1 else {})
        r['object_type']=origin.get('object_type','request');r['frame_seq']=origin.get('frame_seq')
        reqs.append(r)
    successes=[r['e2e_ns'] for r in reqs if r['eligible']]
    frames=defaultdict(list)
    for r in reqs:
        if r['object_type']=='frame':frames[(r['run_id'],r['stream_id'])].append(r)
    frame_summary=[];frame_intervals=[]
    for key,rs in sorted(frames.items()):
        inp=sorted((r for r in rs if r['start_ts'] is not None),key=lambda r:r['start_ts'])
        outs=sorted((r for r in rs if r['eligible']),key=lambda r:r['end_ts'])
        dt=[outs[i]['end_ts']-outs[i-1]['end_ts'] for i in range(1,len(outs))]
        inversions=sum(1 for i in range(1,len(outs)) if outs[i]['frame_seq'] is not None and outs[i-1]['frame_seq'] is not None and outs[i]['frame_seq']<outs[i-1]['frame_seq'])
        for i,d in enumerate(dt,1):
            frame_intervals.append(dict(run_id=key[0],stream_id=key[1],request_id=outs[i]['request_id'],ts=outs[i]['end_ts'],interval_ns=d))
        span=outs[-1]['end_ts']-outs[0]['end_ts'] if len(outs)>1 else 0
        input_span=inp[-1]['start_ts']-inp[0]['start_ts'] if len(inp)>1 else 0
        trace_span=trace_bounds[1]-trace_bounds[0] if trace_bounds else 0
        frame_summary.append(dict(run_id=key[0],stream_id=key[1],observed_inputs=len(inp),valid_outputs=len(outs),
            explicit_drops=sum(r['outcome_status']=='DROP' for r in rs),explicit_timeouts=sum(r['outcome_status']=='TIMEOUT' for r in rs),
            unresolved=sum(r['integrity_status']!='COMPLETE' for r in rs),adjacent_order_reversals=inversions,
            input_interval_fps=(len(inp)-1)*1e9/input_span if input_span>0 else None,
            input_window_fps=len(inp)*1e9/trace_span if trace_span>0 else None,
            output_window_fps=len(outs)*1e9/trace_span if trace_span>0 else None,
            output_timestamp_ties=sum(d==0 for d in dt),
            output_interval_fps=(len(outs)-1)*1e9/span if span>0 else None,
            gap_p50_ns=nearest_rank(dt,.5),gap_p95_ns=nearest_rank(dt,.95),gap_p99_ns=nearest_rank(dt,.99),max_gap_ns=max(dt) if dt else None,
            note='Output is application completion, NOT display presentation; gaps do not prove drops.'))
    function_groups=defaultdict(list)
    for e in events:
        kind=e.get('kind','')
        if kind in ('lat.stage','lat.function') or (kind and not kind.startswith('lat.')):
            function_groups[str(e.get('stage_id') or kind)].append(e)
    function_summary=[]
    for name,rs in sorted(function_groups.items()):
        durations=[r['dur'] for r in rs if r.get('dur') is not None and r['dur']>=0]
        function_summary.append(dict(name=name,observed=len(rs),closed_samples=len(durations),
            open_or_invalid=len(rs)-len(durations),mean_wall_ns=sum(durations)/len(durations) if durations else None,
            p50_wall_ns=nearest_rank(durations,.5),p95_wall_ns=nearest_rank(durations,.95),p99_wall_ns=nearest_rank(durations,.99),
            max_wall_ns=max(durations) if durations else None,tail_sample_warning=len(durations)<1000,
            quality_loss=bool(quality_loss),meaning='Inclusive wall duration of observed slices; not CPU time or E2E attribution'))
    req_index={tuple(r[k] for k in KEYS):r for r in reqs}
    for row in stages+queues:
        parent=req_index[tuple(row[k] for k in KEYS)]
        row['request_integrity_status']=parent['integrity_status']
    return dict(function_summary=function_summary,requests=reqs,stages=stages,queues=queues,flows=flow_rows,orphan_events=orphans,
        frame_summary=frame_summary,frame_intervals=frame_intervals,
        summary=dict(observed_requests=len(reqs),success_samples=len(successes),
          complete_requests=sum(r['integrity_status']=='COMPLETE' for r in reqs),
          integrity_counts=dict(Counter(r['integrity_status'] for r in reqs)),outcome_counts=dict(Counter(r['outcome_status'] for r in reqs)),
          p50_ns=nearest_rank(successes,.5),p95_ns=nearest_rank(successes,.95),p99_ns=nearest_rank(successes,.99),
          tail_sample_warning=len(successes)<1000,quality_loss=bool(quality_loss),
          quantile_method='nearest rank ceil(q*n); empirical only; <1000 is a warning policy, not a confidence test'))
