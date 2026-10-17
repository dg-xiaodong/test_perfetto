WITH sec AS (SELECT CAST((s.ts - (SELECT start_ts FROM trace_bounds))/1e9 AS INT) AS sec,
                    s.cpu AS cpu, s.dur AS dur
             FROM sched_slice s JOIN thread th USING(utid) WHERE th.tid!=0 AND s.dur>0)
SELECT sec, ROUND(SUM(CASE WHEN cpu=6 THEN dur ELSE 0 END)/1e6,1) AS cpu6_ms,
            ROUND(SUM(CASE WHEN cpu=7 THEN dur ELSE 0 END)/1e6,1) AS cpu7_ms
FROM sec GROUP BY sec ORDER BY sec;
