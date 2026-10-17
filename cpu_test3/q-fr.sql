SELECT f.id AS id, COALESCE(NULLIF(f.name,''),'[unsym]') AS name, COALESCE(m.name,'[unknown]') AS mapping
FROM stack_profile_frame f LEFT JOIN stack_profile_mapping m ON m.id=f.mapping;
