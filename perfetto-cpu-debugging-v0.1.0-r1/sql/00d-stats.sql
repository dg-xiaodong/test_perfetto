-- 00d — step 5/5: non-zero stats that are not severity=info (data loss / errors).
-- Empty result = no reported data loss. severity rows that exist with value=0
-- are stat *definitions*, not observed loss; check `value`.
-- Run separately (single SELECT): query -f sql/00d-stats.sql <trace>.pftrace
SELECT name, value, severity
FROM stats
WHERE value <> 0 AND severity <> 'info'
ORDER BY name;
