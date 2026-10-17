-- Dump 可见性能力检查（配合 references/02-native.md 的“Dump 可见性”小节）
-- 先确认分析器是否有 heap_profile 表；v57.1 的 TP 没有该表，用文件末尾的降级语句。
-- 判读：dumps 少、zero_dur_dumps==dumps、distinct_ts_end==dumps 时，
--       说明可见性受“分配推进窗口”/旧采集端无 start_timestamp 影响，不代表采集失败。
-- 不要用本文件的结果去改验收阈值。

-- [1] 表能力：这一版分析器提供了哪些表
SELECT name FROM sqlite_master
WHERE name IN ('heap_profile', 'heap_profile_allocation')
ORDER BY name;

-- [2] dump 轴（v58.2 分析器）：窗口、行数、零宽 dump 检测
WITH params AS (SELECT -1 AS target_upid, 'libc.malloc' AS target_heap)
SELECT h.ts, h.ts_end, h.dur, h.upid, h.heap_name,
       (SELECT COUNT(*) FROM heap_profile_allocation a
         WHERE a.upid = h.upid AND a.heap_name = h.heap_name AND a.ts = h.ts_end) AS alloc_rows
FROM heap_profile h, params p
WHERE h.upid = p.target_upid AND h.heap_name = p.target_heap
ORDER BY h.ts_end;

-- [3] 汇总：可见 dump 数、时间戳是否重复、零宽 dump 数（v58.2 分析器）
WITH params AS (SELECT -1 AS target_upid, 'libc.malloc' AS target_heap)
SELECT COUNT(*) AS dumps,
       COUNT(DISTINCT h.ts_end) AS distinct_ts_end,
       SUM(CASE WHEN h.dur = 0 THEN 1 ELSE 0 END) AS zero_dur_dumps,
       MIN(h.ts_end) AS first_ts_end, MAX(h.ts_end) AS last_ts_end
FROM heap_profile h, params p
WHERE h.upid = p.target_upid AND h.heap_name = p.target_heap;

-- [4] 降级（v57.1 分析器 / 无 heap_profile 表）：只能统计“活动 dump”
WITH params AS (SELECT -1 AS target_upid, 'libc.malloc' AS target_heap)
SELECT COUNT(DISTINCT a.ts) AS activity_dumps,
       MIN(a.ts) AS first_ts, MAX(a.ts) AS last_ts,
       SUM(CASE WHEN a.size > 0 THEN a.size ELSE 0 END) AS alloc_bytes,
       SUM(CASE WHEN a.size < 0 THEN -a.size ELSE 0 END) AS free_bytes
FROM heap_profile_allocation a, params p
WHERE a.upid = p.target_upid AND a.heap_name = p.target_heap;
