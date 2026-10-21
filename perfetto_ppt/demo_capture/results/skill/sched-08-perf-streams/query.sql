-- IDs are data-derived, NOT config source ordering. Check the associated timebase.
SELECT perf_session_id,COUNT(*) AS samples,
 SUM(CASE WHEN callsite_id IS NOT NULL THEN 1 ELSE 0 END) AS with_stack,
 SUM(CASE WHEN COALESCE(unwind_error,'')!='' THEN 1 ELSE 0 END) AS unwind_errors,
 MIN(ts) AS first_ts,MAX(ts) AS last_ts
FROM perf_sample GROUP BY perf_session_id ORDER BY perf_session_id;
