-- Task Q3: what wakes spike-worker. NOTE: this TP build exposes no sched_waking table
-- (raw ftrace has 1222 sched_waking events, but only intrinsic tables exist), so the
-- wakeup->run path is read from thread_state (R rows + waker_utid) instead.
SELECT COUNT(*) AS runnable_intervals,
       ROUND(SUM(dur)/1e3, 1) AS runnable_total_us,
       ROUND(MAX(dur)/1e3, 1) AS max_runnable_us,
       GROUP_CONCAT(DISTINCT COALESCE(CAST(waker_utid AS TEXT), 'null')) AS wakers
FROM thread_state WHERE utid = 206 AND state = 'R' AND dur > 0;
