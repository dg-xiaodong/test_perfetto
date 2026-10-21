-- Inventory only; choose an actual UTID (not TID) before parameterized queries.
SELECT p.upid, p.pid, p.name AS process_name, t.utid, t.tid, t.name AS thread_name,
       t.start_ts, t.end_ts
FROM thread t LEFT JOIN process p USING(upid)
ORDER BY p.upid,t.utid;
