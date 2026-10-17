-- 进程 RSS 分类（把 -1 换成目标 UPID：SELECT upid,pid,name FROM process WHERE name IN ('sh','dd');）
INCLUDE PERFETTO MODULE linux.memory.process;
SELECT m.ts, m.upid, m.anon_rss/1048576.0 AS anon_mib, m.file_rss/1048576.0 AS file_mib,
       m.shmem_rss/1048576.0 AS shmem_mib, m.rss/1048576.0 AS rss_mib
FROM memory_rss_and_swap_per_process m WHERE m.upid = -1 ORDER BY m.ts;

-- 全进程 anon RSS 排行（本测试用于证明“没有进程在增长”）
SELECT p.name, pct.upid, MAX(c.value)/1048576.0 AS max_anon_mib
FROM counter c
JOIN process_counter_track pct ON pct.id = c.track_id
JOIN process p USING (upid)
WHERE pct.name = 'mem.rss.anon'
GROUP BY pct.upid ORDER BY max_anon_mib DESC LIMIT 12;
