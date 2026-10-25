SELECT t.name, COUNT(*) n, MIN(s.ts) mn, MAX(s.ts) mx
FROM slice s JOIN track t ON t.id=s.track_id
WHERE s.category='rdk.latency' AND s.name='lat.request'
GROUP BY t.name ORDER BY n DESC;
