-- Demonstrates the old vs fixed bucket attribution for a 90 ms interval
-- starting at 95 ms. OLD: all 90 ms is charged to bucket 0. FIXED: 5 ms in
-- bucket 0 and 85 ms in bucket 1. This is the concrete 90-120 ms boundary case.
WITH RECURSIVE
params AS (SELECT 100000000 AS bucket_ns),
buckets(bucket) AS (
  SELECT 0 UNION ALL SELECT bucket + 1 FROM buckets WHERE bucket < 2
),
sample(name, ts, dur) AS (
  VALUES ('A_90ms_cross', 95000000, 90000000)
),
old_attribution AS (
  SELECT name, ts, dur,
         CAST(ts / (SELECT bucket_ns FROM params) AS INTEGER) AS old_bucket,
         dur AS old_ms
  FROM sample
),
new_attribution AS (
  SELECT s.name, bk.bucket,
         (MIN(s.ts + s.dur, (bk.bucket + 1) * p.bucket_ns)
          - MAX(s.ts, bk.bucket * p.bucket_ns)) / 1000000.0 AS new_ms
  FROM sample s CROSS JOIN buckets bk CROSS JOIN params p
  WHERE s.ts < (bk.bucket + 1) * p.bucket_ns
    AND s.ts + s.dur > bk.bucket * p.bucket_ns
)
SELECT 'OLD' AS logic, old_bucket AS bucket, old_ms / 1000000.0 AS ms
FROM old_attribution
UNION ALL
SELECT 'FIXED', bucket, new_ms FROM new_attribution
ORDER BY logic, bucket;
