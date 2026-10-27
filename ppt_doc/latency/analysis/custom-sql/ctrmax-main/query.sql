SELECT t.name, MAX(c.value) AS max_depth, MIN(c.value) AS min_depth, COUNT(*) AS n
FROM counter c JOIN counter_track t ON t.id=c.track_id
WHERE t.name LIKE 'lat.queue_depth%' GROUP BY t.name;
