# cpu_test3 — RDK X5 `task-service` 请求延迟抖动：Perfetto CPU 实测诊断

本目录是一次**独立盲诊断**的完整结果：只读确认 → 单次 55 s Perfetto 采集 → 主机 Trace Processor
SQL 分析 → 结论 + 证据等级。**未停止/重启/修改被测服务，未改 sysctl / governor / 挂载，未修改 Skill。**
未读取 `cpu_test2`、测试源码、GROUND_TRUTH 或 selfcheck 材料。

- 板卡：`Linux buildroot 6.1.83-DR-PL5.1_V1.0.20 aarch64`，8 逻辑核
- 服务：`/userdata/cpu-lab/bin/task-service --cpu-a 6 --cpu-b 7`（PID 10285，9 线程，亲和性只允许 CPU6–7）
- Trace：`cpu.pftrace`，7,024,848 B，`sha256 07f5596ecd9b1ff6fbeafde3a559b41011213dea35393d146b89f17f52da527a`
- 采集器 / 分析器：Perfetto **v57.1**（tracebox 与 trace_processor_shell 同版本）
- Skill：`perfetto-cpu-debugging` **v0.1.0 (candidate)**，`SKILL.md sha256 352986f5…`

## 结论一览

延迟"反复变大"是 **48 s 相位周期（`service.log` 的 `slot idx 0..5`，每格 8 s）里交替的三种机制**，本 trace 覆盖全部 6 格：

| 相位 | 请求延迟 | 机制（实测） |
|---|---|---|
| idx0 / idx4 | 14 µs | 正常 |
| idx5 | **2.25 ms（全部请求）** | 每请求 CPU 工作量放大 13 µs → 2.15 ms（`req_worker_main→ts_compute_cpu_budget→ts_mix_block`），**无等待** |
| idx1 | 14 µs | `calc-worker` 4×250 ms 满载尖峰，**不影响请求延迟** |
| **idx2** | **32 ms，峰值 52 ms** | **CPU6 饱和 + 10 ms 片轮转**：`req-worker`/`job-alpha`/`job-beta` 在 CPU6 各 10 ms 轮流，**CPU7 同期空闲**；52 ms 窗口内 CPU6 精确 100%、CPU7 0.6–0.8% |
| **idx3** | 15 µs，峰值 **92.8 ms** | **~91.6 ms 条件变量阻塞**（`pthread_cond_clockwait`），由 `hold-helper` 唤醒；期间 CPU6 1.3–2.4%、CPU7 1.0–2.1% |

关键旁证：

- **"CPU 升高"是进程/单核，不是整机**：服务总 CPU 6555 ms / 55 s = **11.9% 单核**（≈整机 1.5%）；idx2 单秒峰值 418 ms。1 s 粒度的 `top` 只能看到 25–40%，会漏掉窗口内 100% 饱和。
- **频率不是解释**：`schedutil` 在 300/600/1200/1500 MHz 间变化，但 idx2 饱和窗口 CPU6/7 实测 **1500 MHz**；idx3 是 Sleeping；温度 54.6 °C 无降频；CPU6 idle 89.8%、CPU7 idle 96.4%。
- **跨核**：服务被限制在 CPU6–7（其余 6 核闲置），`req-worker` 探测时只允许 CPU6；trace 内 9 线程 **1424 次 `sched_migrate_task`**，`req-worker` 93% CPU 在 CPU6。迁移不是延迟来源；**"2 核上限 + 全挤 CPU6"** 才是 idx2 的结构性瓶颈。
- **热点**（100 Hz `linux.perf`，600 个带栈样本，符号已解析）：`ts_mix_block`（请求/计算/竞争线程）、`flag_waiter_main`+`ts_spin_pause`（sync-waiter）、`hold_helper_main→sleep_for`（~5 ms 轮询一次）。均为用户态计算，非锁/系统调用。
- **反证**：idx1（calc 4×250 ms）与 idx4（sync-waiter 106 ms/s 自旋）期间请求仍 13.8–14.1 µs → "进程 CPU 高 ⇒ 请求慢"不成立。

## 证据等级（Skill 质量口径）

| 层级 | 判定 | 依据 |
|---|---|---|
| Schema | **UNKNOWN** | 仅 v58.2 descriptor 解析通过；板端采集器 v57.1，版本不匹配，不冒充 collector-matching PASS |
| Runtime | **PASS** | tracebox v57.1、`DONE size_bytes=7024848`、ftrace 事件真实存在、`linux.perf` producer 可用、无 sysctl 改动 |
| Data | **PASS** | 54.99 s；UPID 3；43,282 `sched_slice`；`thread_state` 含 Running/R/R+/S（无 D）；`cpufreq`/`cpuidle` 每 CPU 有数据；`perf_sample` 44,000（600 带栈、0 丢）；`stats` 全 0 |
| Analysis | **PASS（本机 SQL/TP 复算）**，**UI_UNKNOWN** | 所有数字可由 `sql-run/` + `analysis.py` 复现；未做 Perfetto UI 操作/截图 |
| 业务语义（hold 的具体条件/时长来源） | **UNKNOWN** | 需业务打点或源码，超出本轮允许材料；trace 只能证明"等 condvar ~91.6 ms、由 hold-helper 唤醒" |

已知局限：采集器自身 2751.8 ms CPU/55 s（CPU3 1896.6、CPU6 256.7，已披露）；无法从 trace 区分"应用临时把亲和性设为 CPU6"还是"负载均衡未拉走"（内核无 `sched_setaffinity` tracepoint）；10.00 ms 整片归因为推断（`ts_compute_cpu_budget` 命名 + 切片形态）。

## 文件

| 路径 | 内容 |
|---|---|
| `report.md` | **完整诊断报告**（状态确认、配置、验收、SQL 结果、两种慢模式的逐片证据、证据等级、UI 步骤、局限） |
| `commands-and-queries.md` | 首轮全部上板命令、SQL 与判读口径（可重放） |
| `cpu.pftrace` | 实采 trace（55 s：sched + cpu_freq/idle + linux.perf） |
| `cpu-combined.pbtxt` | 实际下发的合并配置（含偏离模板的理由注释） |
| `cfg-{overview,scheduling,frequency,profiling}.pbtxt` | 用板端真实 `available_events.txt` 生成的 4 条路线模板 |
| `available_events.txt` | 板端 `survey.sh --events` 原样输出（1170 行） |
| `sql-run/01…08-*.sql`、`q00-*.sql`、`00-inventory.sql` | Skill SQL（`target_upid=3`）与 inventory 拆分 |
| `q-*.sql` | 追加的针对性查询（唤醒者、迁移、逐核占用、频率/Idle、开销、stats） |
| `out/` | 上述查询的原始结果（CSV/TXT）与 `analysis-summary.txt` |
| `analysis.py`、`export_data.sh`、`runq.sh` | 可复现的分析与导出脚本 |
| `requests*.jsonl`、`service*.log` | 业务日志（采集窗口对齐用；板端随后自行轮转过日志，`requests-after.jsonl` 保留了窗口数据） |
| `cpu.log`、`cpu.status`、`cpu.pid`、`capture-*.txt`、`pull.txt` | 采集过程原始凭据（含 `host_pull.sh` 因无密码认证而失败的记录） |
| `manifest-sha256.txt`、`skill-hashes.txt` | 交付物 sha256 清单；实际加载 Skill 版本与哈希 |

## 复现

```bash
# 0) 依赖：Perfetto v57.1 的 trace_processor_shell
TP=/path/to/trace_processor_shell

# 1) 重新导出分析表（生成 out/q-*.csv）
TP=$TP sh export_data.sh

# 2) 复现报告中的分类/窗口/相位/频率数字
python3 analysis.py

# 3) 直接用 Skill SQL 复核（target_upid 已设为 3）
$TP query -f sql-run/01-cpu-usage.sql   cpu.pftrace
$TP query -f sql-run/02-thread-states.sql cpu.pftrace
$TP query -f sql-run/03-runnable-latency.sql cpu.pftrace
$TP query -f sql-run/05-cpu-time-buckets.sql cpu.pftrace
$TP query -f sql-run/06-cpu-spike-episodes.sql cpu.pftrace
$TP query -f sql-run/07-perf-samples.sql cpu.pftrace
$TP query -f sql-run/08-core-busy.sql cpu.pftrace
```

Perfetto UI：<https://ui.perfetto.dev/> → Open trace file → `cpu.pftrace`，步骤见 `report.md` §8。
