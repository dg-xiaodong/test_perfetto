SELECT st.ts AS ts, st.dur AS dur, st.state AS state, st.io_wait AS io_wait,
       st.blocked_function AS blocked_fn, st.waker_utid AS waker, st.irq_context AS irq
FROM thread_state st JOIN thread th USING(utid)
WHERE th.upid=3 AND th.tid=10289 AND st.dur>3000000 ORDER BY st.ts;
