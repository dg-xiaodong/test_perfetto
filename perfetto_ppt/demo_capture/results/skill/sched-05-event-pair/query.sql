-- E2 candidate event association, NEVER an automatic E3 root-cause verdict.
-- Prereqs: 00c schema, 00b quality, verified stream->timebase mapping and clock sync.
-- Select a real wait_id from 02. Default proof flags=0 => no asserted match.
-- Exact timestamps by default; explicit nonzero tolerance requires written justification.
-- No source-order assumption (session 0 need not be switch). No next-thread stack claim.
WITH
p AS (SELECT 213 AS utid,0 AS wait_id,
 0 AS sid,0 AS wid,
 0 AS clk,0 AS src,1000000 AS tol),
o AS (SELECT st.*,
 LEAD(id) OVER (ORDER BY ts,id) AS rid,LEAD(ts) OVER (ORDER BY ts,id) AS rts,
 LEAD(dur) OVER (ORDER BY ts,id) AS rd,LEAD(state) OVER (ORDER BY ts,id) AS rs,
 LEAD(waker_utid) OVER (ORDER BY ts,id) AS waker,
 LEAD(irq_context) OVER (ORDER BY ts,id) AS irq,
 LEAD(ts,2) OVER (ORDER BY ts,id) AS runts,
 LEAD(state,2) OVER (ORDER BY ts,id) AS runs
 FROM thread_state st WHERE utid=(SELECT utid FROM p)),
t AS (SELECT o.*,th.tid,
 CASE WHEN o.dur>0 AND rs IN ('R','R+') AND rts=o.ts+o.dur AND rd>=0
 AND runs='Running' AND runts=rts+rd THEN 1 ELSE 0 END AS complete
 FROM o JOIN thread th USING(utid) CROSS JOIN p
 WHERE o.id=p.wait_id AND o.state IN ('S','D','I')),
se AS (SELECT s.id,s.cpu FROM sched_slice s JOIN t ON s.utid=t.utid
 AND s.ts+s.dur=t.ts WHERE s.dur>0),
sg AS (SELECT COUNT(*) AS n,MIN(cpu) AS cpu FROM se),
we AS (SELECT e.id,e.ts,e.cpu,e.utid FROM ftrace_event e CROSS JOIN t CROSS JOIN p
 WHERE e.name='sched_waking' AND CAST(EXTRACT_ARG(e.arg_set_id,'pid') AS INTEGER)=t.tid
 AND e.ts BETWEEN t.rts-p.tol AND t.rts+p.tol
 AND e.utid=t.waker AND e.ts>=t.ts AND e.ts<=t.runts),
wg AS (SELECT COUNT(*) AS n,MIN(id) AS id,MIN(ts) AS ts,MIN(cpu) AS cpu,MIN(utid) AS utid FROM we),
sc AS (SELECT s.*,
 (SELECT COUNT(*) FROM sched_slice z WHERE z.utid=t.utid AND z.cpu=s.cpu AND z.dur>0
 AND z.ts+z.dur BETWEEN s.ts-p.tol AND s.ts+p.tol) AS nearby_events
 FROM perf_sample s CROSS JOIN t CROSS JOIN p CROSS JOIN sg
 WHERE sg.n=1 AND s.utid=t.utid AND s.cpu=sg.cpu AND s.perf_session_id=p.sid
 AND s.ts BETWEEN t.ts-p.tol AND t.ts+p.tol),
wc AS (SELECT s.*,
 (SELECT COUNT(*) FROM ftrace_event z WHERE z.name='sched_waking' AND z.utid=s.utid AND z.cpu=s.cpu
 AND CAST(EXTRACT_ARG(z.arg_set_id,'pid') AS INTEGER)=t.tid
 AND z.ts BETWEEN s.ts-p.tol AND s.ts+p.tol) AS nearby_events
 FROM perf_sample s CROSS JOIN t CROSS JOIN p CROSS JOIN wg
 WHERE wg.n=1 AND s.utid=wg.utid AND s.cpu=wg.cpu AND s.perf_session_id=p.wid
 AND s.ts BETWEEN wg.ts-p.tol AND wg.ts+p.tol),
sagg AS (SELECT COUNT(*) AS n,MIN(id) AS id,MIN(ts) AS ts,MIN(callsite_id) AS cs,
 MAX(COALESCE(unwind_error,'')) AS err,MAX(nearby_events) AS near FROM sc),
wagg AS (SELECT COUNT(*) AS n,MIN(id) AS id,MIN(ts) AS ts,MIN(callsite_id) AS cs,
 MAX(COALESCE(unwind_error,'')) AS err,MAX(nearby_events) AS near FROM wc),
verdict AS (SELECT t.id AS wait_id,t.utid,t.ts AS sleep_start_ts,t.dur AS sleep_ns,
 t.rts AS waking_boundary_ts,t.rd AS runnable_ns,t.runts AS run_ts,t.waker AS waker_utid,t.irq AS irq_context,
 sg.cpu AS switch_cpu,wg.cpu AS waking_cpu,wg.id AS waking_event_id,
 sagg.n AS switch_candidates,wagg.n AS wake_candidates,
 sagg.id AS switch_sample_id,wagg.id AS wake_sample_id,
 sagg.ts-t.ts AS switch_offset_ns,wagg.ts-wg.ts AS wake_offset_ns,
 sagg.cs AS scs,wagg.cs AS wcs,
 CASE WHEN p.clk!=1 THEN 'CLOCK_UNVERIFIED'
 WHEN p.src!=1 OR p.sid<0 OR p.wid<0 OR p.sid=p.wid THEN 'SOURCE_UNVERIFIED'
 WHEN t.complete!=1 OR sg.n!=1 THEN 'BOUNDARY_INCOMPLETE'
 WHEN sagg.n=0 THEN 'SAMPLE_MISSING' WHEN sagg.n>1 THEN 'SAMPLE_AMBIGUOUS'
 WHEN sagg.near!=1 THEN 'EVENT_SAMPLE_AMBIGUOUS'
 WHEN sagg.cs IS NULL THEN 'STACK_MISSING' WHEN sagg.err!='' THEN 'STACK_PARTIAL'
 ELSE 'MATCH_UNIQUE' END AS switch_status,
 CASE WHEN p.clk!=1 THEN 'CLOCK_UNVERIFIED'
 WHEN p.src!=1 OR p.sid<0 OR p.wid<0 OR p.sid=p.wid THEN 'SOURCE_UNVERIFIED'
 WHEN t.complete!=1 THEN 'BOUNDARY_INCOMPLETE'
 WHEN t.irq=1 THEN 'IRQ_CONTEXT'
 WHEN t.irq IS NULL OR t.waker IS NULL OR t.waker=0 THEN 'CONTEXT_UNKNOWN'
 WHEN wg.n=0 THEN 'WAKE_EVENT_MISSING' WHEN wg.n>1 THEN 'WAKE_EVENT_AMBIGUOUS'
 WHEN wagg.n=0 THEN 'SAMPLE_MISSING' WHEN wagg.n>1 THEN 'SAMPLE_AMBIGUOUS'
 WHEN wagg.near!=1 THEN 'EVENT_SAMPLE_AMBIGUOUS'
 WHEN wagg.cs IS NULL THEN 'STACK_MISSING' WHEN wagg.err!='' THEN 'STACK_PARTIAL'
 ELSE 'MATCH_UNIQUE' END AS wake_status
 FROM t CROSS JOIN p CROSS JOIN sg CROSS JOIN wg CROSS JOIN sagg CROSS JOIN wagg)
SELECT wait_id,utid,sleep_start_ts,sleep_ns,waking_boundary_ts,runnable_ns,run_ts,
 waker_utid,irq_context,switch_cpu,waking_cpu,waking_event_id,
 switch_candidates,wake_candidates,
 CASE WHEN switch_candidates=1 THEN switch_sample_id END AS switch_sample_id,
 CASE WHEN wake_candidates=1 THEN wake_sample_id END AS wake_sample_id,
 switch_offset_ns,wake_offset_ns,switch_status,wake_status,
 CASE WHEN switch_status='MATCH_UNIQUE' THEN scs END AS switch_callsite_id,
 CASE WHEN wake_status='MATCH_UNIQUE' THEN wcs END AS wake_callsite_id,
 CASE WHEN switch_status='MATCH_UNIQUE' AND wake_status='MATCH_UNIQUE'
 THEN 'E2_EVENT_PAIR_REQUIRES_QUALITY_CHECK' ELSE 'PARTIAL_OR_UNKNOWN_NO_ROOT_CAUSE' END AS evidence
FROM verdict;
