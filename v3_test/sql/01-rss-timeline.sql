-- 01-rss-timeline.sql
-- 来源：冻结版 v1.0.2 `sql/01-rss-timeline.sql`，仅把 target_upid 从 -1 换成实际
-- UPID 186；其余 SQL 文本与判读口径不变。
-- 数据源：kmem/rss_stat（由 linux.memory.process 标准库展开为 anon/file/shmem/total）。
-- 输出单位 MiB；ts 为 trace 绝对 ns。UI: Counter Track, ts/value/series。
INCLUDE PERFETTO MODULE linux.memory.process;
WITH params AS (SELECT 186 AS target_upid), selected AS (
  SELECT m.* FROM memory_rss_and_swap_per_process m, params
  WHERE m.upid = params.target_upid
), series_data AS (
  SELECT ts, upid, 'anon' AS category, anon_rss AS bytes FROM selected
  UNION ALL SELECT ts, upid, 'file', file_rss FROM selected
  UNION ALL SELECT ts, upid, 'shmem', shmem_rss FROM selected
  UNION ALL SELECT ts, upid, 'total RSS', rss FROM selected
)
SELECT ts, bytes / 1048576.0 AS value,
       'UPID ' || upid || ' | ' || category || ' (MiB)' AS series
FROM series_data WHERE bytes IS NOT NULL ORDER BY series, ts;
