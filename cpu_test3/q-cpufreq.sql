SELECT ct.cpu AS cpu, c.ts AS ts, c.value AS raw_value
FROM counter c JOIN cpu_counter_track ct ON ct.id=c.track_id
WHERE ct.name='cpufreq' ORDER BY ct.cpu, c.ts;
