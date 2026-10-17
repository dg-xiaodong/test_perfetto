-- v4_test 采集验收：时间范围 / 计数器样本 / 非 info 级错误 / rss_stat 事件数
-- 用法: trace_processor_shell query traces/run1.pftrace "$(cat sql/00-inventory.sql)"   或粘贴到 UI Query(SQL)

SELECT * FROM trace_bounds;

SELECT ct.name, COUNT(*) AS n
FROM counter c JOIN counter_track ct ON ct.id = c.track_id
WHERE ct.name IN ('MemAvailable','MemFree','Shmem','Cached','AnonPages','Slab')
GROUP BY ct.name;

SELECT name, idx, severity, value FROM stats WHERE value <> 0 AND severity <> 'info';

SELECT COUNT(*) AS rss_stat_events FROM ftrace_event WHERE name = 'rss_stat';
