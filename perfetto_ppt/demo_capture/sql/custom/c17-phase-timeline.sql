-- Phase timeline: 8 s phases, cycle index from the app's debug annotations.
SELECT s.ts, s.ts/1e9 AS ts_s,
       EXTRACT_ARG(s.arg_set_id,'debug.cycle') AS cycle,
       EXTRACT_ARG(s.arg_set_id,'debug.phase') AS phase
FROM slice s WHERE s.name='PhaseChange' ORDER BY s.ts
