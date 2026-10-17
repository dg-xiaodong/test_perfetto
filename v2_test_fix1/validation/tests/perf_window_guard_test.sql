-- Guard test for sql/16a-perf-window-check.sql.
-- Windows are relative to this trace's trace_bounds.start_ts.
-- Expected: 'inside' -> OK, 'outside' -> OUT_OF_TRACE.
WITH bounds AS (
  SELECT start_ts, end_ts FROM trace_bounds
), cases(name, spike_start_ms, spike_end_ms, quiet_start_ms, quiet_end_ms) AS (
  VALUES
    ('inside',  1000, 2000,  3000,  4000),
    ('outside', 20000, 21000, 22000, 23000)
), windows AS (
  SELECT
    c.name,
    b.start_ts + c.spike_start_ms * 1000000 AS spike_start_ts,
    b.start_ts + c.spike_end_ms   * 1000000 AS spike_end_ts,
    b.start_ts + c.quiet_start_ms * 1000000 AS quiet_start_ts,
    b.start_ts + c.quiet_end_ms   * 1000000 AS quiet_end_ts,
    b.start_ts,
    b.end_ts
  FROM bounds b, cases c
)
SELECT
  name,
  CASE
    WHEN spike_start_ts < start_ts OR spike_end_ts > end_ts
      OR quiet_start_ts < start_ts OR quiet_end_ts > end_ts
    THEN 'OUT_OF_TRACE'
    WHEN spike_start_ts >= spike_end_ts OR quiet_start_ts >= quiet_end_ts
    THEN 'INVALID_RANGE'
    ELSE 'OK'
  END AS window_check
FROM windows
ORDER BY name;
