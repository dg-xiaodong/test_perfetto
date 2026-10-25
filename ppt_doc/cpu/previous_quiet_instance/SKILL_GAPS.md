# SKILL_GAPS.md — `perfetto-cpu-debugging` v0.1.0-candidate 实盘缺口清单

- 使用者场景：X5（RDK，kernel 6.1.83，aarch64，8 核同构，root）上一次真实的 CPU 异常 + 业务心跳时延分析
- Skill 版本哈希（见 FIRST_PASS_REPORT §8）：树哈希 A `85e518409ee47f20ad012b1a1d0b05558fdd19dd2a6b56deeedaaf55c7ae073c`；MANIFEST 自校验 0 mismatch
- 严重度：**blocker** = 直接卡死流程；**high** = 会误导结论；**medium** = 需手工绕行；**low** = 体验问题

---

## GAP-1（high）采集器自身会落到被测核上，10–20 ms 量级的自干扰没有出现在任何文档里

**现象（实测）**：run1 里没有对 tracebox 做任何限制，它的主线程（tid 1787）在 **cpu1**（恰好是心跳线程 `pf-svc-tick` 与 `pf-worker-p` 共用核）上拿到 594 ms，形成 **19.8 / 21.4 / 19.8 ms 连续块**。这直接造成 3 次 12.6–13.4 ms 的心跳尖峰——**与"被测异常"同量级**。

**为什么是 high**：Skill §3 只提醒"`linux.perf` 是采样、Profiler 本身可能影响性能"，但没有任何地方说：
- collector 的 drain / 采样 / unwinding 线程是**不绑核**的，会去"相对空闲核"，而"相对空闲核"通常正是被测任务所在的核；
- 这种干扰是**离散 10–20 ms 块**，量级和调度类异常完全重合，不区分就会把观察者当根因（或反过来掩盖真根因）。

**建议补丁**（任选，建议全做）：
1. 在 `references/05-quality.md` 的"四级验收"里增加第 5 项"**Observer placement**"：`SELECT p.name, th.name, GROUP_CONCAT(DISTINCT s.cpu) FROM sched_slice ... WHERE p.name LIKE '%tracebox%'`，**必须确认 collector 没有落在被测线程的核上**。
2. 在 `references/04-platforms.md` 的板端流程里给一条标准做法：
   `taskset -c <非工作核> tracebox ...`（或壳脚本包装，因为 `linux_trace_session.sh` 里 `"$TRACEBOX"` 是整体引用，无法直接传多词命令——见 GAP-7）。
3. `sql/` 增一个 `09-observer-overhead.sql`（tracebox/perfetto 自身按核 CPU 时间 + ≥3 ms 连续块），作为 Data 级验收的固定一项。

---

## GAP-2（blocker）`trace_processor_shell query -f` 无法运行 Skill 自带的 `00-inventory.sql`

**现象**：

```
$ tp query -f sql/00-inventory.sql trace.pftrace
Trace loaded: 1.61 MB in 0.07s
Result rows were returned for multiples queries. Ensure that only the final
statement is a SELECT statement or use `suppress_query_output` ...
(exit 1)
```

`00-inventory.sql` 有 5 条语句，其中 4 条返回行（trace_bounds / per-process / thread_state / cpu_counter_track / stats），任何一条非末位都会触发上述错误。而 Skill §2 与 `04-platforms.md` 写的正是
`trace_processor_shell query -f sql/00-inventory.sql captures/cpu.pftrace`。**照抄必失败**，而且报错信息与"SQL 写错"无关，很容易被误判为 trace 有问题。

**绕行**（本次做法）：按语句切分，逐条 `tp query <trace> "<SQL>"`，并把 stdout/stderr 分开（stderr 里夹着 `column N = ...` 与 `Loading trace`，直接 `2>&1` 会把日志插进 CSV 中间，实测出现过行被截断的假象）。

**建议补丁**：
1. `00-inventory.sql` 拆成 `00a/00b/00c...`，或改成"只保留最后一条 SELECT、其余用 CTE 合并"。
2. 提供 `scripts/run_sql.sh <trace> <sqlfile>`，内部按 `;` 切分、逐条执行、stdout/stderr 分离——本次已自造（`run_sql.sh` / `run_sqlf.sh`），可直接吸收。
3. 在 `SKILL.md` 的交付清单里明确"多语句 SQL 不能 `-f`"。

---

## GAP-3（high）`scope.target_cmdline` 没有被实际执行，采样实际是全机的

**现象**：配置里写 `callstack_sampling { scope { target_cmdline: "pf-cpu-case" } }`，但 trace 里 16000 条 `perf_sample` 中有 **15613 条归属 `pid 0 ([NULL])`**，只有 294 条属于目标进程 —— 即 tracebox v57.1 在这块板上并没有按 cmdline 过滤，而是每 CPU 100 Hz 全量采样。

**为什么是 high**：`references/03-profiling.md` 说"采样调用栈 scope 按真实进程名称筛选"，并强调"系统级 summary tree 不可冒充目标 UPID 热点"。实际行为与文档假设不一致：如果分析师直接看 `linux_perf_samples_summary_tree`，看到的是**全机**（且 97.6% 归到 pid 0）的分布，极易误判。

**建议补丁**：
1. `03-profiling.md` 增一条硬性验收：`SELECT p.pid,p.name,COUNT(*) FROM perf_sample ... GROUP BY p.upid` —— 若目标进程样本占比异常低或大量落 `pid 0`，判定 scope **未生效**，后续统计必须**只按 utid 归属**取数。
2. 给出"perf_sample 归属 pid 0"的可能原因（内核态/未归属样本），避免被当成 data loss。

---

## GAP-4（high）栈深度 = 1，但文档默认你拿得到调用链

**现象**：`stack_profile_callsite` 的 `max(depth) = 1`（run1：23 callsite / 23 frame；run2：34 callsite）。栈里只有叶帧 `pfp::p_kernel_hot` / `pfq::q_kernel_hot`，**没有任何祖先**，也没有内核帧（尽管配置了 `kernel_frames: true`）。

**为什么是 high**：`03-profiling.md` 说"UI 中……使用 Flamegraph"，`06-ui.md` 说"选目标进程 Perf Samples → Flamegraph"；但深度 1 的 flamegraph 只有一根柱子，**无法回答"哪个函数链路在烧 CPU"**，只能回答"哪个叶子函数被采样到"。文档没有把"栈深度"列为验收项，也没有说明这种情况下应改走 `perf record -g --call-graph fp`。

**建议补丁**：
1. `03-profiling.md` 验收清单加一条：`SELECT MAX(depth) FROM stack_profile_callsite`；`=1` 时明确写 "ancestry UNKNOWN"，并把替代路径（离线 `perf record -g`→导入）写清楚。
2. `sql/07-perf-samples.sql` 的注释里加一句"leaf only；本查询不能当函数级 CPU 时间或调用链"。

---

## GAP-5（medium）`host_pull.sh` 在这块板上必然失败（缺 legacy `scp -O`）

**现象**：板上 OpenSSH 与主机新 scp 不兼容，`scp`（SFTP 协议）报 `lost connection`；加 `-O` 后单文件成功。多文件 `scp -O a b c dest` 仍然失败（必须逐个文件传输）。

`04-platforms.md` 提到了"若远程 `scp` 环境需要 legacy `scp -O`…先设置主机 SSH/SCP 客户端"，但 `scripts/host_pull.sh` 里是裸 `scp -q`，**没有任何开关**，照跑就 `PULL FAIL: scp ...` 退出 1。

**建议补丁**：`host_pull.sh` 支持 `SCP_OPTS`（默认空，可用 `SCP_OPTS=-O`）并逐个文件调用（当前实现已经是逐个调用，只需把选项加上）；或者在 `04-platforms.md` 写明"若失败先 `export SCP_OPTS=-O`"。

---

## GAP-6（medium）`make_config.py` 没有组合路线，freq + perf 只能手工拼

**现象**：`route` 是四选一，`frequency` 不给 `linux.perf`，`profiling` 不给 `power/cpu_frequency` + `sys_stats`。本次要做"同一条时间轴上同时看调度/频率/热点"，只能：用 `frequency` 生成 → 再把 `profiling` 模板里的 `linux.perf` 段原文追加。追加块是逐字段抄的，但没有任何工具校验这个组合的合法性。

**建议补丁**：加 `--also-perf/--also-freq` 这类修饰参数，或直接给一个 `route=all`（sched + freq + idle + sys_stats + perf），并在 `validate_config.py` 里对"perf 段必须含 target"做检查。

---

## GAP-7（medium）`linux_trace_session.sh` 无法接受带参数的 TRACEBOX（不能直接绑核）

**现象**：脚本里是 `"$TRACEBOX" --txt -c ...`，`TRACEBOX` 被当整体引用，因此 `TRACEBOX="taskset -c 0,4,5,6,7 /path/tracebox"` 会失败（`ERROR: tracebox not executable`）。本次只能另写一个 `tracebox_pinned.sh` 壳脚本包一层。这与 GAP-1 的修复直接耦合。

**建议补丁**：支持 `TRACEBOX_LAUNCHER`/`TRACEBOX_AFFINITY` 环境变量，或在 `linux_session_lib.sh` 里对 `TRACEBOX` 做 `set -- $TRACEBOX` 切分（注意路径含空格时要转义）。

---

## GAP-8（medium）Skill 包的 `tracebox` 获取路径没有闭环

**现象**：`04-platforms.md` 只写"另须按本机实际版本/架构把 tracebox 安装到该目录：**非随包附赠**"，但没有：去哪拿、如何和主机 `trace_processor_shell` 版本对齐、如何验证。本次是从同机另一个实验目录（`/userdata/perfetto-skill-lab/memory/tracebox`，v57.1）借用的；恰好主机 TP 也是 v57.1，才形成版本严格匹配。**如果主机 TP 是 v58 而板端只有 v57.1，本报告里 Schema 级会更不清楚。**

**建议补丁**：
1. 给一个"collector↔TP 版本一致性"检查命令（`tracebox --version` vs `trace_processor_shell --version`，比较 git hash 前缀）。
2. 给 tracebox 的获取与校验步骤（或直接说明"用 `perfetto` 官方 release 的 tracebox 静态包 + 记录 sha256"）。

---

## GAP-9（low）`05/06/02/03/07/08` 的"改参"全靠文本替换

`05/06` 各要在 `params` 里改 `target_upid / start_ts / end_ts / bucket_ns / threshold_ms`，`02/03/07` 改 `target_upid`，`08` 改窗口。本次用 `sed` 改并保留了改后全文（`sqlout/run*/**-run.sql`）才做到可复核。**建议**：改成 `CREATE PERFETTO VIEW` 参数或提供 `scripts/sql_with_params.sh`，避免"人肉 sed 出报告数字"。

## GAP-10（low）`configs/cpu-overview.pbtxt` 与 `cpu-frequency.pbtxt` 字节完全相同

`diff` 无差异（sha256 均 `2f18c8ab…`）。4 个模板里实际只有 3 种内容，"overview" 并不是"调度+频率+热点"的概览。命名会让人以为 `overview` 就够回答"CPU 高在哪"，而它其实没有 `linux.perf`。

## GAP-11（low）`sql/00-inventory.sql` 的 `cpu_counter_track` 统计不能区分 perf 时基与 cpufreq

`GROUP BY name` 只给出 `cpu-clock / cpufreq / cpuidle` 三类 track 计数，看不出 `cpu-clock` 是 perf 的 `SW_CPU_CLOCK` 时基（本次 8 核 × 2000 点），容易被误读成"CPU 频率只有 2000 个点"。建议在 inventory 里直接给出 `name, cpu, COUNT(*)` 与单位提示。

---

## 顺手记录：Skill 文档里被本次实测**证实**的部分（也建议写进 TEST_REPORT）

| Skill 断言 | 本次实测 |
|---|---|
| "X5 `perf_event_paranoid=2` 不等于 `linux.perf` 已可采样；必须实际检查 producer/结果" | 实测 paranoid=2、root、tracebox 内含 `traced_perf`（有 `stack-unwinding` 线程）→ **可以采样**，16000 样本。文档的"必须实测"是正确的姿势。 |
| "`power/cpu_frequency` 是变化事件，短 trace 无事件不等于频率为零；优先结合 `cpufreq_period_ms` 轮询" | 实测 cpufreq 计数器 250 点/核（200 ms 轮询 + 变更事件），min 300 / max 1500 MHz；`power/cpu_idle` 亦工作 |
| "CPU 时间桶必须做区间交集" | `05` 的 200 ms 桶在 3.937–4.496 s 的 p-burst 上正确切出 62.1/195.6/195.7/94.1 ms 四段（合计 547.5 ms ≈ 559.5 ms 窗口内的有效 CPU），未把整段计入起始桶 |
| "`linux.sys_stats` 的 cpufreq 轮询要 >10 ms" | 本次 200 ms，正常 |
| "频率与慢同窗不直接构成降频因果" | 实测**反相关**：慢的秒恰是 950–1175 MHz 的高频秒（见 FIRST_PASS_REPORT §5.7） |

---

## 汇总（按优先级）

| # | 严重度 | 一句话 |
|---|---|---|
| GAP-1 | high | collector 落到被测核造成同量级 10–20 ms 干扰，文档零提示 |
| GAP-2 | **blocker** | `query -f 00-inventory.sql` 直接报错，文档给的正是这条命令 |
| GAP-3 | high | `scope.target_cmdline` 未生效，97.6% 样本归 pid 0 |
| GAP-4 | high | 栈深度只有 1，flamegraph 调用链不可用，验收未覆盖 |
| GAP-5 | medium | `host_pull.sh` 缺 `scp -O`，本板必失败 |
| GAP-6 | medium | 无 freq+perf 组合路线，只能手工拼配置 |
| GAP-7 | medium | `linux_trace_session.sh` 不能给 tracebox 传参/绑核 |
| GAP-8 | medium | tracebox 获取与版本对齐无闭环 |
| GAP-9 | low | SQL 参数靠人肉 sed |
| GAP-10 | low | `cpu-overview.pbtxt` == `cpu-frequency.pbtxt` |
| GAP-11 | low | inventory 的 cpu_counter_track 汇总粒度太粗 |
