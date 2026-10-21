-- Optional syscall tracing route; not automatically enabled by this package.
-- A futex slice is syscall duration, not mutex hold time or ownership.
SELECT sl.id,sl.ts,sl.dur,tt.utid,sl.name
FROM slice sl JOIN thread_track tt ON sl.track_id=tt.id
WHERE tt.utid=213 AND lower(sl.name) GLOB '*futex*' ORDER BY sl.ts;
