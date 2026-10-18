-- Same-clock check: each sched_switch perf sample (session 1) for req-dispatch(898 in cap2 utid=2)
-- vs the nearest sched_switch ftrace event with prev_pid=988; report offset distribution.
WITH s AS (SELECT ps.id pid_sample,ps.ts ps_ts,ps.callsite_id
           FROM perf_sample ps WHERE ps.perf_session_id=1 AND ps.utid=2),
e AS (SELECT e.id,e.ts,e.cpu FROM ftrace_event e WHERE e.name='sched_switch'
      AND CAST(EXTRACT_ARG(e.arg_set_id,'prev_pid') AS INTEGER)=988)
SELECT COUNT(*) n,
  SUM(CASE WHEN ABS(s.ps_ts-e.ts)<=0 THEN 1 ELSE 0 END) exact0,
  SUM(CASE WHEN ABS(s.ps_ts-e.ts)<=1000 THEN 1 ELSE 0 END) le_1us,
  SUM(CASE WHEN ABS(s.ps_ts-e.ts)<=10000 THEN 1 ELSE 0 END) le_10us,
  MIN(s.ps_ts-e.ts) min_off, MAX(s.ps_ts-e.ts) max_off
FROM s JOIN e ON e.id=(SELECT id FROM e e2 WHERE e2.cpu IS NOT NULL ORDER BY ABS(e2.ts-s.ps_ts) LIMIT 1);
