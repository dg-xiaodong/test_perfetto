-- Counterexample for sql/20-jitter-cycles.sql.
-- Seven 1 s buckets:
--   0,1 high; 2,3 low (quiet gap); 4,5 high; 6 low.
-- Expected: OLD logic (ROW_NUMBER over all buckets before filtering) reports
-- one merged episode; FIXED logic reports two episodes [0,1] and [4,5].
WITH sample(bucket_s, cpu_ms) AS (
  VALUES
    (0, 50.0),
    (1, 60.0),
    (2,  1.0),
    (3,  1.0),
    (4, 55.0),
    (5, 45.0),
    (6,  1.0)
),
params AS (SELECT 20.0 AS spike_cpu_ms),
flagged AS (
  SELECT bucket_s, cpu_ms,
         CASE WHEN cpu_ms >= (SELECT spike_cpu_ms FROM params) THEN 1 ELSE 0 END AS spike
  FROM sample
),
old_grouped AS (
  SELECT bucket_s, cpu_ms, spike,
         bucket_s - ROW_NUMBER() OVER (ORDER BY bucket_s) AS grp
  FROM flagged
),
old_episodes AS (
  SELECT MIN(bucket_s) AS first_bucket_s, MAX(bucket_s) AS last_bucket_s
  FROM old_grouped
  WHERE spike = 1
  GROUP BY grp
),
fixed_spikes AS (
  SELECT bucket_s, cpu_ms,
         bucket_s - ROW_NUMBER() OVER (ORDER BY bucket_s) AS grp
  FROM flagged
  WHERE spike = 1
),
fixed_episodes AS (
  SELECT MIN(bucket_s) AS first_bucket_s, MAX(bucket_s) AS last_bucket_s
  FROM fixed_spikes
  GROUP BY grp
)
SELECT 'OLD_merges' AS logic, first_bucket_s, last_bucket_s FROM old_episodes
UNION ALL
SELECT 'FIXED_splits', first_bucket_s, last_bucket_s FROM fixed_episodes
ORDER BY logic, first_bucket_s;

WITH sample(bucket_s, cpu_ms) AS (
  VALUES
    (0, 50.0), (1, 60.0), (2, 1.0), (3, 1.0),
    (4, 55.0), (5, 45.0), (6, 1.0)
),
params AS (SELECT 20.0 AS spike_cpu_ms),
flagged AS (
  SELECT bucket_s, cpu_ms,
         CASE WHEN cpu_ms >= (SELECT spike_cpu_ms FROM params) THEN 1 ELSE 0 END AS spike
  FROM sample
),
old_grouped AS (
  SELECT bucket_s, cpu_ms, spike,
         bucket_s - ROW_NUMBER() OVER (ORDER BY bucket_s) AS grp
  FROM flagged
),
old_episodes AS (
  SELECT MIN(bucket_s) AS first_bucket_s, MAX(bucket_s) AS last_bucket_s
  FROM old_grouped WHERE spike = 1 GROUP BY grp
),
fixed_spikes AS (
  SELECT bucket_s, cpu_ms,
         bucket_s - ROW_NUMBER() OVER (ORDER BY bucket_s) AS grp
  FROM flagged WHERE spike = 1
),
fixed_episodes AS (
  SELECT MIN(bucket_s) AS first_bucket_s, MAX(bucket_s) AS last_bucket_s
  FROM fixed_spikes GROUP BY grp
)
SELECT
  (SELECT COUNT(*) FROM old_episodes) AS old_episode_count,
  (SELECT COUNT(*) FROM fixed_episodes) AS fixed_episode_count;
