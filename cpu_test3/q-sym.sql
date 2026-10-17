SELECT COUNT(*) AS frames, SUM(CASE WHEN name IS NOT NULL AND name<>'' THEN 1 ELSE 0 END) AS named FROM stack_profile_frame;
