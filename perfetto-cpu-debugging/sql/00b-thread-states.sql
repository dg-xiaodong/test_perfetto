-- 00b — step 3/5: which thread_state codes actually exist in this trace.
-- Run separately (single SELECT): query -f sql/00b-thread-states.sql <trace>.pftrace
SELECT state, COUNT(*) AS slices
FROM thread_state
GROUP BY state
ORDER BY slices DESC;
