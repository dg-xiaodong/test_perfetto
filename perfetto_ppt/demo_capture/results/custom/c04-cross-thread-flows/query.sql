-- Real recorded Flow edges between stage slices, with the executing threads.
WITH target AS (SELECT upid FROM process WHERE name LIKE '%pf-demo-x5' LIMIT 1)
SELECT f.id AS flow_id, a.name AS from_slice, ta.name AS from_thread,
       b.name AS to_slice, tb.name AS to_thread, f.slice_out, f.slice_in,
       ROUND((b.ts-a.ts)/1e6,3) AS delta_ms
FROM flow f
JOIN slice a ON a.id=f.slice_out JOIN slice b ON b.id=f.slice_in
LEFT JOIN thread_track tta ON tta.id=a.track_id LEFT JOIN thread ta ON ta.utid=tta.utid
LEFT JOIN thread_track ttb ON ttb.id=b.track_id LEFT JOIN thread tb ON tb.utid=ttb.utid
WHERE a.name IN ('SyntheticCapture','Preprocess','InferenceStub','Postprocess','Output')
ORDER BY f.id LIMIT 40
