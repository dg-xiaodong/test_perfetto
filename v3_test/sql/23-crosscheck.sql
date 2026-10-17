-- 23-crosscheck.sql
-- 程序记录 vs trace 实测对照。
-- 程序侧常量来自 traces/memphase.log（CLOCK_BOOTTIME 标记，日志在采集前先写好，
-- 不依赖 trace）：malloc 33554432 B、mmap 33554432 B，两阶段各一次。
-- 阶段窗口：
--   A malloc [30389709933199, 30395817772035]
--   B mmap   [30400822147912, 30406938280165]
-- 判读：不允许把采样估计值写成“精确分配次数”；此处 count=1 的大分配因
-- size >= sampling_interval(4096) 被必采，size 为精确值，属特例，不能外推到小对象。

WITH
alloc AS (
  SELECT SUM(CASE WHEN size > 0 THEN size ELSE 0 END) AS pos_bytes,
         SUM(CASE WHEN size < 0 THEN -size ELSE 0 END) AS neg_bytes,
         MIN(CASE WHEN size > 0 THEN ts END) AS pos_ts,
         SUM(CASE WHEN count > 0 THEN count ELSE 0 END) AS pos_count
  FROM heap_profile_allocation
  WHERE upid = 186 AND heap_name = 'libc.malloc'
),
rss_a AS (
  SELECT MAX(c.value) - MIN(c.value) AS delta
  FROM process_counter_track pct JOIN counter c ON c.track_id = pct.id
  WHERE pct.upid = 186 AND pct.name = 'mem.rss'
    AND c.ts BETWEEN 30388000000000 AND 30395817772035
),
rss_b AS (
  SELECT MAX(c.value) - MIN(c.value) AS delta
  FROM process_counter_track pct JOIN counter c ON c.track_id = pct.id
  WHERE pct.upid = 186 AND pct.name = 'mem.rss'
    AND c.ts BETWEEN 30396000000000 AND 30406938280165
),
dumps AS (
  SELECT (SELECT value FROM stats WHERE name = 'heapprofd_unwind_samples' AND idx = 3127) AS sent,
         (SELECT COUNT(*) FROM heap_profile WHERE upid = 186 AND heap_name = 'libc.malloc') AS visible
)
SELECT 'A: malloc 32 MiB — program bytes -> heapprofd positive bytes' AS check_item,
       '33554432 -> ' || alloc.pos_bytes AS check_values,
       CASE WHEN alloc.pos_bytes = 33554432 THEN 'MATCH' ELSE 'DIFF' END AS verdict
FROM alloc
UNION ALL
SELECT 'A: free 32 MiB — program bytes -> heapprofd negative bytes',
       '33554432 -> ' || alloc.neg_bytes,
       CASE WHEN alloc.neg_bytes = 33554432 THEN 'MATCH' ELSE 'DIFF' END
FROM alloc
UNION ALL
SELECT 'A: alloc record count (sampling estimate, not a malloc log)',
       '1 expected (large alloc p=1) -> ' || alloc.pos_count,
       CASE WHEN alloc.pos_count = 1 THEN 'MATCH' ELSE 'DIFF' END
FROM alloc
UNION ALL
SELECT 'B: direct mmap 32 MiB — heapprofd rows in B window',
       '0 -> ' || (SELECT COUNT(*) FROM heap_profile_allocation
                    WHERE upid = 186 AND ts BETWEEN 30400822147912 AND 30406938280165),
       CASE WHEN (SELECT COUNT(*) FROM heap_profile_allocation
                   WHERE upid = 186 AND ts BETWEEN 30400822147912 AND 30406938280165) = 0
            THEN 'NOT COVERED (expected for direct mmap)' ELSE 'UNEXPECTED ROWS' END
UNION ALL
SELECT 'A: heapprofd alloc ts - program malloc start (ms)',
       ROUND((alloc.pos_ts - 30389709933199) / 1e6, 3) || ' ms',
       CASE WHEN alloc.pos_ts BETWEEN 30389709933199 AND 30389781658032
            THEN 'INSIDE malloc/touch window' ELSE 'OUTSIDE' END
FROM alloc
UNION ALL
SELECT 'B: RSS rise A idle -> mmap hold (MiB)',
       ROUND(rss_b.delta / 1048576.0, 3) || ' MiB (expected ~32)',
       CASE WHEN ABS(rss_b.delta - 33554432) < 2097152 THEN 'MATCH within 2 MiB' ELSE 'DIFF' END
FROM rss_b
UNION ALL
SELECT 'A: RSS rise baseline -> malloc hold (MiB)',
       ROUND(rss_a.delta / 1048576.0, 3) || ' MiB (expected ~32)',
       CASE WHEN ABS(rss_a.delta - 33554432) < 2097152 THEN 'MATCH within 2 MiB' ELSE 'DIFF' END
FROM rss_a
UNION ALL
SELECT 'dump count: collector sent -> analyzer visible',
       dumps.sent || ' -> ' || dumps.visible,
       CASE WHEN dumps.sent = 9 AND dumps.visible = 1 THEN 'DEDUPED (same window_end, dur=0)'
            ELSE 'CHECK' END
FROM dumps;
