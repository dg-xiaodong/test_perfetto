-- Normal Native incremental profiles ONLY, not ART allocation or dump_at_max.
-- Fill params from inventory; byte values are already sampling estimates.
-- UI: Counter Track; ts / value / series. Snapshot resolution, NOT per-malloc.
WITH params AS (
  SELECT -1 AS target_upid, 'libc.malloc' AS target_heap,
         0 AS start_ts, 9223372036854775807 AS end_ts
), deltas AS (
  SELECT a.ts, a.upid, a.heap_name, SUM(a.size) AS delta
  FROM heap_profile_allocation a, params p
  WHERE a.upid = p.target_upid AND a.heap_name = p.target_heap AND a.ts <= p.end_ts
  GROUP BY a.ts, a.upid, a.heap_name
), live AS (
  SELECT ts, upid, heap_name,
         SUM(delta) OVER (PARTITION BY upid, heap_name ORDER BY ts
           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS live_bytes
  FROM deltas
)
SELECT ts, live_bytes / 1048576.0 AS value,
       'UPID ' || upid || ' | ' || heap_name || ' live estimate (MiB)' AS series
FROM live, params p WHERE ts >= p.start_ts ORDER BY ts;
-- Prefix sum occurs BEFORE display-window filtering: earlier baseline is kept.
