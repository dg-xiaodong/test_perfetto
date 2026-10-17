-- 16a-perf-window-check.sql
-- Companion to 16-perf-spike-vs-quiet.sql.
-- Purpose: prove the relative windows are inside THIS trace before trusting
-- an empty/non-empty sample comparison.
--
-- Edit the four *_ms offsets in params. They are relative to this trace's
-- trace_bounds.start_ts. Do NOT paste absolute timestamps from C1 here.
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
)
SELECT
  start_ts,
  end_ts,
  spike_start_ts,
  spike_end_ts,
  quiet_start_ts,
  quiet_end_ts,
  CASE
    WHEN spike_start_ts < start_ts OR spike_end_ts > end_ts
      OR quiet_start_ts < start_ts OR quiet_end_ts > end_ts
    THEN 'OUT_OF_TRACE'
    WHEN spike_start_ts >= spike_end_ts OR quiet_start_ts >= quiet_end_ts
    THEN 'INVALID_RANGE'
    ELSE 'OK'
  END AS window_check
FROM windows;
