-- 20-jitter-cycles.sql
-- Collapse high-CPU 1 s buckets into episodes, so the period and duty cycle of
-- the "every few seconds" burst can be measured instead of eyeballed.
-- Set spike_cpu_ms from the C1 baseline (e.g. baseline + 2..3x).
--
-- FIX r1: numbering happens AFTER filtering to spike buckets. The old order
-- (ROW_NUMBER over all buckets, then WHERE spike=1) merged separate spikes
-- separated by quiet buckets into one episode.
--
-- FIX r2: a sched_slice is split by INTERSECTION with each 1 s bucket. It is
-- NOT charged entirely to the bucket containing s.ts. A Running slice from
-- 900 ms to 1100 ms (dur=200 ms) contributes 100 ms to bucket 0 and 100 ms to
-- bucket 1; with a 150 ms threshold it must produce NO spike. Charging the
-- full 200 ms to bucket 0 would create a false spike. This is the same
-- interval-intersection rule as v2_modify/sql/10 and v2_modify/sql/11.
--
-- Counterexamples:
--   v2_modify/validation/tests/jitter_bucket_intersection_test.sql
--   v2_modify/validation/tests/jitter_cycles_counterexample.sql
WITH RECURSIVE
params AS (
  SELECT 'worker_app' AS target_name, 100.0 AS spike_cpu_ms
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
        (SELECT CAST((end_ts - start_ts + 999999999) / 1000000000 AS INTEGER) FROM bounds)
),
cpu AS (
  SELECT
    b.start_ts + bk.bucket * 1000000000 AS ts,
    bk.bucket AS bucket_s,
    SUM(
      MIN(s.ts + s.dur, b.start_ts + (bk.bucket + 1) * 1000000000)
      - MAX(s.ts, b.start_ts + bk.bucket * 1000000000)
    ) / 1000000.0 AS cpu_ms
  FROM sched_slice s
  JOIN thread th USING (utid)
  JOIN process p USING (upid)
  CROSS JOIN bounds b
  JOIN buckets bk
    ON s.ts < b.start_ts + (bk.bucket + 1) * 1000000000
   AND s.ts + s.dur > b.start_ts + bk.bucket * 1000000000
  CROSS JOIN params q
  WHERE (p.name = q.target_name OR p.name GLOB '*/' || q.target_name)
    AND s.dur > 0
    AND s.ts < b.end_ts
  GROUP BY bk.bucket, b.start_ts
),
flagged AS (
  SELECT bucket_s, cpu_ms,
         CASE WHEN cpu_ms >= (SELECT spike_cpu_ms FROM params) THEN 1 ELSE 0 END AS spike
  FROM cpu
),
spikes AS (
  -- Filter first: only spike buckets participate in the run numbering.
  SELECT bucket_s, cpu_ms,
         bucket_s - ROW_NUMBER() OVER (ORDER BY bucket_s) AS grp
  FROM flagged
  WHERE spike = 1
)
SELECT
  (SELECT start_ts FROM bounds) + MIN(bucket_s) * 1000000000 AS ts,
  (MAX(bucket_s) - MIN(bucket_s) + 1) * 1000000000 AS dur,
  MIN(bucket_s) AS first_bucket_s,
  MAX(bucket_s) AS last_bucket_s,
  COUNT(*) AS buckets_in_episode,
  MAX(cpu_ms) AS peak_cpu_ms,
  AVG(cpu_ms) AS avg_cpu_ms
FROM spikes
GROUP BY grp
ORDER BY first_bucket_s;
-- UI: Slice Track; Timestamp=ts; Duration=dur; Name=<literal>; Pivot=<literal>.
-- LIMIT: recursive buckets cover the trace duration; >1000 s is outside the
-- intended 30-90 s windows and may hit SQLite's recursive CTE limit.
