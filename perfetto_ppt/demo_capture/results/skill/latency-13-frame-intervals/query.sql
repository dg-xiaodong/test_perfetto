-- Exploratory application-output intervals, NOT display/presentation FPS.
-- Full integrity-qualified output intervals are emitted by analyze.py.
WITH f AS (
 SELECT s.ts,EXTRACT_ARG(s.arg_set_id,'debug.run_id') AS run_id,
 EXTRACT_ARG(s.arg_set_id,'debug.stream_id') AS stream_id,
 EXTRACT_ARG(s.arg_set_id,'debug.request_id') AS request_id,
 EXTRACT_ARG(s.arg_set_id,'debug.frame_seq') AS frame_seq
 FROM slice s WHERE s.category='rdk.latency' AND s.name='lat.request.end'
 AND EXTRACT_ARG(s.arg_set_id,'debug.object_type')='frame'
 AND EXTRACT_ARG(s.arg_set_id,'debug.status')='SUCCESS'
), p AS (
 SELECT *,LAG(ts) OVER(PARTITION BY run_id,stream_id ORDER BY ts) AS prev_ts,
 LAG(frame_seq) OVER(PARTITION BY run_id,stream_id ORDER BY ts) AS prev_seq FROM f
)
SELECT *,ts-prev_ts AS interval_ns,
 CASE WHEN frame_seq<prev_seq THEN 1 ELSE 0 END AS order_reversal,
 'EXPLORATORY_CHECK_REQUEST_INTEGRITY' AS caution FROM p ORDER BY ts;
