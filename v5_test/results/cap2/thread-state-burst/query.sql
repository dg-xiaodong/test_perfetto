-- Per-thread state decomposition, daemon(upid 1)+helper(upid 2), cap2 burst window.
WITH t AS (SELECT utid FROM thread WHERE upid IN (1,2)),
x AS (SELECT st.utid,st.state,MIN(st.ts+st.dur,436171000000)-MAX(st.ts,436039000000) AS n
      FROM thread_state st JOIN t USING(utid)
      WHERE st.dur>0 AND st.ts<436171000000 AND st.ts+st.dur>436039000000)
SELECT th.tid,th.name,x.state,SUM(x.n)/1e6 AS ms
FROM x JOIN thread th USING(utid) GROUP BY th.tid,th.name,x.state ORDER BY th.tid, ms DESC;
