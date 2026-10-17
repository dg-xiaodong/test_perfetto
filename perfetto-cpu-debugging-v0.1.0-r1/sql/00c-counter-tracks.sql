-- 00c — step 4/5: which CPU counters were actually collected.
-- An empty result for 'cpufreq' means frequency data is UNKNOWN (not 0 MHz).
-- Run separately (single SELECT): query -f sql/00c-counter-tracks.sql <trace>.pftrace
SELECT name, COUNT(*) AS tracks
FROM cpu_counter_track
GROUP BY name
ORDER BY tracks DESC;
