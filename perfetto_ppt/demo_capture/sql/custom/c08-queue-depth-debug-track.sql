-- Ready-to-paste Add Debug Track query: QueueDepth over time.
SELECT c.ts AS ts, c.value AS queue_depth
FROM counter c JOIN process_counter_track ct ON ct.id=c.track_id
WHERE ct.name='QueueDepth' ORDER BY c.ts
