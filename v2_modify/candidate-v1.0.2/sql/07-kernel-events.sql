-- Generic ftrace event MARKERS, not inferred allocation durations.
-- Verify ftrace_event exists in this TP version. Some known events are instead
-- normalized into counters/slices; absence here is not proof of absent capture.
SELECT e.ts, 0 AS dur, e.name,
       'CPU ' || e.cpu || ' | ' || e.name AS series, e.utid, e.arg_set_id
FROM ftrace_event e
WHERE e.name GLOB '*cma*' OR e.name GLOB '*reclaim*' OR e.name GLOB '*compaction*'
   OR e.name GLOB '*oom*' OR e.name GLOB '*rss_stat*'
ORDER BY e.ts;
-- UI: Slice Track; ts / dur / name / series. Zero duration -> instant marker.
-- Inspect actual fields BEFORE pairing begin/end or interpreting count/ret.
-- Run separately after selecting an event arg_set_id:
-- SELECT key, int_value, string_value, real_value FROM args WHERE arg_set_id = 123;
