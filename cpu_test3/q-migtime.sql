SELECT r.ts AS ts, t.name AS thread, a2.int_value AS orig_cpu, a3.int_value AS dest_cpu
FROM raw r
JOIN args a ON a.arg_set_id=r.arg_set_id AND a.key='pid'
JOIN thread t ON t.tid=a.int_value AND t.upid=3
LEFT JOIN args a2 ON a2.arg_set_id=r.arg_set_id AND a2.key='orig_cpu'
LEFT JOIN args a3 ON a3.arg_set_id=r.arg_set_id AND a3.key='dest_cpu'
WHERE r.name='sched_migrate_task' ORDER BY r.ts LIMIT 20;
