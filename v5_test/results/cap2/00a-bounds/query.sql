SELECT start_ts,end_ts,(end_ts-start_ts)/1e9 AS duration_s FROM trace_bounds;
