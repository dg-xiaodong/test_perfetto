-- Inventory: execute first, confirm target UPID and available data. No guessing by PID/name.
SELECT start_ts,end_ts,(end_ts-start_ts)/1e9 AS duration_s FROM trace_bounds;
SELECT p.upid,p.pid,p.name AS process_name,COUNT(DISTINCT s.id) AS running_slices,
       ROUND(SUM(CASE WHEN s.dur>0 THEN s.dur ELSE 0 END)/1e6,2) AS cpu_ms
FROM process p JOIN thread th ON th.upid=p.upid
LEFT JOIN sched_slice s ON s.utid=th.utid
GROUP BY p.upid,p.pid,p.name
HAVING running_slices>0 ORDER BY cpu_ms DESC LIMIT 30;
SELECT state,COUNT(*) AS slices FROM thread_state GROUP BY state ORDER BY slices DESC;
SELECT name,COUNT(*) AS tracks FROM cpu_counter_track GROUP BY name;
SELECT name,value,severity FROM stats WHERE value<>0 AND severity <> 'info' ORDER BY name;
-- If perf_sample table doesn't exist in this TP build, skip this independent statement.
-- SELECT COUNT(*) AS samples FROM perf_sample;
