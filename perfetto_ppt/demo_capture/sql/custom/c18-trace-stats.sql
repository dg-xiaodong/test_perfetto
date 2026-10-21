-- Integrity: trace bounds, buffer accounting, declared data loss.
SELECT name, idx, severity, value FROM stats
WHERE value<>0 AND (severity IN ('error','data_loss')
   OR name LIKE 'traced_buf%' OR name LIKE 'traced_chunks%' OR name LIKE 'perf_cpu_lost%')
ORDER BY severity, name, idx
