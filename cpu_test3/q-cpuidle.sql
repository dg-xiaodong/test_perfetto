SELECT ct.cpu AS cpu, c.value AS raw_value, COUNT(*) AS n
FROM counter c JOIN cpu_counter_track ct ON ct.id=c.track_id
WHERE ct.name='cpuidle' GROUP BY ct.cpu, c.value ORDER BY ct.cpu, n DESC;
