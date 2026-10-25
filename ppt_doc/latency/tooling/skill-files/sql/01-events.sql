-- Canonical TrackEvent export; raw identities stay TEXT (no floating-point ID conversions).
-- thread_utid is NULL for generic/custom async tracks, even if a process is known.
SELECT s.id AS slice_id,s.name AS kind,s.ts,s.dur,s.track_id,
       tt.utid AS thread_utid,s.thread_dur,
       CAST(EXTRACT_ARG(s.arg_set_id,'debug.contract_version') AS TEXT) AS contract_version,
       CAST(EXTRACT_ARG(s.arg_set_id,'debug.run_id') AS TEXT) AS run_id,
       CAST(EXTRACT_ARG(s.arg_set_id,'debug.stream_id') AS TEXT) AS stream_id,
       CAST(EXTRACT_ARG(s.arg_set_id,'debug.request_id') AS TEXT) AS request_id,
       CAST(EXTRACT_ARG(s.arg_set_id,'debug.process_instance_id') AS TEXT) AS process_instance_id,
       CAST(EXTRACT_ARG(s.arg_set_id,'debug.stage_id') AS TEXT) AS stage_id,
       CAST(EXTRACT_ARG(s.arg_set_id,'debug.stage_instance_id') AS TEXT) AS stage_instance_id,
       CAST(EXTRACT_ARG(s.arg_set_id,'debug.attempt_id') AS TEXT) AS attempt_id,
       CAST(EXTRACT_ARG(s.arg_set_id,'debug.queue_id') AS TEXT) AS queue_id,
       CAST(EXTRACT_ARG(s.arg_set_id,'debug.queue_visit_id') AS TEXT) AS queue_visit_id,
       CAST(EXTRACT_ARG(s.arg_set_id,'debug.link_id') AS TEXT) AS link_id,
       CAST(EXTRACT_ARG(s.arg_set_id,'debug.from_instance') AS TEXT) AS from_instance,
       CAST(EXTRACT_ARG(s.arg_set_id,'debug.to_instance') AS TEXT) AS to_instance,
       CAST(EXTRACT_ARG(s.arg_set_id,'debug.flow_scope') AS TEXT) AS flow_scope,
       CAST(EXTRACT_ARG(s.arg_set_id,'debug.status') AS TEXT) AS status,
       CAST(EXTRACT_ARG(s.arg_set_id,'debug.boundary') AS TEXT) AS boundary,
       CAST(EXTRACT_ARG(s.arg_set_id,'debug.object_type') AS TEXT) AS object_type,
       EXTRACT_ARG(s.arg_set_id,'debug.frame_seq') AS frame_seq,
       EXTRACT_ARG(s.arg_set_id,'debug.expected_stage_count') AS expected_stage_count,
       EXTRACT_ARG(s.arg_set_id,'debug.expected_queue_count') AS expected_queue_count,
       EXTRACT_ARG(s.arg_set_id,'debug.expected_link_count') AS expected_link_count
FROM slice s LEFT JOIN thread_track tt ON tt.id=s.track_id
WHERE s.category='${CATEGORY}' ORDER BY s.ts,s.id;
