-- Task Q2: shape of one spike in 50 ms buckets. Adapted from skill sql/05-cpu-time-buckets.sql
-- with target_upid + explicit window starting 1 s before tick idx0 (window from fixture log).
WITH RECURSIVE
params AS (SELECT 185 AS target_upid, 41000138186300 AS start_ts, 41001538186300 AS end_ts, 50000000 AS bucket_ns),
bounds AS (SELECT p.target_upid, p.start_ts, p.end_ts, p.bucket_ns FROM params p),
buckets(bucket) AS (
  SELECT 0 UNION ALL SELECT bucket + 1 FROM buckets
  WHERE bucket + 1 < (SELECT CAST((end_ts - start_ts + bucket_ns - 1)/bucket_ns AS INTEGER) FROM bounds)
)
SELECT th.name AS thread_name, bk.bucket AS bucket_index,
       ROUND((b.start_ts + bk.bucket*b.bucket_ns)/1e9, 3) AS bucket_start_s_uptime,
       ROUND(SUM(MIN(s.ts+s.dur, b.start_ts+(bk.bucket+1)*b.bucket_ns)
               - MAX(s.ts, b.start_ts+bk.bucket*b.bucket_ns))/1e6, 2) AS cpu_ms,
       COUNT(*) AS overlapping_slices
FROM sched_slice s JOIN thread th USING(utid)
CROSS JOIN bounds b JOIN buckets bk
  ON s.ts < b.start_ts+(bk.bucket+1)*b.bucket_ns AND s.ts+s.dur > b.start_ts+bk.bucket*b.bucket_ns
WHERE th.upid = b.target_upid AND s.dur > 0
  AND s.ts < b.end_ts AND s.ts+s.dur > b.start_ts
GROUP BY th.utid, th.name, bk.bucket ORDER BY bk.bucket, cpu_ms DESC;
