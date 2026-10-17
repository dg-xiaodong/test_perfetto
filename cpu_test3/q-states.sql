SELECT th.tid AS tid, st.ts AS ts, st.dur AS dur, st.state AS state
FROM thread_state st JOIN thread th USING(utid) WHERE th.upid=3 AND st.dur>0 ORDER BY st.ts;
