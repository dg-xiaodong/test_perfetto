-- S25. Compare graph snapshots; never sum snapshots as if they were increments.
-- UI Counter Track: ts / value / series. Snapshot dots/steps, not continuous GC.
INCLUDE PERFETTO MODULE android.memory.heap_graph.heap_graph_class_aggregation;
WITH params AS (
  SELECT -1 AS target_upid, 'com.example.app.MainActivity' AS target_type
)
SELECT g.graph_sample_ts AS ts, g.size_bytes / 1048576.0 AS value,
       'UPID ' || g.upid || ' | ' || g.type_name || ' shallow size (MiB)' AS series,
       g.obj_count, g.reachable_obj_count, g.native_size_bytes
FROM android_heap_graph_class_aggregation g, params p
WHERE g.upid = p.target_upid AND g.type_name = p.target_type
ORDER BY ts;
-- Native size is separately reported, not silently added to object self size.
