-- 1-second buckets of sampled on-CPU activity per thread: locates the CPU_BURST window.
WITH target AS (SELECT upid FROM process WHERE name LIKE '%pf-demo-x5' LIMIT 1),
b AS (SELECT (ps.ts/1000000000)*1000000000 AS bucket, th.name AS thread_name, COUNT(*) AS samples
      FROM perf_sample ps JOIN thread th USING(utid), target
      WHERE th.upid=target.upid GROUP BY bucket, thread_name)
SELECT bucket, thread_name, samples FROM b ORDER BY bucket, samples DESC
