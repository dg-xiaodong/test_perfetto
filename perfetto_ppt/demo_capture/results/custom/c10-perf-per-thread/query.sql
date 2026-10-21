-- Which of the target's threads were sampled (on-CPU proxy), and the sample count.
WITH target AS (SELECT upid FROM process WHERE name LIKE '%pf-demo-x5' LIMIT 1)
SELECT th.name AS thread_name, th.tid, COUNT(*) AS samples,
       ROUND(100.0*COUNT(*)/(SELECT COUNT(*) FROM perf_sample ps2 JOIN thread t2 USING(utid), target
                             WHERE t2.upid=target.upid),2) AS pct_of_target_samples
FROM perf_sample ps JOIN thread th USING(utid), target
WHERE th.upid=target.upid
GROUP BY th.utid ORDER BY samples DESC
