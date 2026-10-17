-- 18-data-quality.sql
-- Run BEFORE interpreting any chart. Separate "capture succeeded" from
-- "target data is complete" and from "evidence supports a conclusion".
SELECT * FROM trace_bounds;

-- Non-zero diagnostics; some info-level counters are normal.
SELECT name, idx, severity, source, value
FROM stats
WHERE value <> 0
  AND (severity <> 'info'
       OR name GLOB '*heap*'
       OR name GLOB '*ftrace*'
       OR name GLOB '*perf*')
ORDER BY severity, name;

-- Which event types actually arrived (not merely configured).
SELECT name, COUNT(*) AS events
FROM ftrace_event
GROUP BY name
ORDER BY events DESC
LIMIT 40;

-- Which data sources actually produced rows.
SELECT 'sched_slice' AS table_name, COUNT(*) AS rows FROM sched_slice
UNION ALL SELECT 'thread_state', COUNT(*) FROM thread_state
UNION ALL SELECT 'perf_sample', COUNT(*) FROM perf_sample
UNION ALL SELECT 'heap_profile', COUNT(*) FROM heap_profile
UNION ALL SELECT 'heap_profile_allocation', COUNT(*) FROM heap_profile_allocation;

-- Upstream heapprofd visibility (v57.1 collector may give dur=0).
-- If heap_profile is absent in an older TP, use sql/10-native-dump-capability.sql.
WITH params AS (SELECT -1 AS target_upid, 'libc.malloc' AS target_heap)
SELECT h.ts, h.ts_end, h.dur, h.upid, h.heap_name
FROM heap_profile h, params p
WHERE h.upid = p.target_upid AND h.heap_name = p.target_heap
ORDER BY h.ts_end;
