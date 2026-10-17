-- Real-trace regression for the bucket intersection (sql/10 formula).
-- This does NOT use worker_app data; it uses any trace containing sched
-- slices of 90-120 ms that cross a 100 ms bucket edge.
-- Expected: total_overlap_ns == dur, diff_ns == 0 for every sampled slice.
WITH RECURSIVE
bounds AS (SELECT start_ts, end_ts FROM trace_bounds),
buckets(bucket) AS (
  SELECT 0
  UNION ALL
  SELECT bucket + 1 FROM buckets
  WHERE bucket + 1 <
        (SELECT CAST((end_ts - start_ts + 99999999) / 100000000 AS INTEGER) FROM bounds)
),
samples AS (
  SELECT s.id, s.ts, s.dur
  FROM sched_slice s, bounds b
  WHERE s.dur BETWEEN 90000000 AND 120000000
    AND s.ts >= b.start_ts
    AND s.ts < b.end_ts
    AND CAST((s.ts - b.start_ts) / 100000000 AS INTEGER)
        <> CAST((s.ts + s.dur - 1 - b.start_ts) / 100000000 AS INTEGER)
  ORDER BY s.ts
  LIMIT 5
),
overlapped AS (
  SELECT
    s.id,
    s.ts,
    s.dur,
    MIN(s.ts + s.dur, b.start_ts + (bk.bucket + 1) * 100000000)
      - MAX(s.ts, b.start_ts + bk.bucket * 100000000) AS overlap_ns
  FROM samples s
  CROSS JOIN bounds b
  JOIN buckets bk
    ON s.ts < b.start_ts + (bk.bucket + 1) * 100000000
   AND s.ts + s.dur > b.start_ts + bk.bucket * 100000000
)
SELECT id, ts, dur, SUM(overlap_ns) AS total_overlap_ns,
       SUM(overlap_ns) - dur AS diff_ns
FROM overlapped
GROUP BY id, ts, dur
ORDER BY ts;
