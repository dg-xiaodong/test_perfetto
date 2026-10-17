WITH b AS (SELECT 1000000000 AS ns, c.ts/1000000000 AS sec, ct.cpu AS cpu, c.value AS v
           FROM counter c JOIN cpu_counter_track ct ON ct.id=c.track_id WHERE ct.name='cpuidle')
SELECT sec, SUM(CASE WHEN cpu IN (6,7) THEN 1 ELSE 0 END) AS c67_samples,
       SUM(CASE WHEN cpu IN (6,7) AND v=1 THEN 1 ELSE 0 END) AS c67_idle,
       SUM(CASE WHEN cpu NOT IN (6,7) AND v=1 THEN 1 ELSE 0 END) AS others_idle
FROM b GROUP BY sec ORDER BY sec LIMIT 60;
