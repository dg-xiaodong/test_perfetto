-- App-defined counter tracks and value ranges (P12 / Add Debug Track source).
SELECT ct.id AS track_id, p.name AS process_name, ct.name, ct.unit,
       COUNT(c.id) AS n, MIN(c.value) AS min_v, MAX(c.value) AS max_v,
       ROUND(AVG(c.value),3) AS avg_v
FROM process_counter_track ct LEFT JOIN counter c ON c.track_id=ct.id
LEFT JOIN process p ON p.upid=ct.upid
WHERE ct.name IN ('QueueDepth','InflightFrames','CompletedFrames','EndToEndLatencyMs',
                  'LiveAllocatedBytes','RssKb','ThreadsRunning','ThreadsBlocked',
                  'SchedWakeupOvershootMs','IoFileBytes')
GROUP BY ct.id ORDER BY ct.name
