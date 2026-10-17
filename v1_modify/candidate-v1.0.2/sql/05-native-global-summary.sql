-- S24: ALL PROCESSES, ALL HEAPS, WHOLE TRACE aggregated together.
-- Not a single-process report; no upid/ts filter exists on this summary table.
INCLUDE PERFETTO MODULE android.memory.heap_profile.summary_tree;
SELECT id, parent_id, name, mapping_name, source_file, line_number,
       self_size, cumulative_size, self_alloc_size, cumulative_alloc_size
FROM android_heap_profile_summary_tree
ORDER BY cumulative_size DESC;
