-- System memory counters from linux.sys_stats (meminfo type, 1 s polling).
-- Perfetto names them with the /proc/meminfo key; values are kB.
SELECT c.ts, ct.name, c.value AS value_kb
FROM counter c JOIN counter_track ct ON ct.id=c.track_id
WHERE ct.type='meminfo'
  AND ct.name IN ('MemTotal','MemFree','MemAvailable','Buffers','Cached','AnonPages','Slab','SwapFree','CmaFree','Mapped')
ORDER BY ct.name, c.ts LIMIT 400
