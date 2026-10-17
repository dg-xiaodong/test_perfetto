-- 02-rss-phase-summary.sql
-- 进程 RSS（linux.process_stats, /proc/pid/statm, 1 s）与系统内存计数器
-- （linux.sys_stats, 1 s）按程序记录的阶段窗口汇总。
-- 阶段边界来自 traces/memphase.log 的 CLOCK_BOOTTIME 标记（与 trace ts 同钟）。
-- 单位 MiB。rss_stat（事件级）另见 01/20；两者口径不同，不互相替代。

WITH phases(name, start_ts, end_ts) AS (VALUES
  ('baseline', 30384706138405, 30389709898074),
  ('A_hold  ', 30389781691115, 30395786204618),
  ('A_idle  ', 30395817850702, 30400822088371),
  ('B_hold  ', 30400902164454, 30406906801332),
  ('B_idle  ', 30406938351582, 30411942447709)
),
rss AS (
  SELECT p.name AS phase, COUNT(*) AS n,
         MIN(c.value) / 1048576.0 AS min_mib,
         MAX(c.value) / 1048576.0 AS max_mib,
         AVG(c.value) / 1048576.0 AS avg_mib
  FROM phases p
  JOIN process_counter_track pct ON pct.upid = 186 AND pct.name = 'mem.rss'
  JOIN counter c ON c.track_id = pct.id AND c.ts BETWEEN p.start_ts AND p.end_ts
  GROUP BY p.name
),
sysavail AS (
  SELECT p.name AS phase, COUNT(*) AS n,
         MIN(c.value) / 1048576.0 AS min_mib,
         MAX(c.value) / 1048576.0 AS max_mib
  FROM phases p
  JOIN counter_track ct ON ct.name = 'MemAvailable'
  JOIN counter c ON c.track_id = ct.id AND c.ts BETWEEN p.start_ts AND p.end_ts
  GROUP BY p.name
),
anonpages AS (
  SELECT p.name AS phase, COUNT(*) AS n,
         MIN(c.value) / 1048576.0 AS min_mib,
         MAX(c.value) / 1048576.0 AS max_mib
  FROM phases p
  JOIN counter_track ct ON ct.name = 'AnonPages'
  JOIN counter c ON c.track_id = ct.id AND c.ts BETWEEN p.start_ts AND p.end_ts
  GROUP BY p.name
)
SELECT r.phase, r.n AS rss_samples,
       ROUND(r.min_mib, 3) AS rss_min_mib, ROUND(r.max_mib, 3) AS rss_max_mib,
       ROUND(r.avg_mib, 3) AS rss_avg_mib,
       s.n AS sys_samples,
       ROUND(s.min_mib, 3) AS memavail_min_mib, ROUND(s.max_mib, 3) AS memavail_max_mib,
       ROUND(a.min_mib, 3) AS anonpages_min_mib, ROUND(a.max_mib, 3) AS anonpages_max_mib
FROM rss r
LEFT JOIN sysavail s USING (phase)
LEFT JOIN anonpages a USING (phase)
ORDER BY r.phase;
