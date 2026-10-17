-- Task Q1/Q2: cluster spike-worker on-CPU slices into per-tick episodes (quiet gap > 1s splits).
-- Adapted from skill sql/06-cpu-spike-episodes.sql logic (interval intersection already
-- handled by sched_slice; here we cluster the worker's own slices instead of process buckets,
-- because the goal is per-thread attribution and per-tick duration).
WITH r AS (
  SELECT s.ts, s.ts + s.dur AS end_ts, s.dur, s.cpu
  FROM sched_slice s JOIN thread th USING (utid)
  WHERE th.upid = 185 AND th.name = 'spike-worker' AND s.dur > 0
), g AS (
  SELECT *, ts - LAG(end_ts, 1, ts) OVER (ORDER BY ts) AS gap_ns FROM r
), ep AS (
  SELECT *, SUM(CASE WHEN gap_ns > 1000000000 THEN 1 ELSE 0 END)
             OVER (ORDER BY ts) AS grp
  FROM g
)
SELECT grp AS episode,
       MIN(ts) AS start_ts,
       MAX(end_ts) AS end_ts,
       ROUND((MAX(end_ts) - MIN(ts)) / 1e6, 1) AS span_ms,
       ROUND(SUM(dur) / 1e6, 1) AS cpu_ms,
       COUNT(*) AS slices,
       GROUP_CONCAT(DISTINCT cpu) AS cpus,
       ROUND(100.0 * SUM(dur) / (MAX(end_ts) - MIN(ts)), 1) AS pct_of_one_core
FROM ep GROUP BY grp ORDER BY start_ts;
