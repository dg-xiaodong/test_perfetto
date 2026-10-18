SELECT th.tid,th.name,st.state,SUM(st.dur)/1e6 AS ms,COUNT(*) AS n_int
FROM thread_state st JOIN thread th USING(utid) WHERE th.upid IN (197,199) AND st.dur>0
GROUP BY th.tid,th.name,st.state ORDER BY th.tid, ms DESC;
