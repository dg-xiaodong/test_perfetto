-- Synthetic test for the interval/bucket intersection used by sql/10 and 11.
-- Intervals are in ns; buckets are 100 ms.
-- Expected: every "diff_ns" is 0; 90 ms and 120 ms intervals starting at
-- 95 ms must split across the 100 ms boundary (5 ms in bucket 0, remainder
-- in later buckets), not be charged entirely to bucket 0.
WITH RECURSIVE
params AS (SELECT 100000000 AS bucket_ns),
buckets(bucket) AS (
  SELECT 0
  UNION ALL
  SELECT bucket + 1 FROM buckets WHERE bucket < 4
),
intervals(name, ts, dur) AS (
  VALUES
    ('A_90ms_cross',   95000000,  90000000),
    ('B_120ms_cross',  95000000, 120000000),
    ('C_exact_100ms', 100000000, 100000000),
    ('D_250ms_span',   50000000, 250000000),
    ('E_1ns_edge',     99999999,   1000000)
),
overlapped AS (
  SELECT
    i.name,
    i.ts,
    i.dur,
    bk.bucket,
    MIN(i.ts + i.dur, (bk.bucket + 1) * p.bucket_ns)
      - MAX(i.ts, bk.bucket * p.bucket_ns) AS overlap_ns
  FROM intervals i
  CROSS JOIN buckets bk
  CROSS JOIN params p
  WHERE i.ts < (bk.bucket + 1) * p.bucket_ns
    AND i.ts + i.dur > bk.bucket * p.bucket_ns
)
SELECT name, bucket, overlap_ns
FROM overlapped
ORDER BY name, bucket;

WITH RECURSIVE
params AS (SELECT 100000000 AS bucket_ns),
buckets(bucket) AS (
  SELECT 0
  UNION ALL
  SELECT bucket + 1 FROM buckets WHERE bucket < 4
),
intervals(name, ts, dur) AS (
  VALUES
    ('A_90ms_cross',   95000000,  90000000),
    ('B_120ms_cross',  95000000, 120000000),
    ('C_exact_100ms', 100000000, 100000000),
    ('D_250ms_span',   50000000, 250000000),
    ('E_1ns_edge',     99999999,   1000000)
),
overlapped AS (
  SELECT
    i.name, i.dur,
    MIN(i.ts + i.dur, (bk.bucket + 1) * p.bucket_ns)
      - MAX(i.ts, bk.bucket * p.bucket_ns) AS overlap_ns
  FROM intervals i
  CROSS JOIN buckets bk
  CROSS JOIN params p
  WHERE i.ts < (bk.bucket + 1) * p.bucket_ns
    AND i.ts + i.dur > bk.bucket * p.bucket_ns
)
SELECT name, dur, SUM(overlap_ns) AS total_overlap_ns,
       SUM(overlap_ns) - dur AS diff_ns
FROM overlapped
GROUP BY name, dur
ORDER BY name;
