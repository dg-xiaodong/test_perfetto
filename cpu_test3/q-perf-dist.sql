SELECT p.name AS process_name, th.name AS thread_name, COUNT(*) AS samples,
       SUM(CASE WHEN ps.callsite_id IS NULL THEN 1 ELSE 0 END) AS null_callsite
FROM perf_sample ps
JOIN thread th ON th.utid=ps.utid
JOIN process p ON p.upid=th.upid
GROUP BY p.name, th.name ORDER BY samples DESC LIMIT 20;
