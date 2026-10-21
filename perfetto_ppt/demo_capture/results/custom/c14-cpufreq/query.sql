-- CPU frequency polling (linux.sys_stats cpufreq_period_ms=500). Empty != 0 MHz.
SELECT c.ts, ct.cpu, c.value/1000.0 AS freq_mhz
FROM counter c JOIN cpu_counter_track ct ON ct.id=c.track_id
WHERE ct.name='cpufreq' ORDER BY c.ts, ct.cpu
