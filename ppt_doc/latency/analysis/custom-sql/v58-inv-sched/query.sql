-- One result set; counts are inventory, NOT proof of valid business identities.
SELECT tb.start_ts,tb.end_ts,
 (SELECT COUNT(*) FROM slice WHERE category='rdk.latency') AS app_slices,
 (SELECT COUNT(*) FROM slice WHERE category='rdk.latency' AND name='lat.request.begin') AS request_begins,
 (SELECT COUNT(*) FROM slice WHERE category='rdk.latency' AND name='lat.request.end') AS request_terminals,
 (SELECT COUNT(*) FROM slice WHERE category='rdk.latency' AND dur=-1) AS open_slices,
 (SELECT COUNT(*) FROM flow f JOIN slice s ON s.id=f.slice_out WHERE s.category='rdk.latency') AS flow_edges,
 (SELECT COUNT(*) FROM sched_slice WHERE dur>0) AS sched_rows
FROM trace_bounds tb;
