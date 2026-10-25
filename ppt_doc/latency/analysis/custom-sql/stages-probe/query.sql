SELECT stage_id, COUNT(*) n, MIN(dur) min_d, MAX(dur) max_d, AVG(dur) avg_d, COUNT(*)-SUM(CASE WHEN dur>=0 THEN 1 ELSE 0 END) AS open
FROM (SELECT CAST(EXTRACT_ARG(s.arg_set_id,'debug.stage_id') AS TEXT) stage_id, s.dur
 FROM slice s WHERE s.category='rdk.latency' AND s.name='lat.stage') GROUP BY stage_id ORDER BY n DESC;
