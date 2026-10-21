# RDK X5 · Perfetto 全场景采集与验收报告（窗口 B · 独立诊断）

日期：2026-10-21 · 执行者：窗口 B · 目标：为 Perfetto 培训 PPT P2–P12 提供真实 Trace / UI 材料 / 可复核分析。

---

## 0. 结论速览（先回答 8 个问题）

**1) 实际获得了几份 Trace？**
**9 份真实 `.pftrace` + 1 份原始 `perf.data`**（清单见 §3）。其中 3 份是有效主数据：
`overview_system_app.pftrace`（120 s 综合）、`sched_blockwake.pftrace`（30 s 阻塞栈）、
`light_noperf_60s.pftrace`（60 s 开销对照）。

**2) 是否有一份能同时展示多种轨道的综合 Trace？**
**有。** `traces/overview_system_app.pftrace` 同时含：`linux.process_stats`（358 进程/409 线程）、
`linux.sys_stats`（meminfo/vmstat/每 CPU 时间/cpufreq）、`linux.perf`（92,271 个带调用栈的样本）、
SDK `track_event`（42,917 slice / 163,659 counter / 7,463 flow，5 个 category）、应用 Counter 与
跨线程 Flow、`FramePipeline` 异步轨道与帧 ID。**唯一缺的是 `linux.ftrace`**（本内核无 tracefs），
因此 sched_switch/sched_waking/sched_wakeup_new 无法进入该文件（已验证：`sched_slice`=0 行）。

**3) P2–P12 每一页是否都有真实数据支撑？**
**8 页完整、2 页部分、1 页缺失**：P2/P3/P4/P5/P7/P8/P11/P12 有完整真实数据；P9（Running/Runnable/Sleeping）与 P10（Block/Wake）为**降级证据**（P9 只有应用层代理，P10 有真实阻塞栈但无 waker）；**P6（Native Heap/Flamegraph）没有数据**（平台缺 heapprofd producer，已逐层排除）。
P9（Running/Runnable/Sleeping）只能给"应用层代理"（ThreadsRunning/ThreadsBlocked/CvWait），
不能给调度器三态；P7 没有"sched 时间线"，改为 cpufreq+perf+cpustat 的真实替代。
逐页证据见 `UI_DEMO_GUIDE.md`。

**4) 哪些 UI 需要专项 Trace？**
- P6：需要**另一块有 heapprofd 的设备/镜像**（本板无 producer），或窗口 A 部署 heapprofd 后重采；
- P10：使用专项 `sched_blockwake.pftrace`（`SW_CONTEXT_SWITCHES` 阻塞栈）；
- P7/P8：综合 Trace 已够用（cpufreq + perf callstack）；
- P9：综合 Trace + 专项阻塞 Trace 一起讲最完整。

**5) 四个 Skill 分别执行了哪些标准化动作？**
四家的 SKILL.md 路由、`scripts/survey.sh` 只读探测、configs 复用、全部 SQL 逐条执行、质量口径核对均已执行；
CPU 的 `make_config.py`/`linux_trace_session.sh`、Scheduling 的 `record.sh`、Latency 的 `make_config.py`/
`analyze.py`、Memory 的 `01-rss-timeline` 均实际运行过并记录了结果/失败原因。详见 `SKILL_GAPS.md` §0。

**6) 诊断与 Ground Truth 是否一致？**
**主干一致**：周期结构、6 阶段签名、CPU 竞争、队列积压、内存脉冲与延迟无关、推理是 CPU 模拟、
`cpu.pf-infer`≈63%/contend≈34%（实测 60.9%/32.9%）、CvWait/CvTimeout 计数、MIXED 的 postprocess 瓶颈。
**两处不一致**：本实例 SCHED_CONTENTION 的 e2e（981 ms vs 194 ms）与队列（avg 9.6 vs 1.9）更高；
`SchedWakeupOvershootMs` 出现 20–21 ms 次众数尖峰（GT 记录 ≤0.85 ms）。已用无 perf 对照
排除采集开销，并解释为"临界系统双稳态 + 本实例竞争者更多"。详见 `GROUND_TRUTH_COMPARISON.md`。

**7) 哪些能力未实现、为什么？**
sched_switch/sched_waking/sched_wakeup_new、thread_state（Running/Runnable/Sleeping）、
CPU idle tracepoint、Native Heap/Flamegraph —— 前四项因内核 `CONFIG_FTRACE` 未开；
Heap 因 Linux 版 Perfetto 未含 `android.heapprofd` 数据源且常驻进程无 preload。
每项都有逐层证据与最小修复方向（`COVERAGE_MATRIX.md` §3、`SKILL_GAPS.md`）。

**8) 是否已具备制作正式培训 PPT 的全部素材？**
**P2/P3/P4/P5/P7/P8/P11/P12 已具备**（真实数据 + 可复核 SQL + 手工 UI 步骤）；
**P9 部分具备**（只能讲应用层代理）；**P6 不具备**（需补 heapprofd）；
**P10 具备 E2 级素材**（真实阻塞栈，无 waker）。
**UI 截图未完成**：本机无图形界面，且 `ui.perfetto.dev` 前端 bundle 13.6 MB 在 ~44 KB/s 的
不稳定链路上无法就绪（详见 `UI_DEMO_GUIDE.md` §0，已留 3 张"UI 已打开"的真实截图）。

---

## 1. 独立诊断流程（按任务要求的顺序，全部实操）

### 1.1 第一步：平台与目标检查（`logs/STEP1_PLATFORM.md`）
- 只读探测：8 核 aarch64、6.1.83-DR-PL5.1_V1.1.1、`CONFIG_FTRACE` 未开、**无 tracefs**（
  `/sys/kernel/tracing` 不存在、kallsyms 无 `__tracepoint_sched_switch`）、`perf_event_paranoid=2`、
  `perf_event_mlock_kb=516`、cpufreq sysfs 可用、`/userdata` 26 G 可用。
- Perfetto：tracebox/traced/traced_probes 均 v58.2；常驻 traced 持有 `/tmp/perfetto-{producer,consumer}`；
  **未注册** `linux.perf` 与 `android.heapprofd`；SDK producer `pf-demo-x5` 已注册 `track_event`（5 类）。
- 目标：`pf-demo-x5` pid 1090、14 线程、未 preload、无 LD_PRELOAD、affinity 0-7。
- 冲突：`tracebox --system-sockets` 会抢系统 socket（实测导致 CLI 失去连接，随后板卡重启一次）；
  后续一律用 `perfetto` CLI 连常驻 traced，并额外起**唯一一个** `tracebox traced_perf` 作为 perf producer。

### 1.2 第二步：最小 Smoke（3 次，10–15 s）
| Smoke | 配置 | 结果 |
|---|---|---|
| `smoke_noperf_10s` | process_stats+sys_stats+track_event | 4,067 slice / 745 flow / 0 sched；TrackEvent 正常 |
| `smoke_perf_nosource_15s` | +linux.perf（当时无 traced_perf） | rc=0 但 `perf_sample`=0 → **证明"启动成功≠数据存在"** |
| `smoke_perf_15s` | 起 traced_perf 后重试 | 11,607 样本、叶子函数可读（CpuWork/InferenceConv3x3） |

### 1.3 第三步：综合采集（120 s，2.5 个周期）
- 采集前确认周期：日志 `PHASE` 行间隔 8.008 s×6 = **48 s**；120 s 覆盖 cycle 14/15/16。
- 4 次采集迭代，最终 `overview_120s_v4` 作为交付：**单一 perf producer**、1 个 perf session、
  92,271 样本、perf 记录丢失 2,761（3.0%）、应用 buffer `data_loss_*` 全 0。
- 前三次迭代分别暴露：`target_cmdline` 过滤不生效（→`*_cmdline-filter-variant`）、
  多 producer 导致 3 个 perf session（→`*_dup-perf-producer-variant`）、重复启动（v3）——
  这些都作为证据保留，不是"失败重试被丢弃"。

### 1.4 第四步：Memory（见 `results/skill/mem-*`、`results/custom/c12,c13,c13b`）
- RSS/系统内存：**PASS**（目标 RSS 5,884→17,708 kB，anon/file/shmem/watermark 齐全；系统 meminfo 10 类）。
- Native Heap：**FAIL**（0 行；逐层排除见 `COVERAGE_MATRIX.md` §3）。
- 口径核对：RSS ≠ heap live；`LiveAllocatedBytes` 是应用自报；`mem.rss` 为直采 counter（bytes）。
- 发现 Skill 缺陷：`mem-01-rss-timeline` 的 stdlib 输出与直采 counter 单位不一致（G10）。

### 1.5 第五步：CPU（见 `results/skill/cpu-*`、`results/custom/c09,c10,c11,c14,c21`）
- on-CPU 切片：**0 行**（无 sched）→ 不能做 CPU ms 排名；改用 perf 采样 + cpustat + cpufreq。
- 热点：`InferenceConv3x3` 1,322 / `InferenceGemm` 979 / `CpuWork` 1,691（按调用点聚合）；
  线程分布 pf-infer 44.6%、pf-preproc 23.9%、pf-postproc 10.0%、pf-syncwait 9.2%。
- 频率：300–1500 MHz，8 核×241 点；CPU_BURST 均值 1,369–1,500 MHz。
- 数据质量：perf 丢样 3.0%，已在 UI 的 Trace health 中显示；结论按"采样"表述。

### 1.6 第六步：Scheduling（见 `results/skill/sched-*`、`results/custom/c15,c16,c22`）
- E1 状态事实：**不可得**（thread_state=0）；应用自报 `ThreadsRunning` 1–4、`ThreadsBlocked` 恒 0。
- E2 事件关联：**可得**。`SW_CONTEXT_SWITCHES` 采到每次上下文切换的调用栈（37,507 样本）：
  pf-output/pf-syncwait/pf-postproc/pf-preproc 阻塞在 `futex_wait`，pf-capture/contend/ioworker/memheap/monitor
  阻塞在 `hrtimer_nanosleep`；`contend.spin1/2` 与 `ThreadsRunning` 升高同窗。
- E3 机制：**未下定论**。没有 waker、没有同核证据、没有 R 态占比，所以只写"与 CPU 竞争一致"，
  **没有**把 futex 当锁持有者。

### 1.7 第七步：Latency（见 `results/custom/c01–c08,c20`、`results/skill/latency-*`）
- Slice 真实存在且嵌套正确（depth 0/1，父 id 可查）；Flow 是真实 `flow` 表 7,463 行，
  4 种跨线程边各 ~1,866 条；`FramePipeline` 为 async/custom 轨道（无 thread 绑定）。
- 帧 ID 与 e2e：233 帧，avg 341.7 ms / max 1,630 ms；按阶段分解：SCHED_CONTENTION 981 ms、
  MIXED_PIPELINE 719 ms、BASELINE 190 ms（排空）、CPU_BURST 56 ms、MEMORY_PULSE 46 ms、SYNC_IO 26 ms。
- Counter：QueueDepth 0–22、InflightFrames 0–25、EndToEndLatencyMs 6.8–1,641.6 ms、
  LiveAllocatedBytes 0–12,582,912 B、RssKb 5.3–17.8 MB、ThreadsRunning 1–4、SchedWakeupOvershootMs 0.04–21.4 ms。
- 推理阶段是 CPU 模拟（用户态符号 + CPU 热点），**未**写成 BPU 时延。

---

## 2. 逐项数据验收

见 `COVERAGE_MATRIX.md`。摘要：14 项能力中 **8 项 PASS**（进程/线程、RSS/系统内存、
CPU 频率、CPU 采样栈、应用 Slice、应用 Counter、跨线程 Flow、Frame ID/E2E、SQL/Debug Track 数据），
**5 项 FAIL**（sched slices、Native Heap、Heap 调用栈、Running/Runnable/Sleeping、Waker/Block-Wake），
第 6 项拆为 freq PASS + idle FAIL。每项都给出真实行数/数值与证据路径；0 行一律不判 PASS。

Trace 完整性：`traced_buf_bytes_overwritten=0`、`traced_buf_data_loss_*` 全 0、
`traced_chunks_discarded=37`（traced 内部 flush 计数，无对应数据丢失指标）；
唯一数据丢失是 `perf_cpu_lost_records=2,761`（perf 采样环形缓冲溢出，约占 3.0%）。

---

## 3. Trace 清单（文件、大小、SHA256）

| 文件 | 大小 | 说明 | SHA256 |
|---|---|---|---|
| `traces/overview_system_app.pftrace` | 6.85 MB | **主综合 Trace**，120 s，single perf session | `250b95cc59ee0cd170c4f214475df131f4c081d6600cf4401e35a7982c9a225a` |
| `traces/sched_blockwake.pftrace` | 2.77 MB | **阻塞栈专项**，30 s，`SW_CONTEXT_SWITCHES`+kernel frames | `beadb4f22d536d4170c905e3ba28074863fd609b800a4124a4ddf34a1ed78180` |
| `traces/light_noperf_60s.pftrace` | 1.58 MB | 60 s 无 perf **开销对照** | `b3c6b645ece408494c1a10c907888d5d4e8ed3ae4f9fa92e735b653c9dafd33b` |
| `traces/overview_system_app_cmdline-filter-variant.pftrace` | 10.7 MB | 第 1 版，`target_cmdline` 过滤不生效的证据 | `c23fc105cc4c956da519c2bd187a70936149bca64fa1b477d4d22f7ad1279355` |
| `traces/overview_system_app_dup-perf-producer-variant.pftrace` | 14.3 MB | 3 个 perf producer / 3 session 的证据 | `688d6b85d6de035ab1bcbb0967c26c0affd415fee7a55064c3390d1c9d6eb0d2` |
| `traces/smoke_noperf_10s.pftrace` | 0.31 MB | smoke：无 perf | `15d28cc87cd0f12e0ba8f21e597714ce3d702aea892ff6ede121663a0e1ab56b` |
| `traces/smoke_perf_15s.pftrace` | 0.89 MB | smoke：perf 成功 | `f9bb73eb88db866813d0ab12ac4dad4b463c52e3cf7a9b2b535344ba1a466ae5` |
| `traces/smoke_perf_nosource_15s.pftrace` | 0.40 MB | smoke：配置 rc=0 但 perf 0 样本 | `438a1c9f1dc4cd0aee074b6eeb8213d3566f67ec7b57d6e590f4a448be4df589` |
| `traces/native_heap_heapprofd_unavailable.pftrace` | 658 B | heapprofd 数据源不存在时的空 Trace | `6c4d2cc7a658ae59a7a53bfd0e5544c3b9cd3c2d0a069bd98d7619823ff21b53` |
| `traces/sched_blockwake.cs.perfdata` | 1.32 MB | 原始 `perf record -e cs -g`（6,023 样本） | `ae693ad2780551da3036af3631303719ec0bffcaa0c1a83b18681370d47416c8` |

原始采集日志（命令、`start_rc`、起止 uptime、板端 sha256）在 `logs/captures/<name>/`；
全部哈希清单在 `logs/TRACE_SHA256SUMS.txt`。

---

## 4. 采集命令（可复现）

板端（`perfetto` CLI 连常驻 traced，避免第二个 tracing service）：

```sh
D=/userdata/perfetto-training-demo
# 0) 只读探测
sh /userdata/perfetto-b/scripts/survey-cpu.sh
$D/bin/perfetto/perfetto --query | sed 's/\x1b\[[0-9;]*m//g'
# 1) 唯一一个 perf producer（若已存在则不要重复启动）
$D/bin/perfetto/tracebox traced_perf --background
# 2) 采集（配置中的 TARGET_PID_HERE 由 app.pid 注入）
sh /userdata/perfetto-b/scripts/remote_capture_only.sh \
   /userdata/perfetto-b/cfg/overview_120s_v2.cfg /userdata/perfetto-b/out/overview_120s_v4
# 3) 拉回并校验
sha256sum /userdata/perfetto-b/out/overview_120s_v4/trace.pftrace
```

主机分析：

```sh
TP=/root/.cache/perfetto-skill/trace_processor_shell
$TP query traces/overview_system_app.pftrace -f results/custom/c20-phase-metrics/query.sql
```

---

## 5. 关键发现（可复核）

1. **周期与阶段签名**：48 s/6 阶段；延迟从低到高：SYNC_IO 26 ms < MEMORY_PULSE 46 ms <
   CPU_BURST 56 ms < BASELINE 190 ms（排空）< MIXED_PIPELINE 719 ms < SCHED_CONTENTION 981 ms。
2. **CPU 竞争阶段**：`contend.spin1/2` 170/173 条（avg 115 ms、max 200 ms）、`ThreadsRunning` 3.63–3.75、
   `cpu.pf-contend1/2` max 32.9%、`cpu.pf-infer` max 60.9%、cpufreq 1.5 GHz、`InferenceStub` avg 85.5 ms
   （baseline 16 ms）→ **CPU 被抢、推理被拉长**（E2）。
3. **队列积压阶段**：QueueDepth avg 11.8/max 22、Inflight 25、postprocess avg 57.2 ms（瓶颈阶段）、
   e2e 719 ms → **反压来自 postprocess**（与 GT 一致）。
4. **内存脉冲**：每周期 12 MiB 分配、hold 4 s、`malloc_trim` 后 RSS 回落；该阶段帧延迟 46 ms（快），
   **内存脉冲不是延迟根因**。
5. **阻塞归因**：流水线四段 `futex_wait`（条件变量），contend/capture/monitor/ioworker/memheap 为
   `hrtimer_nanosleep`；pf-syncwait 全窗口 CvWait 112.6 s。
6. **格式与口径**：`FramePipeline` 无线程绑定（async/custom）；Flow 是真实跨线程边；
   perf 样本≠调用次数；cpufreq 空≠0 MHz（本板有数据）。

---

## 6. 事故与平台限制（必须写进培训材料的边界）

| 事件 | 事实 | 影响与处理 |
|---|---|---|
| 板卡 3 次无预警重启 | `hobotboot.reason=REBOOT_CMD`，dmesg 无 watchdog/panic；首次与 `tracebox --system-sockets` 时间重合，另两次无定论 | 所有采集短时+立即拉回；最终数据在无重启窗口完成（`env.txt` 记录起止 uptime） |
| `tracebox --system-sockets` 抢占系统 socket | 之后 `perfetto --query` 报 `Could not connect to /tmp/perfetto-consumer` | 放弃该方式；改用 `perfetto` CLI + 额外 `traced_perf` producer |
| 多个 `traced_perf` producer | 同一会话出现 3 个 `perf_session`、采样 ×3、丢样上升 | 采集前 `ps -ef | grep 'tracebox traced_perf'` 保证唯一 |
| 无 tracefs | sched/idle/block tracepoint 全部不可用 | 见 `COVERAGE_MATRIX.md`；Scheduling 降级为 E2 |
| 无 heapprofd | 数据源未注册（非 preload 失败） | P6 无素材，给出最小修复 |
| 主机 TP v57.1 vs collector v58.2 | 跨版本解析成功但未做 schema 校验 | 结论标注 SCHEMA_UNKNOWN |

---

## 7. 交付物索引

```
perfetto_ppt/demo_capture/
├── REPORT.md                      ← 本文件
├── UI_DEMO_GUIDE.md               ← P2–P12 逐页操作指南（含真实时间戳/字段/SQL）
├── COVERAGE_MATRIX.md             ← 14 项能力 PASS/FAIL/UNKNOWN + 证据
├── SKILL_GAPS.md                  ← 四个 Skill 的缺口（G1–G17）
├── GROUND_TRUTH_COMPARISON.md     ← 与窗口 A 答案的逐项对照 + 诊断正确性
├── traces/                        ← 9 个 .pftrace + 1 个 perf.data（SHA256 见 §3）
├── configs/                       ← 实际使用的 cfg + 四个 Skill 原配置 + COMPOSITION.md（组合理由/差异）
├── sql/skills/<skill>/            ← 四个 Skill 原样 PerfettoSQL（未修改）
├── sql/custom/                    ← 本次补充的 24 条分析 SQL（已标注"临时补充"）
├── results/skill/                 ← Skill SQL 原始输出（每目录 query.sql/stdout.csv/stderr.txt/rc.txt）
├── results/custom/                ← 自定义 SQL 原始输出（同上）
├── results/custom-blockwake/      ← 阻塞栈 SQL 输出
├── results/ROUND1_DIAGNOSIS.md    ← 首轮独立诊断（冻结，含独立 SHA256）
├── logs/ENVIRONMENT.md            ← 版本/哈希
├── logs/SKILLS_LOADED.md          ← Skill 路径/版本/树哈希
├── logs/STEP1_PLATFORM.md         ← 第一步只读探测记录
├── logs/TRACE_SHA256SUMS.txt      ← Trace 哈希
├── logs/captures/<name>/          ← 每次采集的 env/start/cmd/notify
└── screenshots/                   ← 3 张真实"UI 已打开"截图；P2–P12 轨道截图待执行
```

## 7.1 仓库状态

- 交付物已提交到本地仓库：`perfetto_ppt/demo_capture`（commit 见 `git log -1 -- perfetto_ppt/demo_capture`；
  `traces/*.pftrace`、`*.perfdata` 被 `.gitignore` 排除，未进 git，实际内容与哈希见 `traces/README.md`）。
- **未推送**：`git push --dry-run origin main` 返回
  `fatal: could not read Username for 'https://github.com'`（本机无 GitHub 凭据）。
  需要推送时请先配置凭据；Trace 文件 41 MB，建议走 release/对象存储或按需单独传输。
- 同一份交付物也复制到了另一个工作副本 `/root/code_1.0.20/tmp/test_perfetto/perfetto_ppt/demo_capture/`。

## 8. 最小后续动作（按优先级）

1. **补 heapprofd**（P6）：部署 Linux `heapprofd` producer + 以 preload 启动专用实例，重采 30 s。
2. **换 ftrace 内核**（P7/P9/P10 完整版）：`CONFIG_FTRACE=y` + `CONFIG_SCHED_TRACER`，可一次拿到
   sched_switch/sched_waking/wakeup_new、power:cpu_frequency/cpu_idle，四个 Skill 的 sched 配方才可用。
3. **稳定竞争阶段**：把 SCHED_CONTENTION 的推理量或帧周期调离临界点，使 e2e 在不同实例上可复现
   （当前 200 ms ↔ 1.6 s 双稳态）。
4. **UI 截图**：在有 UI 的机器上按 `UI_DEMO_GUIDE.md` 执行；Trace 文件与时间戳已固定。
5. **TP 版本对齐**：把主机 TP 升到 v58.2（本次受网络限制未能下载）。
