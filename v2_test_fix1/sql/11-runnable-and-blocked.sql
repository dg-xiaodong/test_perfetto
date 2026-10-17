-- 11-runnable-and-blocked.sql
-- Runqueue latency and uninterruptible sleep in 100 ms buckets.
-- "R"/"R+" = runnable but not on CPU (wakeup -> running latency).
-- "D"     = uninterruptible sleep (often I/O or memory reclaim; inspect blocked_function).
--
-- FIX (r1): every interval is intersected with each overlapping bucket, just
-- like sql/10. A state that starts at 95 ms with 120 ms duration contributes
-- 5 ms to bucket 0 and 100 ms + 15 ms to the following buckets; it is not
-- charged entirely to bucket 0.
--
-- UI: Counter Track; Timestamp=ts_ns; Value=running_ms/runnable_ms/d_state_ms;
-- Pivot=thread_name. runnable_overlaps counts overlaps, not distinct episodes.
WITH RECURSIVE
params AS (
  SELECT 'worker_app' AS target_name
),
target_threads AS (
  SELECT th.utid, th.tid, th.name AS thread_name, p.upid, p.pid
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
),
overlaps AS (
  SELECT
    st.utid,
    st.state,
    st.blocked_function,
    b.start_ts + bk.bucket * 100000000 AS bucket_start,
    bk.bucket AS bucket_100ms,
    MIN(st.ts + st.dur, b.start_ts + (bk.bucket + 1) * 100000000)
      - MAX(st.ts, b.start_ts + bk.bucket * 100000000) AS overlap_ns
  FROM thread_state st
  CROSS JOIN bounds b
  JOIN buckets bk
    ON st.ts < b.start_ts + (bk.bucket + 1) * 100000000
   AND st.ts + st.dur > b.start_ts + bk.bucket * 100000000
  WHERE st.dur > 0
    AND st.ts < b.end_ts
    AND st.utid IN (SELECT utid FROM target_threads)
)
SELECT
  t.utid,
  t.tid,
  t.thread_name,
  o.bucket_start AS ts_ns,
  o.bucket_100ms,
  SUM(CASE WHEN o.state = 'Running' THEN o.overlap_ns ELSE 0 END) / 1000000.0 AS running_ms,
  SUM(CASE WHEN o.state IN ('R', 'R+') THEN o.overlap_ns ELSE 0 END) / 1000000.0 AS runnable_ms,
  SUM(CASE WHEN o.state = 'D' THEN o.overlap_ns ELSE 0 END) / 1000000.0 AS d_state_ms,
  SUM(CASE WHEN o.state IN ('R', 'R+') THEN 1 ELSE 0 END) AS runnable_overlaps,
  MAX(CASE WHEN o.state = 'D' THEN o.blocked_function END) AS d_blocked_function
FROM overlaps o
JOIN target_threads t USING (utid)
GROUP BY t.utid, t.tid, t.thread_name, ts_ns, bucket_100ms
ORDER BY bucket_100ms, runnable_ms DESC;
-- LIMIT: the recursive bucket CTE is sized to the trace duration; >100 s
-- (1000+ buckets) can hit SQLite's recursive CTE limit. This delivery targets
-- 30-90 s windows; split longer traces.
-- Cross-check: SUM(running_ms + runnable_ms + d_state_ms + S/I/... buckets)
-- must be <= trace duration; see validation/tests/bucket_overlap_test.sql.
