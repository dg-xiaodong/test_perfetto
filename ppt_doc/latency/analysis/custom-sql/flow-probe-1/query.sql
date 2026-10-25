SELECT CAST(EXTRACT_ARG(s.arg_set_id,'debug.link_id') AS TEXT) link_id, COUNT(*) n,
 MIN(f.slice_out) so, MIN(f.slice_in) si
FROM slice s JOIN flow f ON f.slice_out=s.id
WHERE s.category='rdk.latency' AND s.name='lat.send'
GROUP BY link_id ORDER BY n DESC LIMIT 5;
