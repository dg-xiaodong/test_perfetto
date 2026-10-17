SELECT r.ts AS ts, r.cpu AS cpu, w.name AS waker_thread, w.tid AS waker_tid, r.utid AS waker_utid
FROM raw r
JOIN args a ON a.arg_set_id=r.arg_set_id AND a.key='pid' AND a.int_value=10289
LEFT JOIN thread w ON w.utid=r.utid
WHERE r.name='sched_waking' AND r.ts BETWEEN 46328800000000 AND 46329000000000
ORDER BY r.ts;
