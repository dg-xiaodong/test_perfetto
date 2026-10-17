-- 16-perf-spike-vs-quiet.sql
-- Compare self CPU samples in explicit spike vs quiet windows.
-- Fill all four timestamps in ns, taken from C1's time selection.
-- This answers "which function is hotter during the jitter", not "why".
WITH params AS (
  SELECT
    'worker_app' AS target_name,
    0 AS spike_start_ts,
    0 AS spike_end_ts,
    0 AS quiet_start_ts,
    0 AS quiet_end_ts
), target_threads AS (
  SELECT th.utid
  FROM thread th
  JOIN process p USING (upid), params
  WHERE p.name = params.target_name
     OR p.name GLOB '*/' || params.target_name
), tagged AS (
  SELECT
    ps.id,
    CASE
      WHEN ps.ts >= (SELECT spike_start_ts FROM params)
       AND ps.ts <  (SELECT spike_end_ts   FROM params) THEN 'spike'
      WHEN ps.ts >= (SELECT quiet_start_ts FROM params)
       AND ps.ts <  (SELECT quiet_end_ts   FROM params) THEN 'quiet'
      ELSE 'excluded'
    END AS phase,
    COALESCE(f.name, '<unknown>') AS frame_name,
    COALESCE(m.name, '<unknown>') AS mapping_name
  FROM perf_sample ps
  JOIN target_threads t USING (utid)
  JOIN stack_profile_callsite c ON c.id = ps.callsite_id
  JOIN stack_profile_frame f ON f.id = c.frame_id
  LEFT JOIN stack_profile_mapping m ON m.id = f.mapping
)
SELECT phase, frame_name, mapping_name, COUNT(*) AS samples
FROM tagged
WHERE phase <> 'excluded'
GROUP BY phase, frame_name, mapping_name
ORDER BY phase, samples DESC;
