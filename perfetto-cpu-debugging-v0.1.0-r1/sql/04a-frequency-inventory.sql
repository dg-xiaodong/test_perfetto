-- 04a — frequency acceptance gate. RUN THIS BEFORE 04-cpu-frequency.sql.
--
-- Why: the scheduling route does not collect CPU frequency, so an empty result
-- from 04-cpu-frequency.sql is EXPECTED there and means UNKNOWN — it is never
-- evidence that the CPU ran at 0 MHz. Only a cpufreq counter track WITH samples
-- inside the analysis window supports a frequency statement.
--
-- Unit: cpufreq raw counter values are kHz in this data source; the timeline SQL
-- divides by 1000 to print MHz. cpuidle values are state depths, except
-- 4294967295 which means "left idle" (not a depth).
--
-- Run separately (single SELECT):
--   trace_processor_shell query -f sql/04a-frequency-inventory.sql <trace>.pftrace
WITH ft AS (
  SELECT COUNT(*) AS tracks,
         COUNT(DISTINCT cpu) AS cpus,
         GROUP_CONCAT(DISTINCT unit) AS units
  FROM cpu_counter_track
  WHERE name = 'cpufreq'
),
fs AS (
  SELECT COUNT(*) AS samples, MIN(c.ts) AS first_ts, MAX(c.ts) AS last_ts
  FROM counter c
  WHERE c.track_id IN (SELECT id FROM cpu_counter_track WHERE name = 'cpufreq')
),
it AS (
  SELECT COUNT(*) AS tracks FROM cpu_counter_track WHERE name = 'cpuidle'
)
SELECT ft.tracks AS freq_tracks,
       ft.cpus AS freq_cpus,
       ft.units AS freq_units,
       fs.samples AS freq_samples,
       fs.first_ts,
       fs.last_ts,
       it.tracks AS cpuidle_tracks,
       CASE
         WHEN ft.tracks = 0
           THEN 'UNKNOWN: no cpufreq counter track -> frequency not collected (do NOT read as 0 MHz)'
         WHEN fs.samples = 0
           THEN 'UNKNOWN: cpufreq track exists but no samples in this trace'
         WHEN fs.samples = 1
           THEN 'WEAK: single cpufreq sample (initial value only, no trend)'
         ELSE 'OK: freq samples present; raw unit is kHz (/1000 for MHz); confirm window coverage'
       END AS verdict
FROM ft CROSS JOIN fs CROSS JOIN it;
