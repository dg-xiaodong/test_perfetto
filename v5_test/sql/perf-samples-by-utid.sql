-- Perf sample source audit: who each sample is attributed to, per session.
SELECT ps.perf_session_id,ps.cpu,th.tid,th.name,
  COUNT(*) n, SUM(ps.callsite_id IS NOT NULL) with_stack,
  SUM(COALESCE(ps.unwind_error,'')!='') unwind_err,
  MIN(ps.ts) first_ts,MAX(ps.ts) last_ts
FROM perf_sample ps LEFT JOIN thread th USING(utid)
GROUP BY 1,2,3,4 ORDER BY n DESC LIMIT 25;
