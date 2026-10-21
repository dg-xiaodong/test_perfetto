-- NO sched_switch on this kernel: these app counters are the only real
-- thread-state signal in this trace. They are application-level, not scheduler facts.
SELECT c.ts, ct.name AS series, c.value
FROM counter c JOIN process_counter_track ct ON ct.id=c.track_id
JOIN process p ON p.upid=ct.upid
WHERE p.name LIKE '%pf-demo-x5'
  AND ct.name IN ('ThreadsRunning','ThreadsBlocked','SchedWakeupOvershootMs')
ORDER BY ct.name, c.ts LIMIT 300
