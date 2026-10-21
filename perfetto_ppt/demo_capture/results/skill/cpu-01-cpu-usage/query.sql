-- Per-process/thread on-CPU duration in chosen trace window, ns half-open [start,end).
-- Set target_upid using 00-inventory. -1 returns no rows; -1 times mean bounds.
-- The sum of thread CPU times may exceed wall-clock for multi-core processes.
WITH p AS (
  SELECT 179 AS target_upid, -1 AS start_ts, -1 AS end_ts
), b AS (
  SELECT p.target_upid,
    CASE WHEN p.start_ts>=0 THEN p.start_ts ELSE tb.start_ts END AS t0,
    CASE WHEN p.end_ts>=0 THEN p.end_ts ELSE tb.end_ts END AS t1
  FROM p CROSS JOIN trace_bounds tb
), clipped AS (
  SELECT th.utid,th.tid,th.name AS thread_name, s.cpu,
         MIN(s.ts+s.dur,b.t1)-MAX(s.ts,b.t0) AS running_ns
  FROM sched_slice s JOIN thread th USING(utid) CROSS JOIN b
  WHERE th.upid=b.target_upid AND s.dur>0 AND s.ts<b.t1
    AND s.ts+s.dur>b.t0
)
SELECT utid,tid,thread_name,
       ROUND(SUM(running_ns)/1e6,3) AS cpu_ms,
       COUNT(*) AS clipped_slices
FROM clipped GROUP BY utid,tid,thread_name ORDER BY cpu_ms DESC;
