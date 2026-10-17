-- 00a — step 2/5: trace time range in ns and seconds.
-- Run separately (single SELECT): query -f sql/00a-trace-bounds.sql <trace>.pftrace
SELECT start_ts, end_ts, (end_ts - start_ts) / 1e9 AS duration_s
FROM trace_bounds;
