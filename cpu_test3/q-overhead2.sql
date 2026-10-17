SELECT ROUND(SUM(s.dur)/1e6,1) AS tracebox_total_ms FROM sched_slice s JOIN thread th USING(utid)
WHERE th.tid!=0 AND th.name LIKE '%tracebox%';
