-- target_upid 必须来自 sql/00-inventory.sql 的 [CANDIDATES] 查询结果：
--   * 仅当恰好一个候选 data_bearing=1 时才用它；有歧义 → 报未解析，不静默选。
--   * 用户已指定 PID/UPID 时沿用该值，不因“另一条记录有数据”而改选。
--   * 保持 -1 表示未解析：此时返回 0 行不代表“没有分配”，必须先解析目标。
-- Normal Native incremental profiles ONLY, not ART allocation or dump_at_max.
-- Fill params from inventory; byte values are already sampling estimates.
-- UI: Counter Track; ts / value / series. Snapshot resolution, NOT per-malloc.
WITH params AS (
  SELECT 190 AS target_upid, 'libc.malloc' AS target_heap,
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
