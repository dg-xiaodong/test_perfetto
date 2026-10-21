-- Per-8s-phase metrics: joins app counters and slice activity to the phase timeline.
-- Phase boundaries come from real PhaseChange instants (debug.phase/debug.cycle).
WITH ph AS (
  SELECT s.ts AS start_ts,
         LEAD(s.ts) OVER (ORDER BY s.ts) AS end_ts,
         EXTRACT_ARG(s.arg_set_id,'debug.cycle') AS cycle,
         EXTRACT_ARG(s.arg_set_id,'debug.phase') AS phase
  FROM slice s WHERE s.name='PhaseChange'
), ph2 AS (
  SELECT cycle, phase, start_ts, COALESCE(end_ts,(SELECT end_ts FROM trace_bounds)) AS end_ts FROM ph
), ctr AS (
  SELECT ct.name, c.ts, c.value
  FROM counter c JOIN process_counter_track ct ON ct.id=c.track_id
  JOIN process p ON p.upid=ct.upid WHERE p.name LIKE '%pf-demo-x5'
)
SELECT ph2.cycle, ph2.phase,
  ROUND((ph2.end_ts-ph2.start_ts)/1e9,2) AS dur_s,
  ROUND((SELECT AVG(value) FROM ctr WHERE name='QueueDepth' AND ts>=ph2.start_ts AND ts<ph2.end_ts),1) AS qdepth_avg,
  (SELECT MAX(value) FROM ctr WHERE name='QueueDepth' AND ts>=ph2.start_ts AND ts<ph2.end_ts) AS qdepth_max,
  (SELECT MAX(value) FROM ctr WHERE name='InflightFrames' AND ts>=ph2.start_ts AND ts<ph2.end_ts) AS inflight_max,
  ROUND((SELECT MAX(value) FROM ctr WHERE name='EndToEndLatencyMs' AND ts>=ph2.start_ts AND ts<ph2.end_ts),1) AS e2e_max_ms,
  ROUND((SELECT AVG(value) FROM ctr WHERE name='ThreadsRunning' AND ts>=ph2.start_ts AND ts<ph2.end_ts),2) AS running_avg,
  ROUND((SELECT MAX(value) FROM ctr WHERE name='SchedWakeupOvershootMs' AND ts>=ph2.start_ts AND ts<ph2.end_ts),2) AS wakeup_overshoot_max_ms,
  ROUND((SELECT MAX(value) FROM ctr WHERE name='RssKb' AND ts>=ph2.start_ts AND ts<ph2.end_ts)/1024.0,1) AS rss_max_mb,
  ROUND((SELECT MAX(value) FROM ctr WHERE name='LiveAllocatedBytes' AND ts>=ph2.start_ts AND ts<ph2.end_ts)/1048576.0,2) AS live_alloc_max_mb,
  (SELECT COUNT(*) FROM slice WHERE name LIKE 'contend.%' AND ts>=ph2.start_ts AND ts<ph2.end_ts) AS contend_slices,
  (SELECT COUNT(*) FROM slice WHERE name='InferenceStub' AND ts>=ph2.start_ts AND ts<ph2.end_ts) AS infer_slices,
  (SELECT COUNT(*) FROM perf_sample ps JOIN thread th USING(utid) WHERE th.name LIKE 'pf-%' AND ps.ts>=ph2.start_ts AND ps.ts<ph2.end_ts) AS target_perf_samples
FROM ph2 ORDER BY ph2.start_ts
