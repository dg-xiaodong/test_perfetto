WITH b AS (SELECT 1000000000 AS ns, ts/1000000000 AS sec, ct.cpu AS cpu, c.value AS khz
           FROM counter c JOIN cpu_counter_track ct ON ct.id=c.track_id WHERE ct.name='cpufreq')
SELECT sec, MIN(khz)/1000.0 AS min_mhz, MAX(khz)/1000.0 AS max_mhz, COUNT(*) AS samples, GROUP_CONCAT(DISTINCT CAST(khz/1000 AS INT)) AS levels
FROM b GROUP BY sec ORDER BY sec;
