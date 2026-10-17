-- 13-native-callsite-hotspots.sql
-- Leaf callsites by allocated and freed bytes/counts (not ancestor-cumulative).
-- Use sql/04-native-callstacks.sql when the caller chain is needed.
-- Requires symbols for source-level names; otherwise mapping/address only.
WITH params AS (
  SELECT -1 AS target_upid, 'libc.malloc' AS target_heap
)
SELECT
  a.callsite_id,
  COALESCE(f.name, '<unknown>') AS frame_name,
  COALESCE(m.name, '<unknown>') AS mapping_name,
  SUM(CASE WHEN a.size > 0 THEN a.size ELSE 0 END) AS alloc_bytes,
  SUM(CASE WHEN a.size > 0 THEN a.count ELSE 0 END) AS alloc_count,
  SUM(CASE WHEN a.size < 0 THEN -a.size ELSE 0 END) AS free_bytes,
  SUM(CASE WHEN a.size < 0 THEN -a.count ELSE 0 END) AS free_count,
  SUM(a.size) AS net_bytes
FROM heap_profile_allocation a
LEFT JOIN stack_profile_callsite c ON c.id = a.callsite_id
LEFT JOIN stack_profile_frame f ON f.id = c.frame_id
LEFT JOIN stack_profile_mapping m ON m.id = f.mapping, params p
WHERE a.upid = p.target_upid
  AND a.heap_name = p.target_heap
GROUP BY a.callsite_id, frame_name, mapping_name
ORDER BY alloc_bytes DESC
LIMIT 50;
