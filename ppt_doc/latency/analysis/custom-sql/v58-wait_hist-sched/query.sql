WITH slow AS (
 SELECT s.id sid, s.ts, s.dur FROM slice s
 WHERE s.category='rdk.latency' AND s.name='lat.stage' AND s.dur>50000000
), sst AS (
 SELECT sl.sid, ts.ts, ts.dur, ts.state FROM slow sl JOIN thread_state ts
 WHERE ts.utid=5 AND ts.ts < sl.ts+sl.dur AND ts.ts+ts.dur > sl.ts AND ts.state IN ('S','R','Running')
)
SELECT state, COUNT(*) n, ROUND(MIN(dur)/1e3,1) min_us, ROUND(AVG(dur)/1e3,1) avg_us,
       ROUND(MAX(dur)/1e3,1) max_us,
       SUM(CASE WHEN state='S' AND dur>4900000 AND dur<5200000 THEN 1 ELSE 0 END) in_4p9_5p2ms
FROM sst GROUP BY state;
