-- 11-runnable-and-blocked.sql
-- Runqueue latency and uninterruptible sleep in 100 ms buckets.
-- "R"/"R+" = runnable but not on CPU (wakeup -> running latency).
-- "D"     = uninterruptible sleep (often I/O or memory reclaim; inspect blocked_function).
-- Purpose: separate "CPU busy" from "thread waited", which is the jitter that
-- a CPU-usage percentage alone cannot show.
WITH params AS (
  SELECT 'worker_app' AS target_name
), target_threads AS (
  SELECT th.utid, th.tid, th.name AS thread_name, p.upid, p.pid
  FROM thread th
  JOIN process p USING (upid), params
  WHERE p.name = params.target_name
     OR p.name GLOB '*/' || params.target_name
), bounds AS (
  SELECT start_ts FROM trace_bounds
)
SELECT
  t.utid,
  t.tid,
  t.thread_name,
  b.start_ts + CAST((st.ts - b.start_ts) / 100000000 AS INTEGER) * 100000000 AS ts_ns,
  CAST((st.ts - b.start_ts) / 100000000 AS INTEGER) AS bucket_100ms,
  SUM(CASE WHEN st.state = 'Running' THEN st.dur ELSE 0 END) / 1000000.0 AS running_ms,
  SUM(CASE WHEN st.state IN ('R', 'R+') THEN st.dur ELSE 0 END) / 1000000.0 AS runnable_ms,
  SUM(CASE WHEN st.state = 'D' THEN st.dur ELSE 0 END) / 1000000.0 AS d_state_ms,
  SUM(CASE WHEN st.state IN ('R', 'R+') THEN 1 ELSE 0 END) AS runnable_episodes,
  MAX(CASE WHEN st.state = 'D' THEN st.blocked_function END) AS d_blocked_function
FROM thread_state st
JOIN target_threads t USING (utid)
CROSS JOIN bounds b
WHERE st.ts >= b.start_ts
GROUP BY t.utid, t.tid, t.thread_name, ts_ns, bucket_100ms
ORDER BY bucket_100ms, runnable_ms DESC;
