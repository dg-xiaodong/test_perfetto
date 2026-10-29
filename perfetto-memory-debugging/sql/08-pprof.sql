-- S11. Current implementation uses __intrinsic_* tables: verify before use.
SELECT name FROM sqlite_master WHERE name GLOB '*aggregate*';
-- Run separately after verifying the table names/columns in this TP version.
SELECT id, scope, name, sample_type_type, sample_type_unit
FROM __intrinsic_aggregate_profile;
-- This is metric aggregation, NOT timestamps or live RSS.
SELECT p.scope, p.sample_type_type, p.sample_type_unit, SUM(s.value) AS total_value
FROM __intrinsic_aggregate_sample s
JOIN __intrinsic_aggregate_profile p ON p.id = s.aggregate_profile_id
GROUP BY p.id, p.scope, p.sample_type_type, p.sample_type_unit;
