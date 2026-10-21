-- Optional version-dependent inventory. First check sqlite_master.
-- Corroborate session IDs and the generated timebase names; never assume IDs=0,1.
SELECT * FROM perf_counter_track;
