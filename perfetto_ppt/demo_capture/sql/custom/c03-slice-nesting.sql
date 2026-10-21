-- Nesting check: how many child slices, max depth, and leaf vs parent totals.
WITH target AS (SELECT upid FROM process WHERE name LIKE '%pf-demo-x5' LIMIT 1)
SELECT s.category, s.name, s.depth, COUNT(*) AS n,
       ROUND(SUM(s.dur)/1e6,2) AS total_ms
FROM slice s JOIN thread_track tt ON tt.id=s.track_id
JOIN thread t ON t.utid=tt.utid, target
WHERE t.upid=target.upid AND s.category IN ('pipeline','memory','sync','io')
GROUP BY s.category, s.name, s.depth
ORDER BY s.category, s.depth, total_ms DESC LIMIT 80
