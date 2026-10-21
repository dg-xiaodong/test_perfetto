-- One row per observed S/D/I interval, NOT per business request or lock.
-- A wakeup means eligible to run; it does not prove lock acquired/condition true.
-- Incomplete episodes are retained; no nearest unrelated future Running pairing.
WITH p AS (SELECT 213 AS utid,-1 AS a,-1 AS b),
w AS (SELECT utid,CASE WHEN a>=0 THEN a ELSE start_ts END AS a,
 CASE WHEN b>=0 THEN b ELSE end_ts END AS b FROM p CROSS JOIN trace_bounds),
o AS (SELECT st.*,
 LAG(state) OVER (ORDER BY ts,id) AS prev_state,
 LAG(ts+dur) OVER (ORDER BY ts,id) AS prev_end,
 LAG(cpu) OVER (ORDER BY ts,id) AS prev_cpu,
 LEAD(id) OVER (ORDER BY ts,id) AS r_id,
 LEAD(ts) OVER (ORDER BY ts,id) AS r_ts,
 LEAD(dur) OVER (ORDER BY ts,id) AS r_dur,
 LEAD(state) OVER (ORDER BY ts,id) AS r_state,
 LEAD(waker_utid) OVER (ORDER BY ts,id) AS r_waker,
 LEAD(ts,2) OVER (ORDER BY ts,id) AS run_ts,
 LEAD(state,2) OVER (ORDER BY ts,id) AS run_state,
 LEAD(cpu,2) OVER (ORDER BY ts,id) AS run_cpu
 FROM thread_state st WHERE st.utid=(SELECT utid FROM p))
SELECT o.id AS wait_id,o.utid,o.state,o.ts AS sleep_start_ts,
 CASE WHEN o.dur>0 THEN o.dur END AS sleep_ns,
 CASE WHEN o.r_state IN ('R','R+') AND o.r_ts=o.ts+o.dur THEN o.r_ts END AS wake_ts,
 CASE WHEN o.r_state IN ('R','R+') AND o.r_ts=o.ts+o.dur AND o.r_dur>=0
 AND o.run_state='Running' AND o.run_ts=o.r_ts+o.r_dur THEN o.run_ts END AS run_ts,
 CASE WHEN o.r_state IN ('R','R+') AND o.r_ts=o.ts+o.dur AND o.r_dur>=0
 AND o.run_state='Running' AND o.run_ts=o.r_ts+o.r_dur THEN o.r_dur END AS runnable_ns,
 o.r_id AS runnable_state_id,o.r_waker AS waker_utid,o.prev_cpu AS switch_cpu,o.run_cpu,
 CASE WHEN o.prev_state!='Running' OR o.prev_state IS NULL OR o.prev_end!=o.ts THEN 'START_CENSORED'
 WHEN o.dur<=0 OR o.r_state NOT IN ('R','R+') OR o.r_state IS NULL OR o.r_ts!=o.ts+o.dur
 OR o.r_dur<0 OR o.run_state!='Running' OR o.run_state IS NULL OR o.run_ts!=o.r_ts+o.r_dur
 THEN 'END_INCOMPLETE'
 WHEN o.ts<w.a OR o.run_ts>w.b THEN 'WINDOW_CLIPPED' ELSE 'COMPLETE' END AS boundary_status
FROM o CROSS JOIN w WHERE o.state IN ('S','D','I') AND o.ts<w.b
AND (o.dur=-1 OR o.ts+o.dur>w.a) AND w.b>w.a ORDER BY o.ts,o.id;
