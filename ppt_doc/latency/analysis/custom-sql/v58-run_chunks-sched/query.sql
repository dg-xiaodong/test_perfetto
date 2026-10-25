WITH slow AS (
 SELECT s.id sid, s.ts, s.dur FROM slice s
 WHERE s.category='rdk.latency' AND s.name='lat.stage' AND s.dur>50000000
), run AS (
 SELECT sl.sid, ts.dur FROM slow sl JOIN thread_state ts
 WHERE ts.utid=5 AND ts.state='Running' AND ts.ts < sl.ts+sl.dur AND ts.ts+ts.dur > sl.ts
)
SELECT COUNT(*) n, ROUND(MIN(dur)/1e3,1) min_us,
 ROUND((SELECT dur FROM run ORDER BY dur LIMIT 1 OFFSET (SELECT COUNT(*) FROM run)/2)/1e3,1) median_us,
 ROUND(AVG(dur)/1e3,1) avg_us, ROUND(MAX(dur)/1e3,1) max_us,
 SUM(CASE WHEN dur>1000000 THEN 1 ELSE 0 END) gt_1ms
FROM run;
