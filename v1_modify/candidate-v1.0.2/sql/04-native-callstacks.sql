-- target_upid 必须来自 sql/00-inventory.sql 的 [CANDIDATES] 查询结果：
--   * 仅当恰好一个候选 data_bearing=1 时才用它；有歧义 → 报未解析，不静默选。
--   * 用户已指定 PID/UPID 时沿用该值，不因“另一条记录有数据”而改选。
--   * 保持 -1 表示未解析：此时返回 0 行不代表“没有分配”，必须先解析目标。
-- Normal Native allocation profiles ONLY. Filter BEFORE recursive aggregation.
-- This returns a TABLE of frame/callsite cumulative values, not a timeline.
-- Set params using actual trace UPID, heap and nanosecond timestamps.
WITH RECURSIVE params AS (
  SELECT -1 AS target_upid, 'libc.malloc' AS target_heap,
         0 AS start_ts, 9223372036854775807 AS end_ts
), leaf AS (
  SELECT a.callsite_id,
         SUM(a.size) AS live_at_end,
         SUM(CASE WHEN a.ts >= p.start_ts AND a.size > 0 THEN a.size ELSE 0 END) AS allocated_in_window
  FROM heap_profile_allocation a, params p
  WHERE a.upid = p.target_upid AND a.heap_name = p.target_heap AND a.ts <= p.end_ts
  GROUP BY a.callsite_id
), ancestors(leaf_id, callsite_id, live_at_end, allocated_in_window) AS (
  SELECT callsite_id, callsite_id, live_at_end, allocated_in_window FROM leaf
  UNION ALL
  SELECT a.leaf_id, c.parent_id, a.live_at_end, a.allocated_in_window
  FROM ancestors a JOIN stack_profile_callsite c ON c.id = a.callsite_id
  WHERE c.parent_id IS NOT NULL
)
SELECT a.callsite_id, c.parent_id, f.name AS frame_name, m.name AS mapping_name,
       SUM(a.live_at_end) AS cumulative_live_bytes_at_end,
       SUM(a.allocated_in_window) AS cumulative_allocated_bytes_in_window
FROM ancestors a
JOIN stack_profile_callsite c ON c.id = a.callsite_id
JOIN stack_profile_frame f ON f.id = c.frame_id
LEFT JOIN stack_profile_mapping m ON m.id = f.mapping
GROUP BY a.callsite_id, c.parent_id, f.name, m.name
ORDER BY cumulative_live_bytes_at_end DESC;
-- Ancestors intentionally repeat descendant totals. NEVER sum this result to
-- calculate process memory. For inlined/symbolized source lines use native UI.
