-- Any non-zero row here invalidates the corresponding numbers. Keep idx/source:
-- they separate unrelated counter instances (per-CPU / per-producer).
SELECT name, idx, source, severity, value
FROM stats
WHERE value != 0
ORDER BY severity DESC, name, idx;
