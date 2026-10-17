-- Task Q3: who issues the wakeups for spike-worker (via thread_state.waker_utid).
SELECT w.utid AS waker_utid, w.tid AS waker_tid, w.name AS waker_thread,
       COUNT(*) AS wakeups, ROUND(AVG(st.dur)/1e3, 1) AS avg_wait_us_before_run
FROM thread_state st LEFT JOIN thread w ON w.utid = st.waker_utid
WHERE st.utid = 206 AND st.state = 'R' AND st.dur > 0
GROUP BY w.utid ORDER BY wakeups DESC;
