-- 10-cpu-thread-buckets.sql
-- Per-thread CPU time in 100 ms buckets for the target process.
-- Purpose: see whether the "CPU rise every few seconds" is a real, periodic,
-- per-thread burst, and which thread carries it.
-- UI: Counter Track; Timestamp=bucket_100ms (or ts_ns below); Value=cpu_ms; Pivot=thread.
-- Fill target_name, then verify the resolved UPID against 00-inventory.sql.
WITH params AS (
  SELECT 'worker_app' AS target_name
), target_threads AS (
  SELECT th.utid, th.tid, th.name AS thread_name, p.upid, p.pid, p.name AS process_name
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
  t.upid,
  t.pid,
  b.start_ts + CAST((s.ts - b.start_ts) / 100000000 AS INTEGER) * 100000000 AS ts_ns,
  CAST((s.ts - b.start_ts) / 100000000 AS INTEGER) AS bucket_100ms,
  SUM(s.dur) / 1000000.0 AS cpu_ms,
  COUNT(*) AS on_cpu_slices
FROM sched_slice s
JOIN target_threads t USING (utid)
CROSS JOIN bounds b
WHERE s.ts >= b.start_ts
GROUP BY t.utid, t.tid, t.thread_name, t.upid, t.pid, ts_ns, bucket_100ms
ORDER BY bucket_100ms, cpu_ms DESC;
