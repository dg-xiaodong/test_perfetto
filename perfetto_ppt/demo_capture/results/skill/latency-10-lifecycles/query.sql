-- UI inspection only: endpoint completeness, not full pipeline validation.
-- Authoritative eligibility requires scripts/analyze.py (counts, stages, flows, quality).
WITH e AS (
 SELECT name,ts,CAST(EXTRACT_ARG(arg_set_id,'debug.run_id') AS TEXT) AS run_id,
 CAST(EXTRACT_ARG(arg_set_id,'debug.stream_id') AS TEXT) AS stream_id,
 CAST(EXTRACT_ARG(arg_set_id,'debug.request_id') AS TEXT) AS request_id,
 CAST(EXTRACT_ARG(arg_set_id,'debug.status') AS TEXT) AS outcome
 FROM slice WHERE category='rdk.latency' AND name IN ('lat.request.begin','lat.request.end')
), g AS (
 SELECT run_id,stream_id,request_id,
 SUM(CASE WHEN name='lat.request.begin' THEN 1 ELSE 0 END) AS nb,
 SUM(CASE WHEN name='lat.request.end' THEN 1 ELSE 0 END) AS ne,
 MIN(CASE WHEN name='lat.request.begin' THEN ts END) AS begin_ts,
 MIN(CASE WHEN name='lat.request.end' THEN ts END) AS end_ts,
 MAX(CASE WHEN name='lat.request.end' THEN outcome END) AS outcome
 FROM e GROUP BY run_id,stream_id,request_id
)
SELECT *,CASE
 WHEN run_id IS NULL OR run_id='' OR stream_id IS NULL OR stream_id='' OR request_id IS NULL OR request_id='' THEN 'INVALID_IDENTITY'
 WHEN nb>1 OR ne>1 OR end_ts<begin_ts THEN 'INVALID'
 WHEN nb!=1 OR ne!=1 THEN 'INCOMPLETE'
 ELSE 'ENDPOINTS_COMPLETE_PIPELINE_UNCHECKED' END AS endpoint_status,
 CASE WHEN nb=1 AND ne=1 AND end_ts>=begin_ts THEN end_ts-begin_ts END AS endpoint_latency_ns
FROM g ORDER BY begin_ts;
