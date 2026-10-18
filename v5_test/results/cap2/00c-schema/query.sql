-- Check actual column availability; missing fields are not silently invented.
SELECT 'thread_state' AS table_name,name,type FROM pragma_table_info('thread_state')
UNION ALL SELECT 'perf_sample',name,type FROM pragma_table_info('perf_sample')
UNION ALL SELECT 'ftrace_event',name,type FROM pragma_table_info('ftrace_event');
