-- Task Q2: whole-system per-CPU busy share over the trace window (skill sql/08).
WITH p AS (SELECT -1 AS start_ts,-1 AS end_ts),
b AS (SELECT CASE WHEN p.start_ts>=0 THEN p.start_ts ELSE t.start_ts END AS t0,
             CASE WHEN p.end_ts>=0 THEN p.end_ts ELSE t.end_ts END AS t1
      FROM p CROSS JOIN trace_bounds t)
SELECT s.cpu,
       ROUND(SUM(MIN(s.ts+s.dur,b.t1)-MAX(s.ts,b.t0))/1e6,1) AS busy_ms,
       ROUND(100.0*SUM(MIN(s.ts+s.dur,b.t1)-MAX(s.ts,b.t0))/(b.t1-b.t0),2) AS busy_pct
FROM sched_slice s JOIN thread th USING(utid) CROSS JOIN b
WHERE th.tid!=0 AND s.dur>0 AND b.t1>b.t0 AND s.ts<b.t1 AND s.ts+s.dur>b.t0
GROUP BY s.cpu ORDER BY s.cpu;
