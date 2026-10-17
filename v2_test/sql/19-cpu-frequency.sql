-- 19-cpu-frequency.sql
-- CPU frequency timeline; use it to reject a DVFS confound before blaming the app.
-- Units depend on the board's cpufreq driver (often kHz). Inspect the raw value
-- and track unit before converting; this query assumes kHz -> MHz.
SELECT c.ts, ct.name, ct.cpu, c.value / 1000.0 AS mhz
FROM counter c
JOIN cpu_counter_track ct ON ct.id = c.track_id
WHERE ct.cpu IS NOT NULL
  AND (ct.name GLOB '*freq*' OR ct.name GLOB '*Freq*')
ORDER BY c.ts, ct.cpu;
