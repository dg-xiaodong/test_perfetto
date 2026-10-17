-- 16-perf-spike-vs-quiet.sql
-- Compare self CPU samples in spike vs quiet windows of THIS trace.
--
-- FIX (r1): windows are RELATIVE to trace_bounds.start_ts, not absolute
-- timestamps copied from C1. C1 and C3 are separate captures; their absolute
-- ns values are not comparable without explicit clock-alignment evidence.
-- Use a time range selected in the C3 trace itself and convert it to offsets
-- from C3's trace start. If you must use absolute ns, first prove alignment
-- (shared clock, simultaneous capture, or a common marker) and document it.
--
-- 16a-perf-window-check.sql validates the offsets against trace_bounds.
-- This answers "which function is hotter in that window", not "why".
WITH bounds AS (
  SELECT start_ts, end_ts FROM trace_bounds
), params AS (
  SELECT
    5000  AS spike_start_ms,
    6000  AS spike_end_ms,
    20000 AS quiet_start_ms,
    21000 AS quiet_end_ms
), windows AS (
  SELECT
    b.start_ts,
    b.end_ts,
    b.start_ts + p.spike_start_ms * 1000000 AS spike_start_ts,
    b.start_ts + p.spike_end_ms   * 1000000 AS spike_end_ts,
    b.start_ts + p.quiet_start_ms * 1000000 AS quiet_start_ts,
    b.start_ts + p.quiet_end_ms   * 1000000 AS quiet_end_ts
  FROM bounds b, params p
), valid AS (
  SELECT * FROM windows
  WHERE spike_start_ts >= start_ts AND spike_end_ts <= end_ts
    AND quiet_start_ts >= start_ts AND quiet_end_ts <= end_ts
    AND spike_start_ts < spike_end_ts
    AND quiet_start_ts < quiet_end_ts
), target_threads AS (
  SELECT th.utid
  FROM thread th
  JOIN process p USING (upid)
  WHERE p.name = 'worker_app'
     OR p.name GLOB '*/' || 'worker_app'
), tagged AS (
  SELECT
    ps.id,
    CASE
      WHEN ps.ts >= w.spike_start_ts AND ps.ts < w.spike_end_ts THEN 'spike'
      WHEN ps.ts >= w.quiet_start_ts AND ps.ts < w.quiet_end_ts THEN 'quiet'
      ELSE 'excluded'
    END AS phase,
    COALESCE(f.name, '<unknown>') AS frame_name,
    COALESCE(m.name, '<unknown>') AS mapping_name
  FROM perf_sample ps
  JOIN target_threads t USING (utid)
  JOIN stack_profile_callsite c ON c.id = ps.callsite_id
  JOIN stack_profile_frame f ON f.id = c.frame_id
  LEFT JOIN stack_profile_mapping m ON m.id = f.mapping
  CROSS JOIN valid w
)
SELECT phase, frame_name, mapping_name, COUNT(*) AS samples
FROM tagged
WHERE phase <> 'excluded'
GROUP BY phase, frame_name, mapping_name
ORDER BY phase, samples DESC;
