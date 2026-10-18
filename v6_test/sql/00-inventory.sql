-- Inventory only: counts prove the events were collected, NOT that the
-- measurement is valid. Check data-loss and open slices before trusting numbers.
SELECT tb.start_ts,
       tb.end_ts,
       (tb.end_ts - tb.start_ts) / 1000000 AS span_ms,
       (SELECT COUNT(*) FROM slice WHERE name = 'camsys.sif.frame')        AS sif_frame_slices,
       (SELECT COUNT(*) FROM slice WHERE name = 'camsys.isp.frame')        AS isp_frame_slices,
       (SELECT COUNT(*) FROM slice WHERE name = 'camsys.sif2isp.queue')    AS sif2isp_slices,
       (SELECT COUNT(*) FROM slice WHERE name = 'camsys.isp.user')         AS userspace_isp_slices,
       (SELECT COUNT(*) FROM counter c JOIN counter_track t ON t.id = c.track_id
         WHERE t.name = 'camsys.sif2isp.enq')                              AS enq_counters,
       (SELECT COUNT(*) FROM counter c JOIN counter_track t ON t.id = c.track_id
         WHERE t.name = 'camsys.sif2isp.deq')                              AS deq_counters,
       (SELECT COUNT(*) FROM counter c JOIN counter_track t ON t.id = c.track_id
         WHERE t.name = 'camsys.isp.fs')                                   AS isp_fs_counters,
       (SELECT COUNT(*) FROM slice
         WHERE name LIKE 'camsys.%' AND dur = -1)                          AS open_camsys_slices
FROM trace_bounds tb;
