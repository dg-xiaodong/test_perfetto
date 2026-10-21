-- Track binding facts for the app's slices: thread_track vs process_track vs custom.
SELECT s.category, s.name,
       CASE WHEN tt.id IS NOT NULL THEN 'thread_track'
            WHEN pt.id IS NOT NULL THEN 'process_track'
            ELSE 'custom_or_async' END AS track_kind,
       COUNT(*) AS n, MIN(s.track_id) AS example_track_id
FROM slice s
LEFT JOIN thread_track tt ON tt.id=s.track_id
LEFT JOIN process_track pt ON pt.id=s.track_id
WHERE s.category IN ('pipeline','memory','sync','io','demo')
GROUP BY s.category, s.name, track_kind ORDER BY s.category, n DESC
