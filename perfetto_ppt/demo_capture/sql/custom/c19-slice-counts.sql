-- Raw capability count: which tables actually have rows in this trace.
SELECT 'slice' AS t, COUNT(*) AS n FROM slice
UNION ALL SELECT 'sched_slice', COUNT(*) FROM sched_slice
UNION ALL SELECT 'thread_state', COUNT(*) FROM thread_state
UNION ALL SELECT 'flow', COUNT(*) FROM flow
UNION ALL SELECT 'counter', COUNT(*) FROM counter
UNION ALL SELECT 'perf_sample', COUNT(*) FROM perf_sample
UNION ALL SELECT 'heap_profile_allocation', COUNT(*) FROM heap_profile_allocation
UNION ALL SELECT 'ftrace_event', COUNT(*) FROM ftrace_event
UNION ALL SELECT 'thread', COUNT(*) FROM thread
UNION ALL SELECT 'process', COUNT(*) FROM process
