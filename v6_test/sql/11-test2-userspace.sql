-- Test 2: userspace-observed ISP frame window, per track.
-- TrackEvent slices (category camsys) opened on ISP_MSG_MCM_SCH and closed on
-- ISP_MSG_FRAME_DONE in cam-service's hal_msg_handler(). This interval INCLUDES
-- the kernel->userspace message round trip; it is not the hardware FS->FE time.
--
-- One async track per (dev_id, inst). Run 11b for the aggregate distribution.
SELECT COALESCE(t.name, '<unnamed-track>') AS track,
       COUNT(*)                            AS samples,
       AVG(s.dur) / 1000.0                 AS avg_us,
       MIN(s.dur) / 1000.0                 AS min_us,
       MAX(s.dur) / 1000.0                 AS max_us,
       SUM(CASE WHEN s.dur = -1 THEN 1 ELSE 0 END) AS open_slices
FROM slice s
LEFT JOIN track t ON t.id = s.track_id
WHERE s.name = 'camsys.isp.user' AND s.dur >= 0
GROUP BY 1
ORDER BY samples DESC;
