-- Per-CPU time counters (linux.sys_stats STAT_CPU_TIMES): cumulative ns.
-- Utilization must be computed as deltas, never from a single absolute sample.
SELECT c.ts, ct.cpu, ct.name, c.value/1e6 AS value_ms
FROM counter c JOIN cpu_counter_track ct ON ct.id=c.track_id
WHERE ct.name LIKE 'cpu.times.%' ORDER BY ct.name, ct.cpu, c.ts LIMIT 400
