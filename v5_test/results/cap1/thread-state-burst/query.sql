-- Per-thread state decomposition, target process + helper, inside the burst window.
WITH t AS (SELECT utid FROM thread WHERE upid IN (197,199)),
x AS (SELECT st.utid,st.state,MIN(st.ts+st.dur,196171000000)-MAX(st.ts,196039000000) AS n
      FROM thread_state st JOIN t USING(utid)
      WHERE st.dur>0 AND st.ts<196171000000 AND st.ts+st.dur>196039000000)
SELECT th.tid,th.name, x.state, SUM(x.n)/1e6 AS ms, COUNT(*) AS n_int
FROM x JOIN thread th USING(utid) GROUP BY th.tid,th.name,x.state
ORDER BY th.tid, ms DESC;
