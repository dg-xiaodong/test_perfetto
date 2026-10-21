-- Target-process RSS categories from linux.process_stats (1 s polling).
SELECT c.ts, ct.name AS series, c.value/1024.0 AS value_kb
FROM counter c JOIN process_counter_track ct ON ct.id=c.track_id
JOIN process p ON p.upid=ct.upid
WHERE p.name LIKE '%pf-demo-x5' AND ct.name IN ('mem.rss','mem.rss.anon','mem.rss.file','mem.rss.shmem','mem.virt')
ORDER BY ct.name, c.ts
