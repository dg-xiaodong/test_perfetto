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
