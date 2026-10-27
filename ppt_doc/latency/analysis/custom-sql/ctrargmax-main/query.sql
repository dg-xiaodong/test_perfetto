SELECT c.ts, c.value FROM counter c JOIN counter_track t ON t.id=c.track_id
WHERE t.name='lat.queue_depth.q_out' AND c.value>=53 ORDER BY c.ts;
