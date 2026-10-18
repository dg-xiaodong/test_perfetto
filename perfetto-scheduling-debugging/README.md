# perfetto-scheduling-debugging v0.1.0 Candidate / Usable Baseline

独立的 Perfetto Scheduling Agent Skill。核心是**慢窗口状态分解 → 定向切出/唤醒抓栈 → 单次等待关联 → 有界唤醒关系调查**。不是通用 CPU 火焰图工具，也不修改已经落盘的 Memory/CPU Skill。

## 版本状态：v0.1.0 Candidate / Usable Baseline

归档日期 2026-10-18。本目录是**经过真实 RDK X5 首轮上板验证**的 v0.1.0 Candidate 归档（不升级为正式 Stable）。
来源：本机实际安装并用于上板诊断的同一份 `perfetto-scheduling-debugging`（原始 candidate 包，
代码/脚本/SQL/配置/参考文档与本归档**逐字节一致**，仅归档文档与清单更新，见 `PROVENANCE.md`）。

板端验证证据：<https://github.com/dg-xiaodong/test_perfetto/tree/main/v5_test>
（真实 trace、两套 TraceConfig、逐条 SQL 输出、采集与质量日志；`cap1 42d885fe…`、`cap2 fd34cfd8…`）。

**已完成真实 X5 验证：**

- 基础调度采集与线程状态分析（60 s 全系统 `sched_switch`/`sched_waking`，Running/Runnable/Sleeping 分解）。
- Runnable 延迟及同核竞争归因（CPU 2 上 `req-dispatch` + `compute-1` + `compute-2` ≈90% 占核、~10 ms 片轮转）。
- 定向 `sched_switch` / `sched_waking` 调用栈采集（6 个目标 TID 过滤、`period:1`、`kernel_frames:false`）。
- 部分切出与唤醒事件关联（切出 5/6 `MATCH_UNIQUE`；唤醒 2/6 `MATCH_UNIQUE`，其余按缺失保留 UNKNOWN）。
- 跨进程唤醒与 futex 活动分析（helper→`ipc-client` 跨进程唤醒发生在 helper 的 `sys_futex` 内）。

**尚未完成全部专项验收：**

- 多级等待链完整归因（wakeup chain 仅在已观察关系上展开）。
- 干扰事件的板端错误关联专项验证（错身份/错 CPU/错来源的板端回归）。
- 超时等待原因识别（futex 参数/返回码未采集）。
- Perfetto UI 实际操作（只给出手动步骤，未做 UI 验收）。

**已知限制：** 事件采样可能缺失（本轮回升到 `perf_cpu_lost_records=724+73`，主线程切出样本约 54% 丢失）；
部分唤醒调用栈不可用（唤醒样本多落在 idle/IRQ 上下文）；perf 样本与 ftrace 事件存在 16.8–111.4 µs 工具侧时间偏差，
关联需显式容差并逐条核对唯一性（本轮用 150 µs）；**不能从唤醒关系直接推断锁所有权**，`MATCH_UNIQUE` 只表示约束下唯一候选。
不得据此宣称 C1–C6 全部通过。

## 安装给 Agent

将 ZIP 解压后的 `perfetto-scheduling-debugging/` 完整目录安装到所用 Agent 支持的 skills 目录。`SKILL.md` 必须位于该目录顶层；不能只复制入口。具体安装根目录按 Agent 产品配置确定。本包不会联网、安装软件或自动注册自己。

从解压后的 Skill 根目录执行：

```sh
python3 scripts/verify_package.py
python3 scripts/validate_config.py --check-resources
python3 -m unittest discover -s tests -v
```

主机工具仅要求 Python 3.9+（标准库）；官方 schema 验证额外需要 Python protobuf 和**对应版本** descriptor。编译测试程序需要 Linux + C++17 编译器。板端脚本不需要 Python。Perfetto 可执行文件、目标依赖、私有业务 Trace 不随包分发。

## 最短使用

已有 Trace：

```sh
# TP 必须由当前环境提供，勿凭路径猜测版本。
TP=/absolute/path/trace_processor_shell
python3 scripts/run_query.py --tp "$TP" --trace /absolute/input.pftrace \
  --sql sql/00-threads.sql --out /absolute/new-inventory
```

查明 UTID 和纳秒窗口后：

```sh
python3 scripts/render_sql.py sql/01-state-window.sql \
  --utid 17 --start-ns 1000000000 --end-ns 1020000000 > state-window.sql
# 17 和时间仅演示；用本 trace 的实际值。UI 可直接执行渲染后单条 SQL。
```

上板采集的完整可复制流程见 `references/platforms.md`。事件抓栈不能跳过目标 TID 和事件 format 确认；`configs/block-wake.example.pbtxt` 的 TID 是演示值，**不能直接上板**。

## 目录与实际能力

- `workflows/`：overview、block/wake、直接唤醒链与 Critical Path 辅助、futex 条件增强。
- `scripts/`：配置/预算、策略及可选 schema 校验、采集/拉回、SQL 参数与执行、日志延迟分解、哈希验证。
- `sql/`：每文件一个结果集；参数以 `{{name}}` 表示，由 render_sql 填写。
- `examples/schedprobe.cpp`：有界的 C1 条件变量、C2 同核竞争、C3 跨进程 futex 测试程序。
- `tests/`：错身份/错事件来源/错 CPU/缺栈/多候选、窗口裁剪、跨进程、采集退出与超时等测试。

## 验证状态

详见 TEST_REPORT。SQLite fixture 证明查询逻辑在约定表结构下的行为，**不等于实际 TP 或 X5 已通过**。构造程序的主机运行也不等于板端事件栈正确关联。关联输出 `MATCH_UNIQUE` 仅表示约束下唯一候选，还需检查源映射、丢数、栈和时钟证据。

## 与其他 Skill

Memory 管内存占用与分配；CPU 管执行开销与 On-CPU 热点；Scheduling 管线程推进障碍。可交接同一 trace 哈希、工具版本、目标 UTID 和慢窗口，不重复采集。基础脚本采用前两版经验重新实现，没有继承其板端 PASS 状态。

安装时不自动上板。先用 `AGENT_HANDOFF.md` 的安装检查，再用短 Prompt 做场景测试。
