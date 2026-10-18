-- Test 1 cross-check, independent of async-slice pairing.
--
-- The kernel patch also emits counter rows carrying the hardware frame id:
--   camsys.sif2isp.enq  (SIF FE, before cam_qbuf_irq)
--   camsys.sif2isp.deq  (ISP new_frame, after cam_dqbuf_irq)
--   camsys.isp.fs       (ISP FS interrupt, hardware read starts)
-- Joining enqueue and dequeue on the frame id yields the same residency as the
-- async slice without relying on S/F bookkeeping. Duplicate ids inside one
-- capture would multiply rows; compare `pairs` with the slice sample count.
WITH enq AS (
    SELECT c.ts, CAST(c.value AS INTEGER) AS fid
    FROM counter c JOIN counter_track t ON t.id = c.track_id
    WHERE t.name = 'camsys.sif2isp.enq'
), deq AS (
    SELECT c.ts, CAST(c.value AS INTEGER) AS fid
    FROM counter c JOIN counter_track t ON t.id = c.track_id
    WHERE t.name = 'camsys.sif2isp.deq'
), fs AS (
    SELECT c.ts, CAST(c.value AS INTEGER) AS fid
    FROM counter c JOIN counter_track t ON t.id = c.track_id
    WHERE t.name = 'camsys.isp.fs'
)
SELECT 'enq->deq (queue residency)'                         AS metric,
       COUNT(*)                                             AS pairs,
       AVG((d.ts - e.ts) / 1000.0)                          AS avg_us,
       MIN((d.ts - e.ts) / 1000.0)                          AS min_us,
       MAX((d.ts - e.ts) / 1000.0)                          AS max_us
FROM enq e
JOIN deq d ON d.fid = e.fid AND d.ts >= e.ts
UNION ALL
-- Secondary: SIF enqueue -> ISP hardware read start (FS interrupt).
SELECT 'enq->isp.fs (hand-off to hardware)'                 AS metric,
       COUNT(*)                                             AS pairs,
       AVG((f.ts - e.ts) / 1000.0)                          AS avg_us,
       MIN((f.ts - e.ts) / 1000.0)                          AS min_us,
       MAX((f.ts - e.ts) / 1000.0)                          AS max_us
FROM enq e
JOIN fs f ON f.fid = e.fid AND f.ts >= e.ts;
