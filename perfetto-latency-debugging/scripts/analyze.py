#!/usr/bin/env python3
"""Analyze a TrackEvent latency.v1 trace created by this instrumentation contract.
Not a general trace or business-log conversion entry. Preserves each SQL output.
"""
import argparse,csv,json,sys
from pathlib import Path
from run_query import run,digest
from latency_core import analyze_records
ROOT=Path(__file__).resolve().parents[1]

def read_csv(path):
    text=Path(path).read_text()
    # Older TP CLI prints column descriptors; preserve original raw output on disk.
    lines=[l for l in text.splitlines() if not l.startswith('column ') and l.strip()]
    if not lines:return []
    rows=list(csv.DictReader(lines))
    if rows and None in rows[0]:raise ValueError('unexpected TP output; inspect '+str(path))
    return [{k:(None if v in ('[NULL]','NULL') else v) for k,v in row.items()} for row in rows]

def write_csv(path,rows):
    fields=list(dict.fromkeys(k for r in rows for k in r))
    with Path(path).open('x',newline='') as f:
        if not fields:f.write('# no rows\n');return
        w=csv.DictWriter(f,fieldnames=fields);w.writeheader()
        for r in rows:w.writerow({k:json.dumps(v,ensure_ascii=False) if isinstance(v,(list,dict)) else v for k,v in r.items()})

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--tp',required=True,type=Path);p.add_argument('--trace',required=True,type=Path)
    p.add_argument('--out',required=True,type=Path);p.add_argument('--category',default='rdk.latency')
    a=p.parse_args()
    try:
        a.out.mkdir(exist_ok=False)
        exports={}
        for filename in ('00-inventory','01-events','02-flow','03-quality','04-counters'):
            dest=a.out/filename;run(a.tp,a.trace,ROOT/'sql'/(filename+'.sql'),dest,category=a.category)
            exports[filename]=read_csv(dest/'stdout.csv')
        inv=exports['00-inventory']
        if not inv or not {'start_ts','end_ts','app_slices'}<=set(inv[0]):raise ValueError('invalid inventory export')
        if int(inv[0]['app_slices'])==0:raise ValueError('NO_TRACK_EVENT: requested category has no events')
        events=exports['01-events'];flows=exports['02-flow'];stats=exports['03-quality']
        if not events or 'slice_id' not in events[0]:raise ValueError('empty/incompatible TrackEvent export')
        loss=any(r.get('severity') in ('error','data_loss') and float(r.get('value') or 0)>0 for r in stats)
        result=analyze_records(events,flows,(int(inv[0]['start_ts']),int(inv[0]['end_ts'])),quality_loss=loss)
        result['provenance']={'trace_sha256':digest(a.trace),'tp_sha256':digest(a.tp),'category':a.category,'quality_scope':'trace-global, not proven attributable to each request'}
        (a.out/'analysis.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
        for key in ('requests','stages','queues','flows','frame_summary','frame_intervals','function_summary'):
            write_csv(a.out/(key+'.csv'),result[key])
        # SQL literal table of ONLY integrity-qualified measured request intervals.
        rows=[]
        for r in result['requests']:
            if r['eligible']:
                name=' / '.join(str(r[k]) for k in ('run_id','stream_id','request_id')).replace("'","''")
                rows.append("SELECT %d AS ts,%d AS dur,'%s' AS name"%(r['start_ts'],r['e2e_ns'],name))
        (a.out/'ui-request-track.sql').write_text(('\nUNION ALL\n'.join(rows) if rows else "SELECT 0 AS ts,0 AS dur,'' AS name WHERE 0")+';\n')
        s=result['summary']
        report='# TrackEvent latency analysis\n\n'+json.dumps(s,ensure_ascii=False,indent=2)+'\n\n'
        report+='Only COMPLETE + SUCCESS + no global loss enter strict latency metrics. DROP/TIMEOUT remain separate.\n'
        report+='Critical path is NOT computed. Stage wall sum, wall union and queue sum are separate dimensions.\n'
        report+='UI SQL is a derived interval table, not new measurements or a screenshot.\n'
        (a.out/'SUMMARY.md').write_text(report)
        print(json.dumps(s,ensure_ascii=False))
        return 0
    except Exception as e:
        print('ANALYSIS_BLOCKED:',e,file=sys.stderr)
        if a.out.is_dir():(a.out/'FAILED.txt').write_text(str(e)+'\n')
        return 2
if __name__=='__main__':raise SystemExit(main())
