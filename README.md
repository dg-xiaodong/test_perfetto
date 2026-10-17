# test_perfetto

X5 上 heapprofd 端到端实验（A/B）的真实 Perfetto trace 与验收结果，见 [`x5_heapprofd_traces/`](x5_heapprofd_traces/)。

- `x5_heapprofd_A_no_tick.pftrace`：无 tick（1 份 dump）
- `x5_heapprofd_B_tick_200ms.pftrace`：持有期每 200ms 4KiB tick（6 份 dump，Live 8→0 MiB）

采集端 tracebox v57.1（X5），分析端 Trace Processor v58.2。可直接拖进 <https://ui.perfetto.dev/> 查看。
