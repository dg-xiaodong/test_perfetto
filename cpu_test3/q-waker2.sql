SELECT COALESCE(w.name,'swapper/idle') AS waker, COUNT(*) AS n
FROM raw r
JOIN args a ON a.arg_set_id=r.arg_set_id AND a.key='pid' AND a.int_value=10289
LEFT JOIN thread w ON w.utid=r.utid
WHERE r.name='sched_waking'
GROUP BY waker ORDER BY n DESC;
