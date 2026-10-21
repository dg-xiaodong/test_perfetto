-- P10 evidence: real blocking call sites from SW_CONTEXT_SWITCHES samples with
-- kernel+user callchains. One row per (thread, blocking leaf, immediate caller
-- of the scheduler). NOT sched_switch: there is no waker/runnable state here.
WITH RECURSIVE anc(sample_id, cid, depth) AS (
  SELECT ps.id, ps.callsite_id, 0 FROM perf_sample ps
  WHERE ps.callsite_id IS NOT NULL
  UNION ALL
  SELECT a.sample_id, c.parent_id, a.depth+1
  FROM anc a JOIN stack_profile_callsite c ON c.id=a.cid
  WHERE c.parent_id IS NOT NULL AND a.depth < 12
)
SELECT th.name AS thread_name, a.depth,
       COALESCE(NULLIF(f.name,''),'[unnamed]') AS frame,
       COALESCE(m.name,'[unknown]') AS mapping, COUNT(*) AS samples
FROM anc a
JOIN perf_sample ps ON ps.id=a.sample_id
JOIN thread th USING(utid)
JOIN stack_profile_frame f ON f.id=(SELECT frame_id FROM stack_profile_callsite WHERE id=a.cid)
LEFT JOIN stack_profile_mapping m ON m.id=f.mapping
WHERE th.name LIKE 'pf-%' AND a.depth BETWEEN 1 AND 4
GROUP BY th.name, a.depth, f.name, m.name
ORDER BY th.name, a.depth, samples DESC LIMIT 120
