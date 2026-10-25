-- Keep source/index to avoid merging unrelated counter instances.
SELECT name,idx,source,severity,value FROM stats
WHERE value!=0 ORDER BY severity,name,idx;
