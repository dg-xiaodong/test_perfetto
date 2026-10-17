-- Counterexample for sql/20-jitter-cycles.sql (r2 bucket intersection).
-- Case A: one Running slice from 900 ms to 1100 ms, dur=200 ms.
--   Correct: bucket0=100 ms, bucket1=100 ms; threshold=150 ms -> no spike.
--   Old (full dur at s.ts): bucket0=200 ms -> false spike.
-- Case B: 900-1250 ms, dur=350 ms.
--   Correct: bucket0=100 ms, bucket1=250 ms -> bucket1 spike.
--   Old: bucket0=350 ms -> spike in the wrong bucket.
WITH RECURSIVE
params AS (SELECT 1000000000 AS bucket_ns, 150.0 AS threshold_ms),
buckets(bucket) AS (
  SELECT 0
  UNION ALL
  SELECT bucket + 1 FROM buckets WHERE bucket < 2
),
samples(name, ts, dur) AS (
  VALUES
    ('A_200ms_900_1100', 900000000, 200000000),
    ('B_350ms_900_1250', 900000000, 350000000)
),
old_attr AS (
  SELECT s.name, s.ts, s.dur,
         CAST(s.ts / (SELECT bucket_ns FROM params) AS INTEGER) AS bucket,
         s.dur / 1000000.0 AS ms,
         CASE WHEN s.dur / 1000000.0 >= (SELECT threshold_ms FROM params)
              THEN 1 ELSE 0 END AS spike
  FROM samples s
),
new_attr AS (
  SELECT s.name, bk.bucket,
         (MIN(s.ts + s.dur, (bk.bucket + 1) * p.bucket_ns)
          - MAX(s.ts, bk.bucket * p.bucket_ns)) / 1000000.0 AS ms,
         CASE WHEN (MIN(s.ts + s.dur, (bk.bucket + 1) * p.bucket_ns)
                    - MAX(s.ts, bk.bucket * p.bucket_ns)) / 1000000.0
                   >= p.threshold_ms
              THEN 1 ELSE 0 END AS spike
  FROM samples s
  CROSS JOIN buckets bk
  CROSS JOIN params p
  WHERE s.ts < (bk.bucket + 1) * p.bucket_ns
    AND s.ts + s.dur > bk.bucket * p.bucket_ns
)
SELECT 'OLD' AS logic, name, bucket, ms, spike
FROM old_attr
UNION ALL
SELECT 'FIXED' AS logic, name, bucket, ms, spike
FROM new_attr
ORDER BY name, logic, bucket;

WITH RECURSIVE
params AS (SELECT 1000000000 AS bucket_ns, 150.0 AS threshold_ms),
buckets(bucket) AS (
  SELECT 0
  UNION ALL
  SELECT bucket + 1 FROM buckets WHERE bucket < 2
),
samples(name, ts, dur) AS (
  VALUES
    ('A_200ms_900_1100', 900000000, 200000000),
    ('B_350ms_900_1250', 900000000, 350000000)
),
old_attr AS (
  SELECT s.name,
         CASE WHEN s.dur / 1000000.0 >= (SELECT threshold_ms FROM params)
              THEN 1 ELSE 0 END AS spike
  FROM samples s
),
new_attr AS (
  SELECT s.name,
         MAX(CASE WHEN (MIN(s.ts + s.dur, (bk.bucket + 1) * p.bucket_ns)
                       - MAX(s.ts, bk.bucket * p.bucket_ns)) / 1000000.0
                      >= p.threshold_ms
                  THEN 1 ELSE 0 END) AS spike
  FROM samples s
  CROSS JOIN buckets bk
  CROSS JOIN params p
  WHERE s.ts < (bk.bucket + 1) * p.bucket_ns
    AND s.ts + s.dur > bk.bucket * p.bucket_ns
  GROUP BY s.name
)
SELECT 'A_200ms' AS case_name,
       (SELECT spike FROM old_attr WHERE name = 'A_200ms_900_1100') AS old_spike,
       (SELECT spike FROM new_attr WHERE name = 'A_200ms_900_1100') AS fixed_spike
UNION ALL
SELECT 'B_350ms',
       (SELECT spike FROM old_attr WHERE name = 'B_350ms_900_1250'),
       (SELECT spike FROM new_attr WHERE name = 'B_350ms_900_1250');
