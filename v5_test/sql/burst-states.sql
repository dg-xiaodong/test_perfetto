-- Raw state intervals for req-dispatch (utid 226) around the cycle-4 burst.
SELECT id,ts,ts/1e9 AS ts_s,dur,state,cpu,io_wait,blocked_function,waker_utid,irq_context,
       CASE WHEN dur>0 THEN dur/1e6 END AS dur_ms
FROM thread_state WHERE utid=226 AND ts+MAX(dur,0)>195500000000 AND ts<197500000000
ORDER BY ts,id;
