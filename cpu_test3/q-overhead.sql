SELECT th.name AS thread, s.cpu AS cpu, ROUND(SUM(s.dur)/1e6,1) AS ms
FROM sched_slice s JOIN thread th USING(utid)
WHERE th.upid!=3 AND th.tid!=0 AND (th.name LIKE '%tracebox%' OR th.name LIKE 'stack-unwind%')
GROUP BY th.name, s.cpu ORDER BY ms DESC LIMIT 12;
