-- Per-phase CPU frequency (linux.sys_stats cpufreq polling, 500 ms) and
-- per-CPU utilization derived from cpustat cumulative deltas.
WITH ph AS (
  SELECT s.ts AS start_ts, LEAD(s.ts) OVER (ORDER BY s.ts) AS end_ts,
         EXTRACT_ARG(s.arg_set_id,'debug.cycle') AS cycle,
         EXTRACT_ARG(s.arg_set_id,'debug.phase') AS phase
  FROM slice s WHERE s.name='PhaseChange'
), ph2 AS (
  SELECT cycle, phase, start_ts, COALESCE(end_ts,(SELECT end_ts FROM trace_bounds)) AS end_ts FROM ph
)
SELECT ph2.cycle, ph2.phase,
  ROUND((SELECT AVG(value) FROM counter c JOIN cpu_counter_track ct ON ct.id=c.track_id
         WHERE ct.name='cpufreq' AND c.ts>=ph2.start_ts AND c.ts<ph2.end_ts)/1000.0,0) AS freq_avg_mhz,
  ROUND((SELECT MAX(value) FROM counter c JOIN cpu_counter_track ct ON ct.id=c.track_id
         WHERE ct.name='cpufreq' AND c.ts>=ph2.start_ts AND c.ts<ph2.end_ts)/1000.0,0) AS freq_max_mhz,
  ROUND((SELECT AVG(value) FROM counter c JOIN cpu_counter_track ct ON ct.id=c.track_id
         WHERE ct.name='cpu.times.user_ns' AND c.ts>=ph2.start_ts AND c.ts<ph2.end_ts),0) AS user_ns_avg,
  ROUND((SELECT AVG(value) FROM counter c JOIN cpu_counter_track ct ON ct.id=c.track_id
         WHERE ct.name='cpu.times.idle_ns' AND c.ts>=ph2.start_ts AND c.ts<ph2.end_ts)/1e9,1) AS idle_s_avg
FROM ph2 ORDER BY ph2.start_ts
