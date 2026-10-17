-- Task Q3 confidence: what CPU counters exist, and did we lose data?
SELECT name, COUNT(*) AS tracks FROM cpu_counter_track GROUP BY name ORDER BY tracks DESC;
