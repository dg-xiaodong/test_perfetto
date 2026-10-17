-- run6 归因查询。替换 <A> 为 workload_start 的 boottime 纳秒（本次 = 37968870000000）
-- 1) exec 链：被测脚本每条命令的时刻、线程、可执行文件
SELECT round((e.ts-37968870000000)/1e9,3) AS t_rel_s, e.utid, t.tid, t.name AS thread_comm,
       MAX(CASE WHEN a.key='filename' THEN a.string_value END) AS exec_path
FROM ftrace_event e LEFT JOIN thread t USING(utid) LEFT JOIN args a ON a.arg_set_id=e.arg_set_id
WHERE e.name='sched_process_exec' GROUP BY e.ts ORDER BY e.ts;

-- 2) dd(utid 213) / rm(utid 217) 的 CPU slice（UI: Add debug track -> Slice Track, ts/dur/name, Pivot=series）
SELECT ts, dur, CASE utid WHEN 213 THEN 'dd (write 24MiB)' ELSE 'rm (unlink)' END AS name,
       'sched' AS series
FROM sched_slice WHERE utid IN (213, 217) ORDER BY ts;

-- 3) 页删除 burst：10 ms 分桶（6,144 页 = 24.00 MiB，单个 i_ino，index 0..6143）
WITH d AS (SELECT (ts/10000000)*10000000 AS ts FROM ftrace_event
           WHERE name='mm_filemap_delete_from_page_cache')
SELECT ts, 0 AS dur, COUNT(*) || ' pages deleted' AS name, 'filemap delete' AS series
FROM d GROUP BY ts ORDER BY ts;

-- 4) 总量核对：页数 / MiB / inode 数 / index 范围 / 时间窗
SELECT COUNT(*) AS pages, COUNT(*)*4096/1048576.0 AS mib,
       COUNT(DISTINCT ai.int_value) AS distinct_i_ino,
       MIN(ax.int_value) AS min_index, MAX(ax.int_value) AS max_index,
       round((MIN(e.ts)-37968870000000)/1e9,3) AS first_s, round((MAX(e.ts)-37968870000000)/1e9,3) AS last_s
FROM ftrace_event e
JOIN args ai ON ai.arg_set_id=e.arg_set_id AND ai.key='i_ino'
JOIN args ax ON ax.arg_set_id=e.arg_set_id AND ax.key='index'
WHERE e.name='mm_filemap_delete_from_page_cache';

-- 5) 反证：所有进程 anon RSS 排行（本期无增长进程）
SELECT p.name, pct.upid, MAX(c.value)/1048576.0 AS max_anon_mib
FROM counter c JOIN process_counter_track pct ON pct.id=c.track_id JOIN process p USING(upid)
WHERE pct.name='mem.rss.anon' GROUP BY pct.upid ORDER BY max_anon_mib DESC LIMIT 10;
