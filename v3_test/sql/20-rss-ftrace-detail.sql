-- 20-rss-ftrace-detail.sql
-- 目标进程的 RSS ftrace（kmem/rss_stat）事件级数据：
-- 说明事件覆盖、粒度，以及在 malloc / mmap 两个阶段的表现。
-- 注意：rss_stat.size 是该类别当时的绝对量；事件由内核批量更新触发，
-- 不是逐页、逐次 malloc 的无损时间线。
-- （Trace Processor 的 -f 多语句不共享 CTE，故每条语句自行声明。）

INCLUDE PERFETTO MODULE linux.memory.process;

-- [1] 覆盖与幅度：目标进程 rss_stat 事件数、时间范围、峰值
SELECT (SELECT COUNT(*) FROM memory_rss_and_swap_per_process WHERE upid = 186) AS rss_stat_samples,
       (SELECT COUNT(DISTINCT ts) FROM memory_rss_and_swap_per_process WHERE upid = 186) AS distinct_ts,
       (SELECT MIN(ts) FROM memory_rss_and_swap_per_process WHERE upid = 186) AS first_ts,
       (SELECT MAX(ts) FROM memory_rss_and_swap_per_process WHERE upid = 186) AS last_ts,
       (SELECT ROUND(MAX(rss) / 1048576.0, 3) FROM memory_rss_and_swap_per_process WHERE upid = 186) AS max_total_rss_mib,
       (SELECT ROUND(MAX(anon_rss) / 1048576.0, 3) FROM memory_rss_and_swap_per_process WHERE upid = 186) AS max_anon_rss_mib;

-- [2] malloc 阶段：touch 开始到 hold 开始前后的 anon 曲线（MiB）
SELECT ts, ROUND(anon_rss / 1048576.0, 3) AS anon_mib,
       ROUND(file_rss / 1048576.0, 3) AS file_mib,
       ROUND(shmem_rss / 1048576.0, 3) AS shmem_mib,
       ROUND(rss / 1048576.0, 3) AS total_rss_mib
FROM memory_rss_and_swap_per_process
WHERE upid = 186 AND ts BETWEEN 30389709933199 AND 30389790000000
ORDER BY ts;

-- [3] free 阶段：A_HOLD_END 到 A_IDLE_START 之间的回落
SELECT ts, ROUND(anon_rss / 1048576.0, 3) AS anon_mib,
       ROUND(file_rss / 1048576.0, 3) AS file_mib,
       ROUND(shmem_rss / 1048576.0, 3) AS shmem_mib,
       ROUND(rss / 1048576.0, 3) AS total_rss_mib
FROM memory_rss_and_swap_per_process
WHERE upid = 186 AND ts BETWEEN 30395786204618 AND 30395850000000
ORDER BY ts;
