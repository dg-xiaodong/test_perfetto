-- Frame id + end-to-end latency debug annotations recorded on FramePipeline.
-- NOTE: FramePipeline is a custom/async TrackEvent track: it has NO thread_track
-- and NO process_track binding (verify: c06b-track-binding.sql). The process is
-- therefore identified by the single app instance in this trace, not by a join.
SELECT s.ts, ROUND(s.dur/1e6,2) AS pipeline_ms,
       EXTRACT_ARG(s.arg_set_id,'debug.frame_id') AS frame_id,
       EXTRACT_ARG(s.arg_set_id,'debug.e2e_ms') AS e2e_ms,
       EXTRACT_ARG(s.arg_set_id,'debug.phase') AS phase,
       s.track_id
FROM slice s WHERE s.name='FramePipeline' ORDER BY s.ts LIMIT 40
