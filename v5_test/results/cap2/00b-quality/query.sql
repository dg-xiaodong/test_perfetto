-- Nonzero diagnostic rows, NOT counts of registered stats names.
-- Informational stats can be nonzero normally. Inspect error/data_loss and scope.
SELECT name,severity,value FROM stats WHERE value!=0 ORDER BY severity,name;
