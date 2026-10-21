-- Observed, closed slices only. Wall time is inclusive; DO NOT sum nested rows.
-- Empirical nearest-rank quantiles, with n explicitly reported.
WITH e AS (
 SELECT s.name,COALESCE(CAST(EXTRACT_ARG(s.arg_set_id,'debug.stage_id') AS TEXT),s.name) AS function_or_stage,
 s.dur,s.thread_dur,tt.utid
 FROM slice s LEFT JOIN thread_track tt ON tt.id=s.track_id
 WHERE s.category='rdk.latency' AND s.dur>=0
 AND (s.name='lat.stage' OR s.name NOT GLOB 'lat.*')
), r AS (
 SELECT *,ROW_NUMBER() OVER(PARTITION BY function_or_stage ORDER BY dur) AS rn,
 COUNT(*) OVER(PARTITION BY function_or_stage) AS n FROM e
)
SELECT function_or_stage,COUNT(*) AS n,AVG(dur)/1e6 AS mean_wall_ms,MAX(dur)/1e6 AS max_wall_ms,
 MIN(CASE WHEN rn*100>=n*50 THEN dur END)/1e6 AS p50_wall_ms,
 MIN(CASE WHEN rn*100>=n*95 THEN dur END)/1e6 AS p95_wall_ms,
 MIN(CASE WHEN rn*100>=n*99 THEN dur END)/1e6 AS p99_wall_ms,
 SUM(CASE WHEN utid IS NOT NULL AND thread_dur>=0 THEN 1 ELSE 0 END) AS valid_thread_time_samples,
 CASE WHEN COUNT(*)<1000 THEN 'SMALL_SAMPLE_EMPIRICAL_TAIL' ELSE 'EMPIRICAL_NOT_CONFIDENCE_INTERVAL' END AS caution
FROM r GROUP BY function_or_stage;
