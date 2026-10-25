-- Export actual recorded Flow edges. No time-neighbor inferred edges.
SELECT f.id AS flow_id,f.slice_out,f.slice_in
FROM flow f
JOIN slice a ON a.id=f.slice_out JOIN slice b ON b.id=f.slice_in
WHERE a.category='rdk.latency' OR b.category='rdk.latency'
ORDER BY f.id;
