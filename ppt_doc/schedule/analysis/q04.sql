-- Individual Runnable intervals; not application queue waiting.
WITH p AS (SELECT 210 AS utid,-1 AS a,-1 AS b),
w AS (SELECT utid,CASE WHEN a>=0 THEN a ELSE start_ts END AS a,
 CASE WHEN b>=0 THEN b ELSE end_ts END AS b FROM p CROSS JOIN trace_bounds)
SELECT st.id,st.utid,st.ts,st.dur,st.state,st.waker_utid,st.waker_id,st.irq_context,
 MIN(st.ts+st.dur,w.b)-MAX(st.ts,w.a) AS overlap_ns
FROM thread_state st CROSS JOIN w WHERE st.utid=w.utid AND st.state IN ('R','R+')
AND st.dur>0 AND w.b>w.a AND st.ts<w.b AND st.ts+st.dur>w.a ORDER BY st.dur DESC;
