-- 15-perf-allocator-share.sql
-- What fraction of target CPU samples land in allocator code?
-- A high share during spikes is evidence of allocator cost; it is NOT proof of
-- object churn and does not replace heapprofd Total Size/Count.
WITH params AS (
  SELECT 'worker_app' AS target_name
), target_threads AS (
  SELECT th.utid
  FROM thread th
  JOIN process p USING (upid), params
  WHERE p.name = params.target_name
     OR p.name GLOB '*/' || params.target_name
), classified AS (
  SELECT
    ps.id,
    CASE
      WHEN f.name GLOB '*malloc*' OR f.name GLOB '*free*'
        OR f.name GLOB '*operator new*' OR f.name GLOB '*operator delete*'
        OR f.name GLOB '*tcache*' OR f.name GLOB '*_int_malloc*'
        OR f.name GLOB '*_int_free*' OR f.name GLOB '*arena*'
        OR f.name GLOB '_Znwm*' OR f.name GLOB '_ZdlPv*'
        OR f.name GLOB '_Znam*' OR f.name GLOB '_ZdaPv*'
      THEN 'allocator_or_free'
      ELSE 'other'
    END AS class
  FROM perf_sample ps
  JOIN target_threads t USING (utid)
  JOIN stack_profile_callsite c ON c.id = ps.callsite_id
  JOIN stack_profile_frame f ON f.id = c.frame_id
)
SELECT class, COUNT(*) AS samples,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM classified
GROUP BY class
ORDER BY samples DESC;
