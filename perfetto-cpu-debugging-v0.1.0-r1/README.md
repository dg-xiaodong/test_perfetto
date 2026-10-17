# perfetto-cpu-debugging — v0.1.0-r1 Candidate

独立可安装的 Perfetto CPU 调试 Agent Skill（通用 Linux 优先，重点面向 RDK X5；包含 Android 适配提示）。目标为 **CPU 时间 → 调度状态/唤醒 → 频率/Idle → CPU 采样热点**，按需使用而不是默认全开。

## 快速使用

把 ZIP 解压得到的 `perfetto-cpu-debugging/` 整目录交给 Agent 的 Skill 目录（或明确指向 `SKILL.md`）；保留 references、scripts、sql、configs。板端仅使用 POSIX shell 和 tracebox，主机运行 Python/Trace Processor。

用户可以直接说：

> 使用 perfetto-cpu-debugging。RDK X5 上的一个 C++ 服务偶发卡顿，CPU 有尖峰，请帮我实际采集一份 trace 并定位哪个线程在忙，附 SQL 证据。不要重启生产业务。

> 我已有 pftrace，帮我找出 Runnable 排队时间最长的线程并判断是否可以确定调度延迟原因。

### 1. 采集前（目标机）

```sh
sh survey.sh --events > available_events.txt
sh survey.sh > survey.txt
```

将 `available_events.txt` 从目标机 SCP 拉回主机，再用于配置生成；不要直接使用随包示例充当实际支持事件。

### 2. 生成并检查（主机 Skill 根目录）

```sh
python3 scripts/make_config.py overview --events available_events.txt --duration-ms 15000 > cpu.pbtxt
python3 scripts/make_config.py scheduling --events available_events.txt > sched.pbtxt
python3 scripts/make_config.py frequency --events available_events.txt > freq.pbtxt   # 轻量：轮询+power，不含 sched
python3 scripts/make_config.py frequency --events available_events.txt --with-sched > freq_sched.pbtxt
python3 scripts/make_config.py profiling --events available_events.txt --target demo_svc --frequency-hz 100 > perf.pbtxt
python3 scripts/validate_config.py --check-resources
python3 scripts/validate_config.py cpu.pbtxt
# 可选，若有与目标采集器构建相匹配的官方 descriptor：
python3 scripts/validate_config.py cpu.pbtxt --descriptor-set /abs/trace_config.desc
```

- `configs/*.pbtxt` 是生成的**静态示例**，事件能力和 `example_app` 目标名不是板端实测；部署前基于实际设备重新生成。
- `linux.perf` 只在实际权限/producer/采样能力允许时启用，不自行调低 sysctl。
- 采集执行、SCP、Trace Processor 与 UI 流程在 `references/04-platforms.md`、`06-ui.md`。

### 3. 分析（主机或 Perfetto UI）

先执行 `sql/00-inventory.sql`（单条 SQL）找到目标 UPID；再按需跑 `00a-trace-bounds.sql`、
`00b-thread-states.sql`、`00c-counter-tracks.sql`、`00d-stats.sql`。每个文件只含一条 SELECT 且必须
**单独执行**（v57.1/v58.2 的 `query -f` 不支持一个文件多结果集）。然后修改 `sql/01..03/05..07` 的
`-1 AS target_upid`。默认 `-1` 安全返回空结果，不等于 0 CPU。

频率问题先跑 `sql/04a-frequency-inventory.sql`：无 `cpufreq` 轨道/无样本会直接给出 `UNKNOWN` 判定，
`sql/04-cpu-frequency.sql` 此时返回空行，**不得**当成 0 MHz。

`sql/08` 提供每核近似 busy 比例；`sql/05` 是每线程 CPU 时间桶，`sql/06` 是整个进程的 CPU spike episode。它们继承自已在 X5 Trace 上验证的 Memory Skill v1.0.2 算法，并继续使用区间交集计算。

## 能力状态

| 能力 | v0.1.0 状态 |
|---|---|
| 配置生成/资源和静态预检 | 本地测试 |
| Linux 普通 tracebox 会话脚本 | 从已验证的 Memory Skill 复制，当前 CPU 包未重新上板 |
| CPU 时间分桶/spike | 从已验证的 Memory Skill 复用，并在本地 SQLite 夹具回归 |
| `thread_state` / Runnable SQL | 合成数据测试；需真实 Trace Processor 验证 |
| CPU 频率 / `linux.perf` | 官方字段参考 + 本地检查；需目标平台验证 |
| Perfetto UI | 操作配方，未自动化检查 |
| Android 完整测试 | 未执行 |

## 版本约束

此包不是正式发布版，不替换 `perfetto-memory-debugging v1.0.2`。如果实际 X5 数据与文档不符，应记录最小复现和证据，做下一候选版修正，不要把静态检查结果写成板端 PASS。
