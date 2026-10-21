-- CPU sampling hotspots (leaf frames) for the target process only.
-- Sample counts are statistical estimates, not call counts or CPU milliseconds.
WITH target AS (SELECT upid FROM process WHERE name LIKE '%pf-demo-x5' LIMIT 1)
SELECT COALESCE(NULLIF(f.name,''),'[unsymbolized]') AS leaf_frame,
       CASE WHEN f.name LIKE '_Z%' THEN demangle(f.name) ELSE f.name END AS leaf_demangled,
       COUNT(*) AS samples
FROM perf_sample ps JOIN thread th USING(utid), target
LEFT JOIN stack_profile_callsite c ON c.id=ps.callsite_id
LEFT JOIN stack_profile_frame f ON f.id=c.frame_id
WHERE th.upid=target.upid
GROUP BY ps.callsite_id ORDER BY samples DESC LIMIT 25
