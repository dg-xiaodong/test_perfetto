SELECT p.upid,p.pid,p.name AS process_name,COUNT(DISTINCT s.id) AS running_slices,
       ROUND(SUM(CASE WHEN s.dur>0 THEN s.dur ELSE 0 END)/1e6,2) AS cpu_ms
FROM process p JOIN thread th ON th.upid=p.upid
LEFT JOIN sched_slice s ON s.utid=th.utid
GROUP BY p.upid,p.pid,p.name
HAVING running_slices>0 ORDER BY cpu_ms DESC LIMIT 30;
