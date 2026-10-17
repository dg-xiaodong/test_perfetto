SELECT s.cpu AS cpu, th.name AS tname, th.upid AS upid, ROUND(SUM(s.dur)/1e6,1) AS ms, COUNT(*) AS n
FROM sched_slice s JOIN thread th USING(utid)
WHERE s.cpu IN (6,7) AND s.dur>0
GROUP BY s.cpu, th.name, th.upid ORDER BY cpu, ms DESC LIMIT 30;
