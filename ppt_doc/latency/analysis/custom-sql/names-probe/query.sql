SELECT s.name, COUNT(*) AS n, SUM(CASE WHEN s.dur=-1 THEN 1 ELSE 0 END) AS open, MIN(s.dur) AS min_dur, MAX(s.dur) AS max_dur
FROM slice s WHERE s.category='rdk.latency' GROUP BY s.name ORDER BY n DESC;
