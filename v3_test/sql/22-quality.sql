-- 22-quality.sql
-- 采集质量：traced buffer 读写/丢弃、ftrace overrun、heapprofd 侧统计。
-- 数值来自 trace 的 stats 表（由采集器/分析器写入），不是人工填写。

-- [1] traced buffers（3 个：8 MiB process/sys + 4 MiB ftrace 逻辑缓冲 + 32 MiB heap）
SELECT name, idx, SUM(value) AS value FROM stats
WHERE name IN ('traced_buf_buffer_size', 'traced_buf_bytes_written',
               'traced_buf_bytes_read', 'traced_buf_chunks_written',
               'traced_buf_chunks_read', 'traced_buf_chunks_discarded')
GROUP BY name, idx ORDER BY name, idx;

-- [2] ftrace：溢出/commit overrun 汇总（0 表示未记录到丢失）
SELECT name, SUM(value) AS total FROM stats
WHERE name IN ('ftrace_cpu_overrun_begin', 'ftrace_cpu_overrun_end',
               'ftrace_cpu_commit_overrun_begin', 'ftrace_cpu_commit_overrun_end',
               'ftrace_cpu_read_events_end', 'ftrace_cpu_dropped_events_end')
GROUP BY name ORDER BY name;

-- [3] heapprofd 侧：采集器报告了多少个 dump 样本、客户端是否异常断开、最后一次 profile 时间
SELECT name, idx AS pid, value FROM stats
WHERE name IN ('heapprofd_unwind_samples', 'heapprofd_client_disconnected',
               'heapprofd_last_profile_timestamp', 'heapprofd_buffer_overran',
               'heapprofd_rejected_concurrent', 'heapprofd_hit_guardrail')
ORDER BY name;

-- [4] 分析器口径下的可见 dump：collector 9 份 dump 全部同 window_end，去重成 1 行且 dur=0
SELECT COUNT(*) AS visible_dumps,
       COUNT(DISTINCT ts_end) AS distinct_ts_end,
       SUM(CASE WHEN dur = 0 THEN 1 ELSE 0 END) AS zero_dur_dumps,
       MIN(ts) AS first_ts, MAX(ts_end) AS last_ts_end
FROM heap_profile WHERE upid = 186 AND heap_name = 'libc.malloc';
