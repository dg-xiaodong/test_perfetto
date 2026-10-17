# X5 heapprofd 端到端实采报告（A/B）

**结论**：两份真实 trace 已在 X5 上采集完成、拉回主机、用 **Perfetto Trace Processor v58.2** 分析，可直接导入 <https://ui.perfetto.dev/>。
- A（无 tick）：**1 份 dump**，Total 28 MiB / Free 28 MiB / Max Live **0**，验收 `CAPTURE_OK_BEHAVIOR_INCOMPLETE`。
- B（tick 200 ms）：**6 份 dump**，Total 28.23 MiB / Free 28.23 MiB / Max Live **8 MiB**，Heap Live 曲线 `8,8,8,0,0,0`，验收 `CAPTURE_OK_BEHAVIOR_INCOMPLETE`（唯一失败项是 **v57.1 无 `start_timestamp` 导致 `dur=0`、持有窗口不可判定**，不是采集失败/符号缺失/行为未捕获）。

## 1. 执行命令与退出码

| 步骤 | 命令（要点） | 退出码/结果 |
|---|---|---|
| 连通性 | `ping -c1 192.168.1.10` | 0 |
| 板端只读预检 | `ssh root@192.168.1.10 'uname -r; df -h /data; ls tracefs; ps ...'` | 0（无 traced/heapprofd/perfetto 运行；`/data` 653M 可用；MemAvailable 1.11 GB） |
| 部署 | `scp tracebox libheapprofd_glibc_preload.so → /data/`；`scp memprobe_arm64 → /data/memprobe`；`scp heapprofd_min.pbtxt board_run.sh → /data/` | 0 |
| 板端工具校验 | `/data/tracebox --version` | `Perfetto v57.1-c59f57dd4` |
| 程序自检 | `/data/memprobe live 1 100 50` | `SUMMARY … tick_ms=0 ticks=0` |
| **实验 A** | `sh /data/board_run.sh`（OUT=`/data/x5_heapprofd_A_no_tick.pftrace`） | `BOARD_RUN_EXIT=0`；`PROBE_RC=0`；`TB_RC=0`；trace 21,346 B |
| **实验 B** | `MEMPROBE_TICK_MS=200 sh /data/board_run.sh`（OUT=`/data/x5_heapprofd_B_tick_200ms.pftrace`） | `BOARD_RUN_EXIT=0`；`PROBE_RC=0`；`TB_RC=0`；trace 21,681 B；`ticks=60` |
| 拉回 | `scp` 两份 trace + A/B 的 `*_probe.log`、`*_tb.log` | 0 |
| 分析 | `python3 analyze.py`（v58.2 TP 跑 accept.sql S1–S8 + heap_live_timeline） | 0 |

**产物校验**（sha256，见板端输出）：
- A：`ec392840ae22bd8e0937b95e229000c1e5f30c488921e0041f2cbaf01a837dbb`
- B：`6bd51270c1c87e09b5971ebef54dfd468d67b6ec6ec980da0f2fc844b2fabc11`

**会话机制**（`board_run.sh`）：`--notify-fd` 读 1 字节（0=就绪）→ 启动 `LD_PRELOAD` + `PERFETTO_HEAPPROFD_BLOCKING_INIT=1` 的 memprobe → `wait` 程序 → `kill -TERM` → `wait` tracebox（进程退出=最终 flush）→ 校验文件。板端日志确认 `SIGINT/SIGTERM received: disabling tracing` 与 `Wrote … bytes`。

## 2. A/B 实测结果（v58.2 TP）

| 项目 | A（无 tick） | B（tick 200 ms） |
|---|---|---|
| trace 时长（trace_bounds） | 12.67 s | 13.63 s |
| 目标进程 | `name_candidates=2, data_bearing=1` → UPID **191** | 同 → UPID **192** |
| **dump 数** | **1** | **6** |
| dump 轴（ts_end, dur） | 1 点，**dur=0** | 6 点，**dur 全为 0** |
| allocation 行数 | 4 | 16 |
| Total / Free | 28.00 / 28.00 MiB | 28.23 / 28.23 MiB |
| Max Live / Last Live | **0 / 0** MiB | **8 / 0** MiB |
| Live 曲线 | `[0]` | `[8,8,8,0,0,0]` |
| 调用栈符号 | 11/11 帧有名，3 个 build_id；`probe_live_block`/`probe_churn_cycle` 均在完整链中 | 15/15 帧有名；额外 `probe_tick_alloc` |
| heapprofd stats | unwind_samples=264, client_disconnected=1, 无 buffer_overrun/data_loss | unwind_samples=474, client_disconnected=1，无错误 |
| **S4 状态** | `CAPTURE_OK_BEHAVIOR_INCOMPLETE`（l2_behavior_failed=3） | `CAPTURE_OK_BEHAVIOR_INCOMPLETE`（l2_behavior_failed=1） |

B 组失败项只有 `hold_within_dump_window_bounds`：`hold_bounds_s=[6.01,6.01]`（窗口零宽，见 §4）。
其余行为项全过：Total 28.23 MiB（+0.22 MiB = 60×4 KiB tick）、Free 匹配、Max Live 8 MiB、`post_release_dumps=2`。

**调用栈证据（B 组一次 8 MiB 分配）**：
```
depth 3 malloc            /data/libheapprofd_glibc_preload.so
depth 4 probe_live_block  /data/memprobe
depth 5 main              /data/memprobe
depth 7 __libc_start_main /usr/lib/libc.so.6
depth 8 _start            /data/memprobe
```
（叶子 0–2 层是 preload 的 malloc hook 内部帧，部分无名；不影响业务帧归因。）

## 3. 与 x86 v58.2 实验的一致性

| 现象 | x86（v58.2 采集） | X5（v57.1 采集） | 一致？ |
|---|---|---|---|
| A 组 dump 数 | 1 | **1** | ✅ |
| A 组 Max Live | 0 | **0** | ✅ |
| B 组 dump 数 | 6 | **6** | ✅ |
| B 组 Max Live | 8 MiB | **8 MiB** | ✅ |
| B 组 tick 数 | 60 | **60** | ✅ |
| B 组 `dur` | ~2000 ms | **0** | ❌ **版本差异** |
| `accept.sql` 状态 | B：PASS | B：BEHAVIOR_INCOMPLETE（仅 hold 窗口项） | ❌ 由 dur 差异导致 |

**版本差异原因（源码级）**：TP `profile_module.cc` 注释明确 "Start of the window. Older producers don't emit it, so the window collapses to a point (start == end)"；`profile_packet.proto` 的 `start_timestamp = 15` 标注 "Unset on older producers"。本地 v54 源码中 `DumpProcessState` 确实没有 `window_start`/`start_timestamp` 逻辑（v58.2 才有）。X5 采集端是 **v57.1**，因此 `heap_profile.dur` 恒为 0。

## 4. 哪些现象可由现有 trace 证明

- ✅ X5 上 heapprofd **能完整采集 malloc/free**：Total/Free 28 MiB（B 组 28.23 MiB，含 tick），`client_disconnected=1` 正常收尾，无 buffer overrun / data_loss。
- ✅ **调用栈有效**：`probe_live_block`（祖先链，cum 8 MiB）、`probe_churn_cycle`（cum 20 MiB）、B 组 `probe_tick_alloc`；15/15 帧有名字，3 个 build_id。
- ✅ **A/B 差异可复现**：无 tick → 1 份 dump、Max Live 0；加 200 ms tick → 6 份 dump、Live 平台 8 MiB 后回落 0。
- ✅ **"长持有只有 1 份 dump"在 X5 上同样出现**（与 x86 一致），机制是 heapprofd 的 `window_end` 只随分配推进 + TP 按 `(upid, window_end)` 去重。
- ✅ 两份 trace 均可被 v58.2 TP 完整解析（S1–S8 全部 rc=0）。

## 5. 仍有不确定性 / 未验证

1. **`heap_profile.dur=0` 的直接原始字段证据**：目前依据 TP 源码注释 + v54 源码无该字段 + 观测一致性推断 v57.1 未 emit `start_timestamp`；未逐字节解析 ProfilePacket 验证。
2. **持有区间判定**：v57.1 下窗口不可知，`accept.sql` 的 hold 判定失败属**度量能力缺失**，不能据此说"持有时间不符"。
3. **符号化流程**：本次 trace 自带函数名（preload hook 帧部分无名），**未执行** `trace_processor bundle --symbol-paths` 做离线符号化/Build ID 匹配。
4. **板端 v58.2 采集**：若要让 `dur` 正常、使 accept 判定完整，需要把板端 tracebox 升级到 v58.2 —— 本轮按约束**未升级板端**，未验证。
5. **其他配置**：`block_client:true`、其他 `dump_interval_ms`、Android kCentral 模式均未测。
6. **单机单次**：每组仅 1 次采集，未做重复性统计。

## 6. 如何打开与观察

见 `README_UI.md`（打开方式、找进程/轨道、指标选择、Add debug track 步骤、A/B 对比点、能证明/不能证明、排查清单）。

## 7. 交付文件

```
x5_heapprofd_validation/
├── x5_heapprofd_A_no_tick.pftrace      (21,346 B)
├── x5_heapprofd_B_tick_200ms.pftrace   (21,681 B)
├── A_accept_results.txt / B_accept_results.txt   (S1–S8 原始输出)
├── A_heap_live.csv / B_heap_live.csv             (ts,value_mib,series)
├── A_memprobe.log / B_memprobe.log               (程序 EV 日志)
├── A_tracebox.log / B_tracebox.log               (会话日志)
├── A_board_console.txt / B_board_console.txt     (板端脚本输出)
├── SUMMARY.txt                                   (关键指标汇总)
├── analyze.py                                    (可复现分析脚本)
├── README_UI.md                                  (UI 操作指南)
└── FINAL_REPORT.md                               (本文件)
```
