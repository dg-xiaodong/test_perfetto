# ppt_doc/schedule — pf-sched-case periodic-A 迟到诊断（X5，窗口 B 单次独立诊断 V4）

本目录是 2026-10-25 在 RDK X5 上对 `pf-sched-case` 周期线程迟到问题的一次**单次独立诊断**的完整留存，
使用 `perfetto-scheduling-debugging` v0.1.0（candidate）。诊断结论与全部证据边界见
[FIRST_PASS_REPORT.md](FIRST_PASS_REPORT.md)（报告已冻结）。

结论一行版：迟到不是睡眠等待、也不是唤醒延迟，而是 CPU5 上 nice=0 的 `pf-t1` 以 415–477ms burst
（97.7% 单核占用，每 3.3–3.9s 一次）使 nice=17 的 `pf-t0` 产生 16.5–46.5ms 的 **Runnable 饥饿**；
唤醒源为 arch timer hrtimer IRQ（`waker_utid=211` 仅为被中断上下文，不是 pf-t1 用户态信号）。

## 先看哪个 trace

| 文件 | 内容 | 用途 |
|---|---|---|
| `cap-ov-1/trace.pftrace` | 30s 全系统 sched_switch/waking（无 perf，无丢事件） | **首选**：迟到窗口、Runnable 占比、CPU5 竞争 7/7 对齐 |
| `cap-bw-1/trace.pftrace` | 15s 定向 block/wake（2×696 带栈 perf 样本） | 核对 `clock_nanosleep` 切出栈与 hrtimer 唤醒栈 |

用 <https://ui.perfetto.dev> 打开即可；时钟为 BOOTTIME，公共 CSV 为 MONOTONIC（offset 291/250ns，
见报告 §13）。ftrace 数据封装在 `.pftrace` 内（`ftrace_event` / `thread_state` / `sched_slice` 表）。

UI 截图：[`cap-ov-1/ui-runnable-starvation.png`](cap-ov-1/ui-runnable-starvation.png) ——
overview trace（Duration 29s 706ms 99µs 223ns）中 `pf-t0 4705` 的长 Runnable 条（红框，~36ms）
结束后才获得 CPU；同一时间窗 CPU 5 由 `pf-sched-case [4703] / pf-t1 [4706]` 占用。

UI 截图 2：[`cap-ov-1/p9.webp`](cap-ov-1/p9.webp) —— 同一 trace 中最长的一次等待（`thread_state[3995]`）：
**Runnable 46ms 504µs 875ns**（00:00:07.497 836 087 起），Previous state `Sleeping 2ms 398µs 458ns`，
Next state `Running 1ms 117µs 417ns`，**Woken by Interrupt** —— 即 IRQ 上下文唤醒（对应报告 §6/§7 的
`irq_context=1` 与 46.5ms 最大等待）。

UI 截图 3：[`cap-ov-1/p10.webp`](cap-ov-1/p10.webp) —— 竞争者一侧：CPU 5 上 `pf-t1 [4706]` 的
**29ms 966µs 41ns 连续 sched slice**（Priority 120 = nice 0，End State Runnable，sched[1241]），
同一时间窗 `pf-t0 4705` 轨道连续出现 Runnable 条；CPU 6 另见 `pf-t2 [4707]` 长切片
（不同核，与本问题无关）。

## 校验

```sh
cd ppt_doc/schedule
sha256sum -c SHA256SUMS.txt          # 覆盖冻结证据集（README.md 与 UI 截图 ui-runnable-starvation.png、p9.webp、p10.webp 除外）
sha256sum -c FIRST_PASS_REPORT.md.sha256
```

## 主要文件

- `FIRST_PASS_REPORT.md` + `.sha256`：诊断报告（E1/E2/E3、数据质量、UNKNOWN、UI 复核步骤）
- `cap-ov-1/`、`cap-bw-1/`：真实 trace + 实际采集配置 + record.sh 状态/日志
- `overview-30s.pbtxt`、`block-wake-15s.pbtxt`：make_config.py 生成并通过策略校验的配置
- `a_latency_after.csv`：采集后的公共周期时延快照（与 trace 对账见 `analysis/correlate.py`）
- `analysis/`：对账脚本与全部 SQL 查询/输出（`analysis/runs/` 含每条查询的实际输出与版本）
- `events.txt`、`formats/`：板端 available_events 与 sched 事件 format 快照
- `board_facts.txt`：内核/调度属性事实（nice、亲和性、CONFIG_*）

工具版本：tracebox v58.2-add693d8b（aarch64）、trace_processor_shell v57.1-c59f57dd4。
