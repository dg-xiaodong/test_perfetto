# Skill Gap 报告（本次实测中发现的问题）

原则：区分「Skill 已实现但本平台不可用」与「Skill 实现有缺陷/缺配方」。
下列每条都附本次真实证据；**未修改任何 Skill 文件**（`/root/.dsh/skills/*` 只读使用）。

## 0. 四个 Skill 的标准化动作执行情况

| Skill | 实际执行的标准动作 | 结果 |
|---|---|---|
| `perfetto-cpu-debugging` 0.1.0 | SKILL.md 路由 → 只读 `scripts/survey.sh`（CPU 版）→ 生成/复用 configs → `sql/00-inventory` 等 9 个 SQL 全部执行 → 质量口径核对 | 路由与 survey 正常；SQL 中依赖 sched 的 6 个返回 0 行；`04-cpu-frequency`、`07-perf-samples` 有真实数据 |
| `perfetto-memory-debugging` 1.0.0 | SKILL.md 路由 → `scripts/survey.sh` → configs 复用 → `sql/00..08` 全部执行 → 口径核对（RSS vs heap live） | `01-rss-timeline` 有数据（但单位口径异常，见 G5）；heapprofd 路线全链路不可用 |
| `perfetto-scheduling-debugging` 0.1.0 | SKILL.md 选路 → workflows/overview → `scripts/survey.sh`（TRACEFS=UNKNOWN）→ `scripts/record.sh` 预检 → `sql/00/00a/00b/00c/01/01b/02/03/04/05/06/07/08/08a/09` 全部执行 → E1/E2/E3 口径 | survey 正确报告无 tracefs；record.sh 无法执行；除 00/00b/00c/08/08a 外全部 0 行 |
| `perfetto-latency-debugging` 0.1.1 | SKILL.md → configs/track-event 复用 → `scripts/make_config.py` 语义 → `sql/00..14` 全部执行 → integrity/outcome 分开 | track_event 配方有效；`analyze.py` 的 `latency.v1` 契约与本程序命名不一致；`04-counters` 名称硬编码 |

## 1. CPU Skill

**G1（实现缺口，重要）`scripts/make_config.py overview/scheduling` 在无 ftrace 板卡上直接失败。**
`check_event('sched/sched_switch', events, required=True)` → 抛 `ValueError`，没有降级配方；
`--no-sched` 只允许 `frequency`/`profiling` 两条路线。X5 这类 `CONFIG_FTRACE` 未开的内核无法
生成任何 overview 配置（本次只能手工组合）。
证据：`configs/overview_120s.cfg`（手工组合）、`python3 scripts/make_config.py overview` 实测报错。

**G2（实现缺口）`linux.perf` 的 `target_cmdline` 过滤在本 collector 上不生效于采样侧。**
用 `scope { target_cmdline: "pf-demo-x5" }` 采 120 s：`swapper`（内核 idle）样本 170,461 / 184,799
（92%），且 `perf_session`=3、每 CPU 约 292 Hz（配置是 99 Hz）。
证据：`results/overview/05-perf-by-thread`、`results/overview/06-cpu-counter-tracks`、
`traces/overview_system_app_cmdline-filter-variant.pftrace`。
Skill 的 `references/03-profiling.md` 未给出「过滤只作用于保留、不降低采样量」的提示，
也未给"如何确认过滤生效"的检查 SQL。

**G3（配方缺口，高价值）未提供 `SW_CONTEXT_SWITCHES` 的阻塞栈配方。**
本次自行发现：`timebase { counter: SW_CONTEXT_SWITCHES period: 1 }` +
`callstack_sampling { kernel_frames: true }` 可在**没有 sched tracepoint** 的板卡上采到
"每次上下文切换的事件级调用栈"（leaf `schedule` → `futex_wait`/`do_nanosleep` → 用户线程函数），
这是 Scheduling Block/Wake 在无 ftrace 平台上唯一可得的 E2 证据。
证据：`traces/sched_blockwake.pftrace`、`results/custom-blockwake/c22-blocking-callstacks.csv`。

**G4（操作风险，已在本次造成故障）多个 `traced_perf` producer 会被同时分配同一 `linux.perf` 数据源。**
`tracebox traced_perf --background` 的进程 comm 是 `tracebox`，脚本里用 `pidof traced_perf`
判活在部分情况下取不到，导致重复启动；一个会话内出现 **3 个 perf session**、采样量 ×3、丢样上升。
证据：`results/skill/sched-08-perf-streams`（3 个 session）、`traces/overview_system_app_dup-perf-producer-variant.pftrace`。
Skill 的 `sql/08-perf-streams.sql` 恰好能暴露该问题（值得保留），但 README/流程没有"producer 唯一性"检查。

**G5（实现缺口）无 sched 时没有 CPU 时间的替代口径。** `01/02/03/05/06/08` 全部依赖
`sched_slice`/`thread_state`，本板全 0 行；Skill 未给 `linux.sys_stats` 的
`cpu.times.*`/`cpufreq` 作为近似口径的 SQL（本次临时补 `c13b-cpustat`、`c21-phase-cpufreq`）。

## 2. Scheduling Skill

**G6（实现缺口，致命）`scripts/record.sh` 强依赖 tracefs 且无降级。**
脚本开头检查 `tracing_on`/`events/enable`，但真正的阻塞点是 `grep scheduling.switch` 与
block-wake 配置必须引用 `sched/sched_switch`；本板 `survey.sh` 已返回 `TRACEFS=UNKNOWN`，
`make_config.py overview` 直接失败 → **四个 workflow 在本平台全部无法执行**。
本次改用官方 `perfetto` CLI + `tracebox traced_perf`（临时补充）。

**G7（配方缺口）缺少"无 thread_state 时的证据降级包"。**
`sql/00b-quality.sql`、`00c-schema.sql`、`08-perf-streams.sql` 在无 sched 板卡上仍然有用
（本次确实用到），但 Skill 没有把「应用自报 ThreadsRunning/Blocked、CvWait/CvWakeup slice、
`SW_CONTEXT_SWITCHES` 阻塞栈」定义为 E1/E2 的替代证据，导致使用者在 workflow 第一步就卡住。

**G8（文档缺口）`references/platforms.md` 的 X5 段落写的是"历史基线"，未提示
「X5 默认镜像 CONFIG_FTRACE 未开」这一决定性事实**，只在质量口径里泛泛提到"内核事件实际存在"。
建议把「先 `survey.sh` 看 TRACEFS，UNKNOWN 时直接走 §G7 降级包」写成显式分支。

## 3. Memory Skill

**G9（配方缺口，重要）`android.heapprofd` 在 Linux 板卡上默认不存在，配置却能"成功"启动。**
`configs/native.pbtxt` 直接给 `android.heapprofd`；在 X5 上采集 **rc=0、notify=0**，但输出仅 658 B、
`heap_profile_allocation` 0 行。Skill 的质量章节要求"实际采到"，但 configs/流程里没有
**采集前**的数据源注册检查（`perfetto --query | grep heapprofd`），也没有区分
"数据源未注册 / 进程未匹配 / 无 dump / 无符号"的判定脚本。
证据：`traces/native_heap_heapprofd_unavailable.pftrace`、`logs/captures/heaptest`。

**G10（实现缺陷，可复现）`sql/01-rss-timeline.sql` 与原始 counter 口径不一致。**
同一时刻（ts=700000583666）：
- 原始 `mem.rss.anon` counter = 1,077,248 B（`results/custom/c12-rss-target`）；
- Skill SQL 输出 `UPID 179 | anon (MiB)` = **0.769531**（`results/skill/mem-01-rss-timeline`）。
两者差约 1.3×，说明 stdlib `memory_rss_and_swap_per_process` 的字段/单位与
`linux.process_stats` 直采 counter 不是同一口径。Skill 未提示该差异，容易在培训材料里写错单位。
建议：先用 `c12-rss-target` 这类直采 counter 校准，再使用 stdlib 视图。

**G11（覆盖缺口）没有"Linux 无 heapprofd 时如何演示 native 分配"的替代方案**
（如 `perf` 采样 malloc 热点、`ltrace`/`heaptrack`），也没说明这些替代**不是** heap live 数据。

## 4. Latency Skill

**G12（实现缺口）`scripts/analyze.py` 只接受自家 `latency.v1` 命名，缺少字段映射层。**
`00-inventory.sql` 用 `${CATEGORY}`，00/01/10/11/12/13 依赖 `lat.request.begin/end`、
`debug.run_id/stream_id/request_id`。本程序用 `FramePipeline` + `debug.frame_id/e2e_ms`，
`latency-00-inventory` 实测 `app_slices=0`，`analyze.py` 必然抛 `NO_TRACK_EVENT`。
SKILL.md 说"先明确一对一字段映射"，但没有提供映射模板/适配脚本，使用者需完全手写。

**G13（配置口径）`04-counters.sql` 硬编码 `lat.queue_depth*`**，对通用命名（`QueueDepth`）无效；
`${CATEGORY}` 的默认值 `rdk.latency` 也会让"拿现成 trace 先看"这一步直接空结果。

**G14（好的部分，建议保留）** `03-quality.sql`（stats 原样导出）、`02-flow.sql`（只导出真实 flow）、
`configs/track-event.pbtxt`（disabled_categories "*" + 精确 enable）在本次全部验证有效。

## 5. 跨 Skill 与工具链

**G15（工具链）主机 TP v57.1 / 板端 collector v58.2 版本不一致。**
四个 Skill 都写"host TP same or newer"，但本机只有 v57.1（`/root/.cache/perfetto-skill/trace_processor_shell`），
新版本下载受网络限制（13.6 MB UI bundle 实测 ~44 KB/s）。
本次 v58.2 trace 能被 v57.1 解析（含 `perf_session`/`swapper` 等），但属于**未经验证的跨版本组合**，
已在该 Trace 的结论里标注。

**G16（操作风险）`tracebox --system-sockets` 会替换系统 socket 路径。**
本次在常驻 `traced` 已占用 `/tmp/perfetto-{producer,consumer}` 时执行，随后板卡重启
（dmesg `hbootboot.reason=REBOOT_CMD`，非 watchdog/panic；重启原因不能 100% 归因于该操作，但
时间点重合，且重启后 CLI 恢复可用）。四个 Skill 都没有"系统已有 traced 时禁止 autostart tracebox"
的显式互锁检查；建议在 record.sh 增加 `pidof traced` 与 socket 属主检查。

**G17（组合缺口）没有官方"多 Skill 合并配置"生成器。**
本次按「process_stats + sys_stats + track_event + linux.perf」手工组合（`configs/overview_120s.cfg`），
数据源选择依据分别来自四个 Skill 的 configs；差异与理由记录在 `configs/COMPOSITION.md`。
