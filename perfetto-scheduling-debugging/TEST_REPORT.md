# v0.1.0 Candidate 测试报告

日期：2026-10-18。对象：本 ZIP 中的 `perfetto-scheduling-debugging`。

## 总结

**已完成独立包实现及本机离线验证。没有执行新的 X5、Android 或真实 Perfetto 采集，不声明已完成事件级板端验收。**

最新完整测试命令：

```sh
python3 -m unittest discover -s tests -v
```

原始输出：`tests/LOCAL_TEST_RESULTS.txt`。

结果：**59 个测试被发现，58 个通过，1 个跳过；无失败、无错误。**
跳过的是 `test_tp_optional.RealTP.test_real_inventory_queries`，原因是未提供真实 `TP_BINARY` / `TP_TRACE`。

本机环境：Linux x86_64；Python 3.13.5；SQLite（Python sqlite3）；g++ 14.2.0。板端脚本用本机 POSIX sh 与模拟 tracebox 子进程测试，不是板端 BusyBox 执行验证。

## 实际完成

| 检查 | 实際结果 | 证明范围 |
|---|---|---|
| 配置生成 | PASS | overview 不含 perf；block/wake 两路、明确 TID 过滤、无进程 scope；配置输出确定性 |
| 配置负例 | PASS | 无目标/缺事件/缺 format、非法 ring、错误页大小、预算超限、零时长、未知/重复字段拒绝 |
| Futex 配置增强 | PASS（策略层） | 显式 opt-in，要求 raw syscall 事件，生成 sys_futex 字段 |
| SQL 状态与区间 | PASS（SQLite fixture） | 窗口两端裁剪、未知 duration、完整与不完整等待、全系统竞争者 |
| 单次等待关联 | PASS（SQLite fixture） | 同/跨进程；错 UTID/CPU/source、无 clock/source 证明、IRQ/未知上下文、缺栈/展开错误、歧义、唤醒晚于重新运行等负例 |
| 调用栈/直接关系 | PASS（SQLite fixture） | 实际 callsite 祖先遍历；直接 waker 与锁所有权严格区分 |
| 请求延迟 | PASS | 排队、处理、入队到完成分别计算；非法顺序和未确认时钟拒绝 |
| 配置 descriptor 身份检查 | PASS（负例） | hash 不符会拒绝；不代表官方 TraceConfig schema 已执行 |
| Shell 语法 | PASS | 三份目标/主机 shell 的 `sh -n` |
| 采集生命周期 | PASS（mock） | 正常、早退、非零、空 trace、无 notify、失败 notify、超时非零；正常仅标 DATA_UNCHECKED |
| C1/C2/C3 测试程序 | PASS（本机） | C++17 编译含 -Wall -Wextra -Werror；三个模式均有界运行；跨进程模式实际产生两PID日志 |
| 资源检查 | PASS | 新增核心资源纳入 REQUIRED；缺失资源反例失败 |
| Python 编译 | PASS | scripts/tests 的 compileall |

SQL fixture 使用本包约定的 Perfetto 兼容列，并注册 `EXTRACT_ARG` 的 SQLite 测试替身。它验证关联算法，不验证 Perfetto 导入器、真实事件字段、perf stream映射或内核采样。
C1/C2/C3 主机程序运行验证的是负载基本可运行；没有附加调度 trace，因此没有把主机墙钟/CPU差值当成真实 Runnable Ground Truth。

## 尚未执行或不能据此宣称通过

| 项目 | 状态 / 原因 |
|---|---|
| 同版本官方 TraceConfig descriptor 完整解析 | NOT_RUN：本机没有 protoc/对应 descriptor；3 份配置仅完成策略子集校验，输出 SCHEMA_UNKNOWN |
| 真实 Trace Processor v57.1/v58.2 查询 | NOT_RUN：本机没有 TP；尝试下载工具与既有CPU trace时容器DNS解析失败，未继续重试 |
| 本次 X5 Linux event-based perf 抓栈 | NOT_RUN：没有连接目标板 |
| C1/C2/C3 真实事件/调用栈关联 | NOT_RUN：须在目标环境验证 event source、时钟、IRQ字段、样本覆盖及Ground Truth |
| perf_counter_track 来源映射的实际版本兼容 | NOT_RUN：查询前先查真实 schema；不按session ID顺序猜测 |
| Android 事件抓栈与权限 | NOT_RUN；平台说明不是端到端验收 |
| UI/Critical Path Lite/futex 展示 | NOT_RUN；只交付手动操作与降级规则 |
| 无 Skill / 有 Skill 独立 Agent A/B | NOT_RUN：未派遣独立Agent，不将fixture当行为评测 |
| 非4KiB页目标 | UNSUPPORTED_RECIPE：当前生成器拒绝事件抓栈配方；待独立验证 |

下载失败与环境边界记录见 `tests/environment_limits.txt`。不会继承 Memory/CPU 历史板端 PASS，也没有生成模拟 .pftrace 冒充真实数据。

## 发布前需要的最小目标验证

先安装检查，然后按 `tests/SCENARIOS.md` 做 C1、C2、C3，可逐项执行。每项都要保存真实配置、trace、采集器/TP版本、数据质量、源映射、目标TID/UTID、事件/样本身份、程序日志及查询输出。

C1确认双端关联；C2确认Runnable而非睡眠；C3确认跨进程waker未被过滤。缺字段或栈时允许正确降级，但不得将降级当成完整 Block/Wake 已通过。基础三项完成前不扩展成大规模压力或任意锁图恢复。

## 包完整性

`MANIFEST.json` 记录其余文件 SHA-256（排除 manifest 自身和 SHA256SUMS，避免自引用）；`SHA256SUMS.txt` 还包含 manifest 的哈希。ZIP CRC、解压路径与包内资源另经打包校验。

```sh
python3 scripts/verify_package.py
python3 scripts/validate_config.py --check-resources
```

版本状态保持 **0.1.0 / candidate**。未安装到用户Agent、未修改已有Skills、未推送任何仓库。

## 归档更新（2026-10-18）：真实 X5 首轮验证后的状态

本节是**归档时**的真实状态，覆盖上文 authored 时的 `NOT_RUN` 记录（原文保留为历史）；也说明上文
“未推送任何仓库”一句对应 authored 时状态——本轮已按用户要求归档到 `dg-xiaodong/test_perfetto`，
**Skill 诊断逻辑与核心实现未改动**。

验证对象：RDK X5（`6.1.83-DR-PL5.1_V1.0.20`，8 核），常驻 C++ 服务 `sched-case-daemon`（12 worker + main，helper 独立进程，亲和性 CPU 1-2）。
采集器 tracebox **v57.1-c59f57dd4**；Trace Processor **v57.1-c59f57dd4**；两份 TraceConfig 均通过**官方 v57.1 `trace_config` schema** 校验。
原始 Trace、SQL 输出与判定见归档仓库 `v5_test/`（cap1 `42d885fe…`、cap2 `fd34cfd8…`）。

### 本轮实际验证通过

| 能力 | 本轮证据 | 级别 |
|---|---|---|
| 基础调度采集 + 线程状态分析 | 60 s 全系统调度（无 perf）；窗口内 13/13 状态区间、无 UNKNOWN 缺口 | E1 |
| Runnable 延迟 / 同核竞争归因 | 请求线程 Runnable 占 wait 的 99.6–99.9%；CPU 2 三线程 ≈90% 占核 | E1/E3 |
| 定向 `sched_switch`/`sched_waking` 调用栈 | 两路 perf，`prev_pid`/`pid` 过滤，`period:1`；switch 侧 2344/2344 带栈 | E2 采集 |
| 部分切出/唤醒事件关联 | 6 个等待中切出 5 个 `MATCH_UNIQUE`（callsite 3）、唤醒 2 个 `MATCH_UNIQUE`（callsite 164）；其余 `SAMPLE_MISSING` 保留 UNKNOWN | E2 |
| 跨进程唤醒 + futex | helper→`ipc-client` 跨进程唤醒落在 helper 的 `sys_futex` slice 内；`sys_futex` 计时 ≠ 睡眠/持有时间 | E2 |

### 仍未完成 / 不得宣称通过

| 项目 | 状态 |
|---|---|
| 多级等待链完整归因 | 未完成：只沿已观察的唤醒边展开 |
| 干扰事件板端错误关联专项 | 未完成：错身份/错 CPU/错来源的板端负例未跑 |
| 超时等待原因识别 | 未完成：无 futex 参数/返回码 |
| Perfetto UI 实际操作 | 未完成（只交付手动配方） |
| C1–C6 全部通过 | **不成立**：本轮是真实服务盲诊断，不是 C1/C2/C3 夹具场景的逐项验收 |

### 本轮暴露的已知限制（已写入 README）

事件采样缺失（`perf_cpu_lost_records=724+73`；目标 977 切出样本 1438→659，988 局部仍有缺样本）；
唤醒调用栈多不可用（3033/3109 唤醒样本落在 idle 上下文）；perf 样本与 ftrace 事件存在 16.8–111.4 µs
工具侧偏差（成因未定，`clock_snapshot` 显示 boot−mono 仅 −0.625 µs），关联需显式容差（本轮 150 µs）并逐条验唯一性；
**waker ≠ 锁持有者**，`MATCH_UNIQUE` 不能升级为锁所有权结论。
