SELECT r.ts, r.name, r.cpu, r.utid, r.arg_set_id, a.key, a.string_value, a.int_value
FROM raw r LEFT JOIN args a ON a.arg_set_id=r.arg_set_id
WHERE r.ts BETWEEN 46328815000000 AND 46328900000000 AND r.name IN ('sched_waking','sched_switch')
ORDER BY r.ts LIMIT 40;
