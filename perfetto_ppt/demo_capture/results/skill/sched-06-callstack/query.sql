-- Walk a selected event sample's actual callsite, not all samples in a thread.
-- Output leaf -> ancestors. Missing names are preserved, Build ID belongs to mapping.
WITH RECURSIVE chain(id,depth,visited) AS (
 SELECT 0,0,','||0||',' WHERE 0>=0
 UNION ALL
 SELECT c.parent_id,ch.depth+1,ch.visited||c.parent_id||','
 FROM chain ch JOIN stack_profile_callsite c ON c.id=ch.id
 WHERE c.parent_id IS NOT NULL AND ch.depth<63
 AND instr(ch.visited,','||c.parent_id||',')=0)
SELECT ch.depth,c.id AS callsite_id,f.name AS function_name,f.rel_pc,
 m.name AS mapping_name,m.build_id,
 CASE WHEN c.parent_id IS NOT NULL AND (ch.depth=63 OR instr(ch.visited,','||c.parent_id||',')>0)
 THEN 'TRUNCATED_OR_CYCLE' ELSE 'FRAME' END AS status
FROM chain ch JOIN stack_profile_callsite c ON c.id=ch.id
LEFT JOIN stack_profile_frame f ON f.id=c.frame_id
LEFT JOIN stack_profile_mapping m ON m.id=f.mapping ORDER BY ch.depth;
