-- 系统内存时间线（UI: Add debug track -> Counter Track, Timestamp=ts, Value=value, Pivot=series）
-- counter.value 是 bytes；/proc/meminfo 原值 kB × 1024 后进入 trace。
SELECT c.ts AS ts, c.value / 1048576.0 AS value, ct.name AS series
FROM counter c JOIN counter_track ct ON ct.id = c.track_id
WHERE ct.name IN ('MemAvailable','MemFree','Shmem','Cached','AnonPages','Slab','PageTables','KernelStack')
ORDER BY series, ts;

-- 对齐到 workload_start 的相对秒数（临时表；按需替换时间戳）
-- SELECT (c.ts - <workload_start_ns>) / 1e9 AS t_rel, ct.name, c.value / 1048576.0 AS mib
-- FROM counter c JOIN counter_track ct ON ct.id = c.track_id
-- WHERE ct.name IN ('MemAvailable','Shmem','Cached') ORDER BY t_rel;
