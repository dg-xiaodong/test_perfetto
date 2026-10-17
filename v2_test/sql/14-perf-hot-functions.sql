-- 14-perf-hot-functions.sql
-- Self (leaf) CPU samples by function for the target process.
-- This is a sampling estimate, not exact CPU time; compare with sched_slice.
-- Requires symbols (Build ID) for useful names.
WITH params AS (
  SELECT 'worker_app' AS target_name
), target_threads AS (
  SELECT th.utid
  FROM thread th
  JOIN process p USING (upid), params
  WHERE p.name = params.target_name
     OR p.name GLOB '*/' || params.target_name
)
SELECT
  COALESCE(f.name, '<unknown>') AS frame_name,
  COALESCE(m.name, '<unknown>') AS mapping_name,
  COUNT(*) AS samples,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_target_samples
FROM perf_sample ps
JOIN target_threads t USING (utid)
JOIN stack_profile_callsite c ON c.id = ps.callsite_id
JOIN stack_profile_frame f ON f.id = c.frame_id
LEFT JOIN stack_profile_mapping m ON m.id = f.mapping
GROUP BY frame_name, mapping_name
ORDER BY samples DESC
LIMIT 50;
