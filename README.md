# test_perfetto

X5 上 heapprofd 端到端实验（A/B）的真实 Perfetto trace 与验收结果，见 [`x5_heapprofd_traces/`](x5_heapprofd_traces/)。

- `x5_heapprofd_A_no_tick.pftrace`：无 tick（1 份 dump）
- `x5_heapprofd_B_tick_200ms.pftrace`：持有期每 200ms 4KiB tick（6 份 dump，Live 8→0 MiB）

采集端 tracebox v57.1（X5），分析端 Trace Processor v58.2。可直接拖进 <https://ui.perfetto.dev/> 查看。

## 截图

- `x5_heapprofd_traces/折线图.png`：实验 B trace 在 Perfetto UI 中的截图。
  注意：该图的 debug track 被添加成了 **Debug Slice Track**（按 slice 渲染，显示为色块+横线），
  不是 `heap_live_timeline.sql` 期望的 **Counter Track**（折线/散点，值应为 `8,8,8,0,0,0` MiB）。
  若要得到真正的 Heap Live 折线，请在 Query 结果区选择 **Add debug track → Counter Track**。

## CPU 性能诊断

- [`cpu_v1_test/`](cpu_v1_test/)：X5 上 C++ 多线程负载（每 3 s 烧 300 ms）的 CPU 尖峰归因。
  采集端 tracebox v57.1 + scheduling 路由（20 s），分析端 Trace Processor v57.1；
  结论：`spike-worker`(tid 12044) 每 3000 ms 满占 CPU1 一个核 300 ms，Runnable 仅 ~80 µs，非调度延迟。
