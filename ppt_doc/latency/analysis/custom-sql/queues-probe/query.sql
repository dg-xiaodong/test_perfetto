SELECT queue_id, COUNT(*) n, SUM(CASE WHEN dur>=0 THEN 1 ELSE 0 END) closed, MIN(dur) min_d, MAX(dur) max_d, AVG(dur) avg_d
FROM (SELECT CAST(EXTRACT_ARG(s.arg_set_id,'debug.queue_id') AS TEXT) queue_id, s.dur
 FROM slice s WHERE s.category='rdk.latency' AND s.name='lat.queue') GROUP BY queue_id ORDER BY n DESC;
