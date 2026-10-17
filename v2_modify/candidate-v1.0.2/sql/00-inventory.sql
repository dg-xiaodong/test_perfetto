-- Run the individual statements in UI Query (SQL). Source: references/06-quality.md.
SELECT * FROM trace_bounds;
SELECT upid, pid, name, start_ts, end_ts FROM process ORDER BY upid;
SELECT name FROM sqlite_master
WHERE name GLOB '*heap*' OR name GLOB '*aggregate*' OR name GLOB '*ftrace*'
ORDER BY name;
SELECT id, name FROM counter_track ORDER BY name, id;
SELECT pct.upid, p.pid, p.name AS process_name, pct.id AS track_id, pct.name
FROM process_counter_track pct LEFT JOIN process p USING (upid)
ORDER BY pct.upid, pct.name;
SELECT name, idx, severity, source, value FROM stats
WHERE value <> 0 AND (severity <> 'info' OR name GLOB '*heap*' OR name GLOB '*ftrace*')
ORDER BY severity, name, idx;
-- Only run these after verifying the tables exist in this trace/TP version:
SELECT upid, heap_name, COUNT(*) AS rows, MIN(ts) AS first_ts, MAX(ts) AS last_ts
FROM heap_profile_allocation GROUP BY upid, heap_name;
SELECT upid, graph_sample_ts, COUNT(*) AS objects
FROM heap_graph_object GROUP BY upid, graph_sample_ts;

-- [CANDIDATES] Native 目标候选：upid/pid/name + 目标 heap 的 dump/记录数 + 歧义。
-- 用法：把 params.target_name 改成目标名（不带路径；'memprobe' 可匹配 '/data/memprobe'）。
-- 解析规则：仅当恰好一个候选 data_bearing=1 时用它；否则报"未解析"，不要静默取第一行。
-- 若本机 TP 没有 heap_profile（v57.1），删掉 dumps 子查询，用 activity_dumps 代替。
WITH params AS (
  SELECT 'memprobe' AS target_name, 'libc.malloc' AS target_heap
), cand AS (
  SELECT p.upid, p.pid, p.name, p.start_ts, p.end_ts
  FROM process p, params q
  WHERE p.name = q.target_name OR p.name GLOB '*/' || q.target_name
)
SELECT c.upid, c.pid, c.name,
  (SELECT COUNT(*) FROM heap_profile_allocation a, params q
    WHERE a.upid = c.upid AND a.heap_name = q.target_heap) AS alloc_rows,
  (SELECT COUNT(*) FROM heap_profile_allocation a, params q
    WHERE a.upid = c.upid AND a.heap_name = q.target_heap AND a.size > 0) AS alloc_pos_rows,
  (SELECT COUNT(DISTINCT a.ts) FROM heap_profile_allocation a, params q
    WHERE a.upid = c.upid AND a.heap_name = q.target_heap) AS activity_dumps,
  (SELECT COUNT(*) FROM heap_profile h, params q
    WHERE h.upid = c.upid AND h.heap_name = q.target_heap) AS dumps,
  CASE WHEN (SELECT COUNT(*) FROM heap_profile_allocation a, params q
              WHERE a.upid = c.upid AND a.heap_name = q.target_heap) > 0
       THEN 1 ELSE 0 END AS data_bearing,
  CASE WHEN (SELECT COUNT(DISTINCT a.upid) FROM heap_profile_allocation a, params q
              WHERE a.heap_name = q.target_heap
                AND a.upid IN (SELECT upid FROM cand)) > 1
       THEN 1 ELSE 0 END AS ambiguous
FROM cand c
ORDER BY data_bearing DESC, c.upid;
-- 同名辅助进程是常态：Linux preload 客户端会 fork 一个继承 cmdline 的 heapprofd 子进程，
-- 它通常 data_bearing=0；用户已给出 PID/UPID 时，沿用该值并核对其 identity，
-- 不要因为"另一条记录有数据"而改选。
