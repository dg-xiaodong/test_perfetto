-- 04-cpu-frequency.sql — frequency / idle raw counters as a timeline.
--
-- PRECONDITION: run 04a-frequency-inventory.sql first. An empty result here
-- means the counter was NOT COLLECTED (typical for the scheduling route) and
-- must be reported as UNKNOWN — never as "0 MHz".
-- cpufreq is typically kHz; convert to MHz by /1000. cpuidle 4294967295 means
-- leaving idle (NOT an idle state depth).
SELECT ct.cpu, ct.name AS kind, ct.unit AS raw_unit, c.ts,
       c.value AS raw_value,
       CASE WHEN ct.name = 'cpufreq' THEN c.value / 1000.0 END AS freq_mhz,
       CASE WHEN ct.name = 'cpuidle' AND c.value = 4294967295 THEN 'not-idle'
            WHEN ct.name = 'cpuidle' THEN 'idle-state'
            ELSE 'frequency' END AS meaning
FROM counter c
JOIN cpu_counter_track ct ON ct.id = c.track_id
WHERE ct.name IN ('cpufreq', 'cpuidle')
ORDER BY ct.cpu, c.ts;
