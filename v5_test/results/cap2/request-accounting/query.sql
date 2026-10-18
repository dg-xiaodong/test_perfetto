-- Business request boundaries (from service.log, mono ns) vs observed thread_state (ftrace boot ns).
-- Log boot_ns = mono_ns + 0.33-0.42us (measured on every log line), so windows are used as-is
-- with a 1us pad; results are reported as overlaps, not as exact-equality evidence.
WITH req(id,enq,start,done) AS (VALUES
 (94,436039247249,436039411457,436049426291),
 (95,436050606874,436085095082,436085105082),
 (96,436091531166,436091611166,436101621832),
 (97,436102512249,436120084832,436120090082),
 (98,436143135457,436143181499,436153189041),
 (99,436153954124,436170044207,436170048457)),
st AS (SELECT st.ts,st.dur,st.state FROM thread_state st WHERE st.utid=2 AND st.dur>0
       AND st.ts+st.dur>436039000000 AND st.ts<436171000000)
SELECT r.id,
  r.start-r.enq AS queue_ns,
  (SELECT SUM(MIN(s.ts+s.dur,r.start+1000)-MAX(s.ts,r.enq)) FROM st s WHERE s.state='S' AND s.ts<r.start AND s.ts+s.dur>r.enq) AS pre_sleep_ns,
  (SELECT SUM(MIN(s.ts+s.dur,r.start+1000)-MAX(s.ts,r.enq)) FROM st s WHERE s.state IN ('R','R+') AND s.ts<r.start AND s.ts+s.dur>r.enq) AS pre_runnable_ns,
  r.done-r.start AS dur_ns,
  (SELECT SUM(MIN(s.ts+s.dur,r.done+1000)-MAX(s.ts,r.start)) FROM st s WHERE s.state='Running' AND s.ts<r.done AND s.ts+s.dur>r.start) AS proc_running_ns,
  (SELECT SUM(MIN(s.ts+s.dur,r.done+1000)-MAX(s.ts,r.start)) FROM st s WHERE s.state='S' AND s.ts<r.done AND s.ts+s.dur>r.start) AS proc_sleep_ns,
  (SELECT SUM(MIN(s.ts+s.dur,r.done+1000)-MAX(s.ts,r.start)) FROM st s WHERE s.state IN ('R','R+') AND s.ts<r.done AND s.ts+s.dur>r.start) AS proc_runnable_ns
FROM req r ORDER BY r.id;
