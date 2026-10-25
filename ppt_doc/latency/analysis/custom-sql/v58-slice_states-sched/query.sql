SELECT ts.ts, ts.dur, ts.state, ts.cpu
FROM thread_state ts
WHERE ts.utid=5 AND ts.ts+ts.dur>7786825263546 AND ts.ts<7786825263546+85153666
ORDER BY ts.ts;
