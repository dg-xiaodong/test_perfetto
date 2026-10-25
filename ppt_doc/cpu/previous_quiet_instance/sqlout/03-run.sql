-- Longest runnable waits, NOT sleeps. Runnable time is only a scheduler-wait proxy.
-- Requires sched_switch + wakeup/waking to reconstruct thread_state; otherwise UNKNOWN.
-- Set target_upid; optional threshold_ms. We require R or R+ state exactly.
WITH p AS (SELECT 188 AS target_upid,1.0 AS threshold_ms),
rows AS (
 SELECT th.utid, th.tid,th.name AS thread_name,st.ts,st.dur,st.state,
        st.waker_utid, st.irq_context
 FROM thread_state st JOIN thread th USING(utid) CROSS JOIN p
 WHERE th.upid=p.target_upid AND st.state IN ('R','R+') AND st.dur>0
   AND st.dur>=p.threshold_ms*1000000
)
SELECT utid,tid,thread_name,ts,dur,
       ROUND(dur/1e6,3) AS runnable_wait_ms,state,waker_utid,irq_context
FROM rows ORDER BY dur DESC LIMIT 100;
