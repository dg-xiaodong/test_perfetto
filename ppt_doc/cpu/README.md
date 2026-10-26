# pf-cpu-case CPU 性能分析（RDK X5 / Perfetto）

由 `perfetto-cpu-debugging` Skill v0.1.0-candidate 驱动的真实上板测量结果。所有数字来自板端真实采集的 `.pftrace`
+ 公共业务时延记录 `heartbeat_latency.csv`，未使用源码、自测材料、私有日志或 Ground Truth。

---

## 先看哪个文件

| 目的 | 文件 |
|---|---|
| **当前实例的完整报告（先看这个）** | [`FIRST_PASS_REPORT.md`](FIRST_PASS_REPORT.md) |
| **当前实例的 Trace（用 Perfetto UI 打开它）** | [`captures/cpu_run3.pftrace`](captures/cpu_run3.pftrace) |
| Skill 缺口清单 | [`SKILL_GAPS.md`](SKILL_GAPS.md) |
| 上一轮（更空闲的板面）报告与 Trace | [`previous_quiet_instance/`](previous_quiet_instance/) |
| 上一轮 Trace | [`previous_quiet_instance/captures/cpu_firstpass.pftrace`](previous_quiet_instance/captures/cpu_firstpass.pftrace)（观察者未绑核）、[`cpu_firstpass2.pftrace`](previous_quiet_instance/captures/cpu_firstpass2.pftrace)（观察者已移出工作核） |
| Perfetto UI 截图 | [`captures/p12.png`](captures/p12.png) |

打开方式：把 `.pftrace` 拖进 <https://ui.perfetto.dev/> 即可，无需安装。Trace 为 Perfetto v57.1 格式。

> **注意别搞混实例**：`captures/cpu_run3.pftrace` 对应 `pf-cpu-case` **pid 8143**（当前运行实例）；
> `previous_quiet_instance/` 下两个 trace 对应**已被重启的旧实例 pid 1762**，只能配旧的
> `heartbeat_latency.*.csv` 使用。两份报告的跨实例对照见 `FIRST_PASS_REPORT.md` §6。

---

## 一句话结论

心跳线程 `pf-svc-tick`（nice+10，绑 cpu1）的尾部延迟**来自同核的 `pf-worker-p`**：
对 trace 内全部 482 段 runnable 等待逐段归属，`pf-worker-p` 持有 **227.018 / 240.168 ms = 94.5%**；
同板另外两个 benchmark 用例虽然合计占 59% 系统 CPU，对心跳延迟的直接贡献只有 **0.06%**。
延迟增量 100% 来自"等待上 CPU"，tick 自身 on-CPU 反而更低（0.944 vs 1.185 ms/slice）。

---

## 目录内容

```
ppt_doc/cpu/
├── README.md                  ← 本文件
├── FIRST_PASS_REPORT.md       ← 当前实例（pid 8143）报告，已冻结
├── SKILL_GAPS.md              ← Skill 缺口清单（新增 5 项 + 遗留 11 项）
├── FROZEN_SHA256.txt          ← 上面两个文件的冻结哈希
├── SHA256SUMS.txt             ← 本目录全部文件哈希（除自身）
├── analyze.py                 ← 分析脚本（生成报告中的统计数字）
├── run_sql.sh / run_sqlf.sh   ← trace_processor 查询封装（stdout/stderr 分离）
├── captures/                  ← Trace、公共时延 CSV、板端采集脚本、采集日志、UI 截图 p12.png
├── cfg/                       ← 实际生效的 TraceConfig（.pbtxt）与生成/校验记录
├── sqlout/                    ← 原始 SQL 与原始输出（含 skill 自带 02/03/05/06/08）
└── previous_quiet_instance/   ← 上一轮：更空闲板面下的同程序测量（2 条 trace）
```

`sqlout/` 里的 `*.csv` 是 trace_processor 的原始输出，`*.stderr` 是它的日志（`column N = ...`、`Loading trace`），
`*-run.sql` 是把 Skill 模板参数替换后的可复现 SQL 全文。

### UI 截图

| 文件 | 内容 |
|---|---|
| `captures/p12.png` | Perfetto UI 全览（48 tracks）：`CPU 1 Scheduling`、`CPU 2 Scheduling`、`pf-worker-p 8147`、`pf-worker-q 8148`、`pf-svc-tick 8146`；时间轴上选中了一段约 **14.69 ms** 的区间，另有一处书签。对应 `captures/cpu_run3.pftrace`。 |

---

## 如何复核

```bash
# 1) 校验文件完整性
sha256sum -c FROZEN_SHA256.txt          # 报告未被改动
sha256sum -c SHA256SUMS.txt             # 全部文件
cd previous_quiet_instance && sha256sum -c FROZEN_SHA256.txt && sha256sum -c DELIVERABLES.sha256

# 2) 复跑关键数字（需要 trace_processor_shell v57.1）
TP=/path/to/trace_processor_shell
$TP query captures/cpu_run3.pftrace \
  "SELECT start_ts,end_ts,(end_ts-start_ts)/1e9 dur_s FROM trace_bounds"
#   期望：14378596598731, 14402583053700, 23.986455

# 3) 逐段归属（报告核心证据，SQL 全文见 FIRST_PASS_REPORT.md §10 第 7 步）
$TP query -f sqlout/run3/05-run.sql captures/cpu_run3.pftrace
```

> `trace_processor_shell` **不能**直接 `-f` 多语句文件（会报
> `Result rows were returned for multiples queries`）；`run_sql.sh` 已按单语句封装。

Perfetto UI 的逐项点击步骤见 `FIRST_PASS_REPORT.md` §10。

---

## 环境与边界（摘要）

| 项 | 值 |
|---|---|
| 板 | RDK X5，kernel `6.1.83-DR-PL5.1_V1.1.1`，aarch64，8 核同构，300–1500 MHz，`schedutil` |
| 采集器 / 分析器 | tracebox `v57.1-c59f57dd4` / trace_processor `v57.1-c59f57dd4`（严格同版本） |
| 观察者位置 | 绑核 cpu0/4，工作核 cpu1/cpu2 上 tracebox 占用 **0 ms** |
| 数据完整性 | 8 核 ftrace dropped/overrun = 0，`traced_buf_data_loss_*` = 0 |
| **UNKNOWN** | 官方 schema 级 PASS（无 collector descriptor）；perf 调用链祖先与内核帧（栈深度=1）；4.065/14.064 ms 量化的内核机制；窗口外事件的逐条归因；`pf-svc-tick` 的 21 ms `D` 状态成因；UI 截图 |

完整边界见 `FIRST_PASS_REPORT.md` §7。

---

## 映射到本地构建目录

这两份内容分别来自本机：

```
/root/sdk_ly_x5_1.1.1/tmp/perf-cpu-firstpass-r2/   →  ppt_doc/cpu/                      （当前实例）
/root/sdk_ly_x5_1.1.1/tmp/perf-cpu-firstpass/      →  ppt_doc/cpu/previous_quiet_instance/（旧实例）
```

报告正文里的相对路径（`captures/…`、`sqlout/…`）在本仓库同层级下依然有效，无需改写。
