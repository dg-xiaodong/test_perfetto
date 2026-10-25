-- 06-cpu-spike-episodes.sql
-- Provenance: perfetto-memory-debugging v1.0.2 sql/12-cpu-spike-episodes.sql
-- Frozen commit 0fa17e08eb8b93a9944232e380c7ddb39666fcf2.
-- CPU time summed over all threads in one UPID, per bucket; threshold in ms.
-- Missing/quiet buckets BREAK episodes. Default target_upid=-1 returns no rows.
-- UI Slice Track: ts (ns), dur (ns), choose literal name in the UI if required.
WITH RECURSIVE
params AS (
  SELECT 4 AS target_upid, -1 AS start_ts, -1 AS end_ts,
         200000000 AS bucket_ns, 150.0 AS threshold_ms
),
bounds AS (
  SELECT p.target_upid,
         CASE WHEN p.start_ts >= 0 THEN p.start_ts ELSE t.start_ts END AS start_ts,
         CASE WHEN p.end_ts >= 0 THEN p.end_ts ELSE t.end_ts END AS end_ts,
         p.bucket_ns, p.threshold_ms
  FROM params p CROSS JOIN trace_bounds t WHERE p.bucket_ns > 0
),
buckets(bucket) AS (
  SELECT 0 UNION ALL SELECT bucket + 1 FROM buckets
  WHERE bucket + 1 <
    (SELECT CAST((end_ts - start_ts + bucket_ns - 1) / bucket_ns AS INTEGER) FROM bounds)
),
cpu AS (
  SELECT bk.bucket AS bucket_index,
         SUM(MIN(s.ts + s.dur, b.start_ts + (bk.bucket+1)*b.bucket_ns)
           - MAX(s.ts, b.start_ts + bk.bucket*b.bucket_ns)) / 1000000.0 AS cpu_ms
  FROM sched_slice s JOIN thread th USING (utid)
  CROSS JOIN bounds b JOIN buckets bk
    ON s.ts < b.start_ts + (bk.bucket+1)*b.bucket_ns
   AND s.ts + s.dur > b.start_ts + bk.bucket*b.bucket_ns
  WHERE th.upid=b.target_upid AND s.dur > 0
    AND s.ts < b.end_ts AND s.ts + s.dur > b.start_ts
  GROUP BY bk.bucket
),
spikes AS (
  SELECT bucket_index, cpu_ms,
         bucket_index - ROW_NUMBER() OVER (ORDER BY bucket_index) AS grp
  FROM cpu WHERE cpu_ms >= (SELECT threshold_ms FROM bounds)
)
SELECT b.start_ts + MIN(s.bucket_index)*b.bucket_ns AS ts,
       (MAX(s.bucket_index)-MIN(s.bucket_index)+1)*b.bucket_ns AS dur,
       MIN(s.bucket_index) AS first_bucket,
       MAX(s.bucket_index) AS last_bucket,
       COUNT(*) AS buckets_in_episode,
       MAX(s.cpu_ms) AS peak_cpu_ms, AVG(s.cpu_ms) AS avg_cpu_ms
FROM spikes s CROSS JOIN bounds b GROUP BY s.grp ORDER BY ts;
