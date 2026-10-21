-- App TrackEvent inventory: category / slice name counts and wall totals.
-- TEMP SUPPLEMENT written for this capture (not shipped by any Skill).
SELECT s.category, s.name, COUNT(*) AS n,
       ROUND(SUM(CASE WHEN s.dur>0 THEN s.dur ELSE 0 END)/1e6,2) AS total_ms,
       ROUND(AVG(CASE WHEN s.dur>0 THEN s.dur ELSE 0 END)/1e6,3) AS avg_ms,
       MAX(s.dur)/1e6 AS max_ms
FROM slice s
WHERE s.category IN ('pipeline','memory','sync','io','demo')
GROUP BY s.category, s.name ORDER BY s.category, n DESC
