-- Per-thread stage wall duration (P11). Wall time, not CPU time.
WITH target AS (SELECT upid FROM process WHERE name LIKE '%pf-demo-x5' LIMIT 1)
SELECT t.name AS thread_name, s.name AS stage, COUNT(*) AS n,
       ROUND(SUM(s.dur)/1e6,2) AS total_ms,
       ROUND(AVG(s.dur)/1e6,3) AS avg_ms,
       ROUND(MAX(s.dur)/1e6,2) AS max_ms
FROM slice s JOIN thread_track tt ON tt.id=s.track_id
JOIN thread t ON t.utid=tt.utid, target
WHERE t.upid=target.upid AND s.dur>0
  AND s.category IN ('pipeline','memory','sync','io')
GROUP BY t.name, s.name ORDER BY total_ms DESC LIMIT 60
