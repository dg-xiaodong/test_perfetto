-- Offset between sched_switch perf sample ts (session 1) and the ftrace sched_switch event ts
-- with the same prev tid, matched by exact event CPU and nearest time (reporting the delta).
WITH s AS (SELECT ps.id,ps.ts,ps.cpu FROM perf_sample ps WHERE ps.perf_session_id=1),
e AS (SELECT fe.id,fe.ts,fe.cpu,CAST(EXTRACT_ARG(fe.arg_set_id,'prev_pid') AS INTEGER) prev
      FROM ftrace_event fe WHERE fe.name='sched_switch'
      AND CAST(EXTRACT_ARG(fe.arg_set_id,'prev_pid') AS INTEGER) IN (977,987,988,994,995,996))
SELECT s.id, (SELECT ts FROM e WHERE e.prev=(SELECT tid FROM thread WHERE utid=(SELECT utid FROM perf_sample WHERE id=s.id))
     AND e.cpu=s.cpu ORDER BY ABS(e.ts-s.ts) LIMIT 1) - s.ts AS off_ns
FROM s WHERE s.id IN (SELECT id FROM perf_sample WHERE perf_session_id=1 ORDER BY ts LIMIT 400);
