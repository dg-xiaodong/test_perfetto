-- Queue depth is instantaneous. Summing samples is not a queue-size metric.
SELECT c.ts,c.value,ct.id AS track_id,ct.name,ct.unit
FROM counter c JOIN counter_track ct ON ct.id=c.track_id
WHERE ct.name GLOB 'lat.queue_depth*' ORDER BY c.ts,ct.id;
