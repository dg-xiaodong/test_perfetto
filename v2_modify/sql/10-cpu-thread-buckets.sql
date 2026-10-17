-- 10-cpu-thread-buckets.sql
-- Per-thread CPU time in 100 ms buckets for the target process.
--
-- FIX (r1): an interval [ts, ts+dur) is split by INTERSECTION with each
-- bucket. It is NOT charged entirely to the bucket containing ts. This
-- matters for 90-120 ms sched slices/thread states that cross a 100 ms edge.
--
-- Buckets are aligned to trace_bounds.start_ts. Overlap is:
--   min(ts + dur, bucket_end) - max(ts, bucket_start)
-- and is only counted when positive.
--
-- UI: Counter Track; Timestamp=ts_ns; Value=cpu_ms; Pivot=thread_name.
-- Fill target_name; verify the resolved UPID against 00-inventory.sql.
WITH RECURSIVE
params AS (
  SELECT 'worker_app' AS target_name
),
target_threads AS (
  SELECT th.utid, th.tid, th.name AS thread_name, p.upid, p.pid, p.name AS process_name
  FROM thread th
  JOIN process p USING (upid), params
  WHERE p.name = params.target_name
     OR p.name GLOB '*/' || params.target_name
),
bounds AS (
  SELECT start_ts, end_ts FROM trace_bounds
),
buckets(bucket) AS (
  SELECT 0
  UNION ALL
  SELECT bucket + 1
  FROM buckets
  WHERE bucket + 1 <
        (SELECT CAST((end_ts - start_ts + 99999999) / 100000000 AS INTEGER) FROM bounds)
)
SELECT
  t.utid,
  t.tid,
  t.thread_name,
  t.upid,
  t.pid,
  b.start_ts + bk.bucket * 100000000 AS ts_ns,
  bk.bucket AS bucket_100ms,
  SUM(
    MIN(s.ts + s.dur, b.start_ts + (bk.bucket + 1) * 100000000)
    - MAX(s.ts, b.start_ts + bk.bucket * 100000000)
  ) / 1000000.0 AS cpu_ms,
  COUNT(*) AS overlapping_slices
FROM sched_slice s
JOIN target_threads t USING (utid)
CROSS JOIN bounds b
JOIN buckets bk
  ON s.ts < b.start_ts + (bk.bucket + 1) * 100000000
 AND s.ts + s.dur > b.start_ts + bk.bucket * 100000000
WHERE s.dur > 0
  AND s.ts < b.end_ts
GROUP BY t.utid, t.tid, t.thread_name, t.upid, t.pid, ts_ns, bucket_100ms
ORDER BY bucket_100ms, cpu_ms DESC;
-- LIMIT: the recursive bucket CTE is sized to the trace duration; >100 s
-- (1000+ buckets) can hit SQLite's recursive CTE limit. This delivery targets
-- 30-90 s windows; split longer traces.
-- Cross-check: for any single interval, SUM(cpu_ms) over its buckets must
-- equal dur; see validation/tests/bucket_overlap_test.sql.
