-- 00-inventory.sql — 采集验收：目标 UPID / trace 范围 / 数据源 / 丢失
-- Trace: heap.pftrace (X5 board, tracebox v57.1), analyzer: Trace Processor v58.2
-- 目标：./memphase (pid 3127)，来自 sql/00 的候选解析；UPID=186。

-- [1] trace 绝对时间范围（boot time ns）
SELECT start_ts, end_ts, (end_ts - start_ts) / 1e9 AS dur_s FROM trace_bounds;

-- [2] 候选进程解析：只有 UPID 186 有 native 数据；188 是 preload fork 的
--     heapprofd 辅助子进程（同名，data_bearing=0），不选它。
WITH params AS (SELECT 'libc.malloc' AS target_heap)
SELECT p.upid, p.pid, p.name,
       (SELECT COUNT(*) FROM heap_profile_allocation a, params q
         WHERE a.upid = p.upid AND a.heap_name = q.target_heap) AS alloc_rows,
       (SELECT COUNT(*) FROM heap_profile h, params q
         WHERE h.upid = p.upid AND h.heap_name = q.target_heap) AS dumps,
       CASE WHEN (SELECT COUNT(*) FROM heap_profile_allocation a, params q
                   WHERE a.upid = p.upid AND a.heap_name = q.target_heap) > 0
            THEN 1 ELSE 0 END AS data_bearing
FROM process p
WHERE p.name LIKE '%memphase%'
ORDER BY data_bearing DESC, p.upid;

-- [3] 四类数据源各自的可查数据（同一份 trace）
SELECT 'linux.process_stats: 目标进程 mem.rss 采样' AS data_source,
       COUNT(*) AS rows, MIN(value) / 1048576.0 AS min_mib, MAX(value) / 1048576.0 AS max_mib
FROM counter c JOIN process_counter_track pct ON pct.id = c.track_id
WHERE pct.upid = 186 AND pct.name = 'mem.rss'
UNION ALL
SELECT 'linux.sys_stats: MemAvailable 采样', COUNT(*),
       MIN(c.value) / 1048576.0, MAX(c.value) / 1048576.0
FROM counter c JOIN counter_track ct ON ct.id = c.track_id
WHERE ct.name = 'MemAvailable'
UNION ALL
SELECT 'linux.ftrace: kmem/rss_stat 事件', COUNT(*), NULL, NULL FROM raw WHERE name = 'rss_stat'
UNION ALL
SELECT 'android.heapprofd: heap_profile dump 行', COUNT(*), NULL, NULL FROM heap_profile WHERE upid = 186;

-- [4] 已注册/已见数据源与采集器版本侧信息
SELECT name, value FROM stats
WHERE name IN ('traced_data_sources_registered', 'traced_data_sources_seen',
               'traced_buffers', 'traced_producers_connected');

-- [5] 数据丢失/异常（非 info 或与 buffer/heap/ftrace 有关且非零）
SELECT name, idx, severity, source, value FROM stats
WHERE value <> 0 AND (severity <> 'info' OR name LIKE '%overrun%'
      OR name LIKE '%discard%' OR name LIKE '%corrupt%' OR name LIKE '%heapprofd%')
ORDER BY severity, name;
