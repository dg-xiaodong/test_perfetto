-- App-level blocking/wakeup substitutes for P10: CvWait / CvWakeupWork / CvTimeout
-- recorded by the SDK on real threads. NOT sched_switch and NOT waker attribution.
SELECT t.name AS thread_name, s.name, COUNT(*) AS n,
       ROUND(SUM(s.dur)/1e6,2) AS total_ms, ROUND(AVG(s.dur)/1e6,3) AS avg_ms,
       ROUND(MAX(s.dur)/1e6,2) AS max_ms
FROM slice s JOIN thread_track tt ON tt.id=s.track_id JOIN thread t ON t.utid=tt.utid
WHERE s.name IN ('CvWait','CvWakeupWork','CvTimeout','QueueWait.inference','QueueWait.postprocess','QueueWait.output')
GROUP BY t.name, s.name ORDER BY total_ms DESC
