-- 5 ms-bucket timeline of CPU 2 (and CPU 1) busy time in the burst, by thread.
SELECT s.cpu,(s.ts/5000000)*5 AS bucket_ms, th.name, SUM(s.dur)/1e6 AS ms
FROM sched_slice s JOIN thread th USING(utid)
WHERE s.cpu IN (1,2) AND s.dur>0 AND s.ts>=195960000000 AND s.ts<196220000000 AND th.tid!=0
GROUP BY 1,2,3 HAVING ms>0.8 ORDER BY 1,2,ms DESC;
