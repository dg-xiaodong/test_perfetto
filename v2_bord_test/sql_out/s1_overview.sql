select 'TRACE_BOUNDS' k, start_ts, end_ts, (end_ts-start_ts)/1e9 as dur_s from trace_bounds;
select 'PROC' k, upid, pid, name, start_ts, end_ts from process where name in ('dd','timeout','sh','sshd') or name like '%tracebox%' order by name, upid;
select 'SCHED_COUNTS' k, count(*) n, min(ts) first_ts, max(ts+dur) last_ts from sched_slice;
select 'COUNTERS' k, ct.name, count(*) n, min(c.value) minv, max(c.value) maxv from counter c join counter_track ct using(track_id) group by ct.name order by ct.name;
select 'STATS' k, name, value, severity, source from stats order by name;
select 'DATA_SOURCES' k, name, count(*) n from stats group by name;
