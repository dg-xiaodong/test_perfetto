-- Timeline of all target-process threads in the burst window: state changes only.
SELECT th.tid,th.name,st.ts/1e6 AS ms,st.dur/1e6 AS dur_ms,st.state,st.cpu,st.waker_utid,st.irq_context
FROM thread_state st JOIN thread th USING(utid)
WHERE th.upid IN (197,199) AND st.dur>0 AND st.ts<196175000000 AND st.ts+st.dur>196035000000
ORDER BY st.ts;
