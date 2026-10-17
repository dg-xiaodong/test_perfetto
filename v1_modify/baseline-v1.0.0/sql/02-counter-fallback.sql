-- No standard library dependency. Choose ONE real track_id from inventory.
-- Native value/unit is preserved: do not divide unknown counters by 1048576.
WITH params AS (SELECT -1 AS selected_track_id)
SELECT c.ts, c.value, ct.name || ' [native unit; verify first]' AS series
FROM counter c JOIN counter_track ct ON ct.id = c.track_id, params
WHERE c.track_id = params.selected_track_id
ORDER BY c.ts;
