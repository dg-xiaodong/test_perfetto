-- Largest Runnable intervals, all target-process/helper threads, burst window.
SELECT th.tid,th.name,st.id,st.ts,st.dur/1e6 AS dur_ms,st.state,st.cpu,st.waker_utid,st.irq_context
FROM thread_state st JOIN thread th USING(utid)
WHERE th.upid IN (197,199) AND st.state IN ('R','R+') AND st.dur>0
AND st.ts<196200000000 AND st.ts+st.dur>196000000000
ORDER BY st.dur DESC LIMIT 25;
