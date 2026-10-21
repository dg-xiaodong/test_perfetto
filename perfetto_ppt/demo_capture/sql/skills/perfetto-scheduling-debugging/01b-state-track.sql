-- UI Slice Debug Track: Timestamp=ts, Duration=dur, Name=state, Pivot=utid.
WITH p AS (SELECT {{utid}} AS utid,{{start_ns}} AS a,{{end_ns}} AS b),
w AS (SELECT utid,CASE WHEN a>=0 THEN a ELSE start_ts END AS a,
  CASE WHEN b>=0 THEN b ELSE end_ts END AS b FROM p CROSS JOIN trace_bounds)
SELECT st.id AS state_id,st.utid,MAX(st.ts,w.a) AS ts,
  MIN(st.ts+st.dur,w.b)-MAX(st.ts,w.a) AS dur,st.state,
  CASE WHEN st.ts<w.a OR st.ts+st.dur>w.b THEN 1 ELSE 0 END AS clipped
FROM thread_state st CROSS JOIN w WHERE st.utid=w.utid AND st.dur>0
AND w.b>w.a AND st.ts<w.b AND st.ts+st.dur>w.a ORDER BY ts,state_id;
