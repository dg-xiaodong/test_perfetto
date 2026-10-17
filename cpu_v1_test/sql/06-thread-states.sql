-- Task Q3: why - is the worker Running or waiting? Adapted from skill sql/02-thread-states.sql.
WITH p AS (SELECT 185 AS target_upid, -1 AS start_ts, -1 AS end_ts),
b AS (SELECT p.target_upid,
  CASE WHEN p.start_ts>=0 THEN p.start_ts ELSE t.start_ts END AS t0,
  CASE WHEN p.end_ts>=0   THEN p.end_ts   ELSE t.end_ts   END AS t1
  FROM p CROSS JOIN trace_bounds t),
cut AS (
  SELECT th.utid, th.tid, th.name AS thread_name, st.state,
         MIN(st.ts + st.dur, b.t1) - MAX(st.ts, b.t0) AS dur_ns
  FROM thread_state st JOIN thread th USING (utid) CROSS JOIN b
  WHERE th.upid = b.target_upid AND st.dur > 0
    AND st.ts < b.t1 AND st.ts + st.dur > b.t0
)
SELECT utid, tid, thread_name, state,
       COUNT(*) AS intervals,
       ROUND(SUM(dur_ns)/1e6, 1) AS duration_ms,
       ROUND(MAX(dur_ns)/1e6, 3) AS max_single_interval_ms
FROM cut GROUP BY utid, tid, thread_name, state
ORDER BY tid, duration_ms DESC;
