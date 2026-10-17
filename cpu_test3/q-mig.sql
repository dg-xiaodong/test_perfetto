SELECT t.name AS thread, COUNT(*) AS migrates
FROM raw r
JOIN args a ON a.arg_set_id=r.arg_set_id AND a.key='pid'
JOIN thread t ON t.tid=a.int_value AND t.upid=3
WHERE r.name='sched_migrate_task'
GROUP BY t.name ORDER BY migrates DESC;
