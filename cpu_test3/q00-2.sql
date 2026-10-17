SELECT state,COUNT(*) AS slices FROM thread_state GROUP BY state ORDER BY slices DESC;
