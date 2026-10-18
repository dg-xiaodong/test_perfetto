# X5 `sched-case-daemon` 调度 / 同步等待诊断（Perfetto）

本目录是对 RDK X5 上常驻服务 `sched-case-daemon` 的一次**独立、盲诊断**交付：不读测试构造/答案材料，
只基于现场采集的真实 trace、SQL 与业务日志。Skill：`perfetto-scheduling-debugging v0.1.0 Candidate`。

## 最关键的四个事实

1. **两类慢请求，去向完全不同**（E1）
   - `dur≈10.0 ms` 的请求：时间 ≥99.9% 消耗在 **Running**（本线程在 CPU 2 上执行）；
   - `wait≈34.5 / 18 / 16 ms` 的请求：时间 99.6–99.9% 消耗在 **Runnable**（已唤醒、抢不到 CPU 2），
     睡眠只有 14–28 µs，请求排队（enqueue→wake）只有 14–90 µs。
2. **CPU 2 上只有 3 个线程在跑**（E3）：`compute-2`(35.3%) + `compute-1`(30.9%) + `req-dispatch`(23.8%)
   ≈ 90% 单核；三者同进程、同一亲和性 `2`，以 ~10 ms 片轮转。CPU 1 基本空闲（主线程 11.5%，其余 ≤0.23%）。
3. **阻塞/唤醒路径可定位**（E2）：`req-dispatch` 的切出栈 = `dispatch_entry()→syscall`（futex）；
   唤醒者 = 主线程，唤醒栈 = `enqueue_request()→run_one_cycle()→main`，且 6 次唤醒全部落在主线程的
   `sys_futex` slice 内部。**futex slice 35.3 ms ≠ 睡眠 0.78 ms**：其中 34.4 ms 是 Runnable。
4. **跨进程唤醒存在**（E2）：helper 在自己的 `sys_futex` slice 内唤醒 `ipc-client`；
   但锁地址/类型/owner、10 ms Running 内部在算什么 = **UNKNOWN**（未采集，不编造）。

## 目录

| 路径 | 说明 |
|---|---|
| `REPORT.md` | 主报告：E1/E2/E3 分层结论、SQL 结果、数据质量、开销、未覆盖能力、UI 步骤 |
| `COMMANDS.md` | 本次实际执行命令（口令脱敏） |
| `traces/cap1-overview.pftrace` | 主采集：仅调度数据，60 s，覆盖一个完整突发簇 + 基线 |
| `traces/cap2-blockwake.pftrace` | 定向采集：有过滤的事件调用栈 + `sys_futex`，60 s |
| `configs/` | 实际 TraceConfig（`overview.pbtxt`、`block-wake.pbtxt`）+ v57.1 descriptor 与元数据 |
| `logs/` | survey、线程清单、配置生成/校验、采集/拉回、schema、12 簇汇总、collector 日志、status/exit |
| `results/cap1/`、`results/cap2/` | 按 trace 分组的每条 SQL 输出：`stdout.csv` + `run.json`（含命令、退出码、三个 SHA256）+ 渲染后 `query.sql` |
| `sql/` | Skill 自带 SQL + 本次自定义查询 |
| `data/` | 业务日志、可用事件清单、两个事件 format |
| `SHA256SUMS` | 全部文件哈希 |

## 快速打开

1. Perfetto UI（`ui.perfetto.dev`）打开 `traces/cap2-blockwake.pftrace`。
2. 缩放到 **436039–436171 ms**：`req-dispatch` 线程轨可见 `Runnable 34.374 / 17.515 / 16.058 ms`
   与 `Running 10.49 / 10.29 / 10.17 ms`；同时展开 CPU 2 轨，可见 `compute-2/compute-1/req-dispatch`
   的 ~10 ms 交替。
3. 点击 Runnable 段起点的 `sched_waking` 看唤醒者（`sched-case-daem` 977）与 `enqueue_request()` 栈；
   点击切出侧 `sched_switch` 样本看 `dispatch_entry()→syscall`。
4. 另见 `REPORT.md §12` 的完整 9 步 UI 配方（含 W2：456040–456061 ms 主线程 R+ 20.1 ms）。

## 版本

- 采集器 `tracebox` = Perfetto **v57.1-c59f57dd4**（板上 `/userdata/cpu-lab/perfetto-session/tracebox`）
- Trace Processor = Perfetto **v57.1-c59f57dd4**
- TraceConfig 校验：`POLICY_PASS` + `SCHEMA_PASS`（官方 v57.1 `trace_config` descriptor，protoc 3.12.4）
