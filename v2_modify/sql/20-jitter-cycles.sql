-- 20-jitter-cycles.sql
-- Collapse high-CPU 1 s buckets into episodes, so the period and duty cycle of
-- the "every few seconds" burst can be measured instead of eyeballed.
-- Set spike_cpu_ms from the C1 baseline (e.g. baseline + 2..3x).
--
-- FIX (r1): numbering must happen AFTER filtering to spike buckets. The old
-- order (ROW_NUMBER over all buckets, then WHERE spike=1) merged separate
-- spikes separated by quiet buckets into one episode.
--
-- Counterexample with quiet gap is in
-- validation/tests/jitter_cycles_counterexample.sql:
--   buckets 0,1 high; 2,3 low; 4,5 high -> two episodes, not one.
WITH params AS (
  SELECT 'worker_app' AS target_name, 100.0 AS spike_cpu_ms
), bounds AS (
  SELECT start_ts FROM trace_bounds
), cpu AS (
  SELECT
    CAST((s.ts - b.start_ts) / 1000000000 AS INTEGER) AS bucket_s,
    SUM(s.dur) / 1000000.0 AS cpu_ms
  FROM sched_slice s
  JOIN thread th USING (utid)
  JOIN process p USING (upid), bounds b, params q
  WHERE (p.name = q.target_name OR p.name GLOB '*/' || q.target_name)
    AND s.ts >= b.start_ts
  GROUP BY bucket_s
), flagged AS (
  SELECT bucket_s, cpu_ms,
         CASE WHEN cpu_ms >= (SELECT spike_cpu_ms FROM params) THEN 1 ELSE 0 END AS spike
  FROM cpu
), spikes AS (
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
