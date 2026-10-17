SELECT th.tid AS tid, th.name AS tname, s.ts AS ts, s.dur AS dur, s.cpu AS cpu, s.end_state AS end_state
FROM sched_slice s JOIN thread th USING(utid) WHERE th.upid=3 AND s.dur>0 ORDER BY s.ts;
