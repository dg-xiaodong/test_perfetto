SELECT f.id AS flow_id,a.id AS from_slice,b.id AS to_slice,a.ts AS from_ts,b.ts AS to_ts,
 a.name AS from_event,b.name AS to_event,
 EXTRACT_ARG(a.arg_set_id,'debug.run_id') AS from_run,
 EXTRACT_ARG(b.arg_set_id,'debug.run_id') AS to_run,
 EXTRACT_ARG(a.arg_set_id,'debug.stream_id') AS from_stream,
 EXTRACT_ARG(b.arg_set_id,'debug.stream_id') AS to_stream,
 EXTRACT_ARG(a.arg_set_id,'debug.request_id') AS from_request,
 EXTRACT_ARG(b.arg_set_id,'debug.request_id') AS to_request,
 EXTRACT_ARG(a.arg_set_id,'debug.link_id') AS from_link,
 EXTRACT_ARG(b.arg_set_id,'debug.link_id') AS to_link
FROM flow f JOIN slice a ON a.id=f.slice_out JOIN slice b ON b.id=f.slice_in
WHERE a.category='${CATEGORY}' OR b.category='${CATEGORY}' ORDER BY a.ts;
