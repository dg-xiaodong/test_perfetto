-- 12-native-dump-timeline.sql
-- One row per heapprofd dump end: allocation/free bytes and counts.
-- IMPORTANT: on v57.1 collector + v58.2 TP, heap_profile.dur is often 0
-- (start_timestamp not published). Treat a.row ts as the snapshot END and the
-- preceding dump_interval_ms as an UNKNOWN-width window; do not claim exact
-- per-malloc timestamps. See references/02-native.md "Dump 可见性".
WITH params AS (
  SELECT -1 AS target_upid, 'libc.malloc' AS target_heap
)
SELECT
  a.ts AS dump_end_ts,
  a.ts AS ts_ns,
  SUM(CASE WHEN a.size > 0 THEN a.size ELSE 0 END) AS alloc_bytes,
  SUM(CASE WHEN a.size > 0 THEN a.count ELSE 0 END) AS alloc_count,
  SUM(CASE WHEN a.size < 0 THEN -a.size ELSE 0 END) AS free_bytes,
  SUM(CASE WHEN a.size < 0 THEN -a.count ELSE 0 END) AS free_count,
  SUM(a.size) AS net_bytes
FROM heap_profile_allocation a, params p
WHERE a.upid = p.target_upid
  AND a.heap_name = p.target_heap
GROUP BY a.ts
ORDER BY a.ts;
