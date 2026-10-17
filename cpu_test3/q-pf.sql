SELECT ps.utid AS utid, th.tid AS tid, th.name AS tname, ps.callsite_id AS csid
FROM perf_sample ps JOIN thread th USING(utid) WHERE th.upid=3;
