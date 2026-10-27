# SKILL_GAPS — `perfetto-latency-debugging` v0.1.1 candidate 实测缺口

本轮在 X5 上对 `pf-lat-case` 做真实诊断时，按 Skill 的规定流程（TrackEvent → record.sh → analyze.py → 手动 UI/SQL）执行；以下是**实际影响本轮结论或效率**的缺口。每条给出：现象、影响、建议。

---

## G1. Counter 盘点不在 analyzer/checklist 里，容易漏判（本轮 rev1 即因此误判，rev3 已修正）

- **现象**：本 Trace 实际**存在** `lat.queue_depth.q_pre/q_work/q_out` 三个 Counter（各 3,600 采样点）。但首轮报告 rev1 误判为『Counter 不存在』——盘点轨道时只查了含 Slice 的 track（`slice.track_id` 路径），没有单独枚举 `counter_track`；`analyze.py` 虽导出了 `04-counters`（非空），但没有任何步骤提示『这些 Counter 存在、可用作队列模型验证』，于是被忽略。
- **影响**：按 rev1 结论会错失一个现成的独立验证手段（峰值深度、排空斜率可直接对账排队模型），并向 Skill 报了一条不存在的缺口。
- **建议**：
  1. `analyze.py` 的 summary 增加 `counter_tracks` 清单（名称/点数/min/max），非空时显式列出；
  2. 诊断 checklist 加一条：队列类结论必须与 `lat.queue_depth.*`（若存在）对账；
  3. `04-counters` 导出附每条 Counter 的 min/max/argmax，而不只是原始值流。
- **修订记录**：rev1 误判 → rev3 修正本条，并在报告新增 §5.7（q_out 峰值 51 @ 慢消化结束点、排空 ≈5.1ms/个、q_pre/q_work ≤1）。

## G2. 没有“原因/相位/触发”事件，机制只能靠时长分布反推

- **现象**：事件只有 begin/request/end/stage/stage.result/queue/send/receive；没有“故障窗口开始/结束”“负载阶段”“降级标志”一类事件或注解。
- **影响**：本轮能确定“逐请求、按到达时间门控、固定 +14 ms / +80 ms”，但无法从 Trace 说明**为什么**窗口在 20.0 s / 6.0 s（mod 30 s）打开；这正是报告里标 UNKNOWN 的部分。
- **建议**：在 Skill 增加一节“诊断型可选事件”：`lat.phase.begin/end`（phase_id、原因标签）或 `lat.trigger`，并规定：没有该类事件时，报告必须把“机制/触发”单列为 UNKNOWN——本轮已按此纪律执行。

## G3. 配置校验器拒绝 sched 之外的所有 ftrace 事件 → 无法用 syscall 区分“sleep / futex / 锁”

- **现象**：`scripts/validate_config.py` 的 `check_policy()` 对 `linux.ftrace` 强制
  `set(ftrace_events) == {'sched/sched_switch','sched/sched_waking'}`，**多一个事件即 FAIL**（"unexpected/missing sched event"）。而 `make_config.py` 也没有通用的 `--events` 注入。
- **影响**：本轮看到慢 `output` 93.2% 时间在 `S`、约 16×5 ms 轮询，但无法进一步区分：
  `nanosleep`（显式 sleep 循环）/ futex-with-timeout（`condition_variable::wait_for`）/ `try_lock_for`。
  三者对“修什么”含义不同，这是本轮最实质的证据缺口。
- **建议**：增加一个**受限**的补充模式（例如 `--with-syscalls`，仅 `sys_enter_nanosleep`/`sys_exit_nanosleep`/`sys_enter_futex`/`sys_exit_futex`，仍限定时长/缓冲），并在校验器里作为显式、可审计的第三种 recipe；否则诊断报告只能停在“定时轮询”这一层。

## G4. `analyze.py` 缺少“阶段/队列 × 时间相位”和“线程状态叠加”的派生输出

- **现象**：`analyze.py` 产出逐请求/阶段/队列/Flow 的明细与严格统计，但没有：
  - 按时间分桶/相位窗口的 stage/queue 中位数；
  - `lat.stage` × `thread_state` 的 Running/S/Runnable 叠加（`sql/14-thread-overlay.sql` 只面向函数事件/线程 Track，且未纳入 analyzer）。
- **影响**：本轮这些表全部是手写 SQL + Python 生成；可复核，但**不在 Skill 的固定产物里**，换人容易漏做“S vs Running”的关键一步（只看 85 ms 墙钟会误判为 CPU 慢）。
- **建议**：把“阶段 × Runnable/Running/Sleeping 叠加”做成 analyzer 的可选输出（有 sched 时默认开），并在 `03-analysis.md` 明确：“慢阶段必须先用线程状态分类，再谈 CPU/调度归因”。

## G5. 版本匹配没有闭环：Skill 依赖 SDK v58.2，但不提供/不校验 TP 版本

- **现象**：板端 tracebox 为 v58.2；host 默认缓存的 TP 为 **v57.1**（`/root/.cache/perfetto-skill/trace_processor_shell`）。本轮另找到同版本 v58.2 TP 才做最终分析（v57.1 结果与 v58.2 完全一致，仅作交叉校验）。
- **影响**：若严格按环境默认，会出现“collector v58.2 + TP v57.1”的版本错配；`analyze.py` 不检查也不警告，`run.json` 只记录 TP hash，不记录版本字符串。
- **建议**：
  1. `analyze.py`/`run_query.py` 在 `run.json` 增加 `tp_version` 与 `collector_target`，并在主版本不一致时输出 `VERSION_MISMATCH` 警告；
  2. `scripts/prepare_sdk.py` 或 `survey.sh` 提供“按 SDK 版本获取匹配 TP”的可选步骤（离线环境给出手工放置说明）。

## G6. `record.sh` 的 READY 语义容易被误读为“数据可用”

- **现象**：`record.sh` 的 READY 只代表数据源已启动（notify byte=0），`status.txt` 明确是 `RECORDED_DATA_UNCHECKED`；但脚本成功返回 0 时，日志里仍有 `RECORDED_DATA_UNCHECKED`，与“采集成功”的直觉不同。
- **影响**：本轮没有误判（随后跑了 inventory/quality），但对自动化管线，`rc=0 + 非空文件` 很容易被当成验收通过。
- **建议**：在 `record.sh` 输出里加一行固定的后续动作提示（“run analyze.py / check stats before claiming success”），或让 `analyze.py` 在 quality 失败时返回显式 `DATA_QUALITY_BLOCKED`（目前 `quality_loss` 只进分析 JSON）。

## G7. 捕获边界语义：只观察到 `capture_start_in_flight`，没有 `capture_stop_in_flight`

- **现象**：sched Trace 起始处出现 1 个 `lat.request.boundary=capture_start_in_flight`（对应 1 个 CENSORED 请求）；停止时 28 个在途请求没有 `capture_stop_in_flight`，被正确判为 INCOMPLETE，但无法区分“正常截断”与“丢事件”。
- **影响**：本轮通过 `exit.txt`/flush 统计/`quality` 已排除丢数据；但若 flush 失败，单靠 INCOMPLETE 无法给出 CENSORED。
- **建议**：示例在停止路径补发 `capture_stop_in_flight`（或 Skill 明确“停止边界默认 INCOMPLETE，需配合 flush 统计”）。

## G8. 缺少“相位/窗口”这一分析原语的文档

- **现象**：本例的主异常是**周期性时间窗**内的固定附加延迟；Skill 的分析规则覆盖请求/阶段/队列/Flow/帧/函数，但没有“按 wall-clock 相位切窗并对比阶段中位数”的固定方法。
- **影响**：本轮自行定义窗口（`app_time mod 30 s`）并用 50 ms 采样精度声明边界；若换人分析，可能只看到“P95 高”而错过 30 s 周期与双窗口。
- **建议**：在 `03-analysis.md` 增加“周期性/窗口型异常”一节：先做 E2E 时间序列与自相关/相位对齐，再按窗口切阶段；并强调“窗口内/外的同阶段对比”优先于“全局最长 Slice”。

---

## 不属于 Skill 缺口、但本轮必须声明的边界

- 本轮**未读取** `pf_lat_case.cpp` / 私有 Ground Truth / 自测报告，未反编译；因此“每 30 s 打开两个窗口”的**目的**无法也不应被推断。
- 板端同时运行 `pf-cpu-case` 与 `pf-sched-case`；它们对“逐请求固定增量”的解释力已被 §5.6/§7.3 的证据排除，但系统级噪声仍会使 P99 有毫秒级波动（不影响量级结论）。
