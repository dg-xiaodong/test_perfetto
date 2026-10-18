-- Clock/identity alignment check: req-dispatch(utid 226) runnable starts near
-- log-recorded enqueue->start events (log mono, trace boot ~ mono+0.3us).
SELECT st.id,st.ts,st.ts-191039270465 AS off_from_log_start_191039 FROM thread_state st
WHERE st.utid=226 AND st.state IN ('R','R+') AND st.ts>191038000000 AND st.ts<191040000000;
