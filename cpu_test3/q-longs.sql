SELECT st.ts AS ts, st.dur AS dur, st.state AS state
FROM thread_state st JOIN thread th USING(utid)
WHERE th.upid=3 AND th.tid=10289 AND st.dur>60000000 ORDER BY st.ts;
