# cpu_v1_test — RDK X5 CPU 周期性尖峰归因（perfetto-cpu-debugging v0.1.0 首次上板）

用 `perfetto-cpu-debugging` skill 在 RDK X5 上做的一次受控 CPU 性能诊断：自建 C++ 多线程负载，
采一份 **scheduling 路由**的真实 trace，回答「哪个线程尖峰 / 何时多久多大 / 为什么」。

完整分析与四级验收见 [`REPORT.md`](REPORT.md)；原始 SQL 输出见 [`sql_out/`](sql_out/)。

## 一眼结论

| 问题 | 结论 |
|---|---|
| 哪个线程 | `spike-worker`（pid 12042 / tid 12044 / utid 206） |
| 形态 | 每 **3000.0 ms** 一次，每次连续 **300.2 ms**，满占 **1 个逻辑核（CPU1，100%）** |
| 次数/量 | 19.683 s 窗口内 7 次；累计 2101.4 ms = 单核 10.7% / 8 核 1.3% |
| 原因 | 线程自身连续 on-CPU 计算；Runnable 等待仅 76–84 µs ⇒ 不是调度延迟/饥饿/锁争用 |
| 函数级热点、频率 | **UNKNOWN**（本轮按最小证据原则未采 `linux.perf` / `power/cpu_frequency`） |

## 快速打开

把 [`cpu.pftrace`](cpu.pftrace) 拖进 <https://ui.perfetto.dev/>：

- 搜 `spike-worker` → 线程轨道：7 个 `Running` 绿块，间隔 3 s，各 300 ms
- 搜 `CPU 1` → 同一时刻的琥珀色粗柱（一次尖峰被切成 191.86 ms + 108.32 ms 两段）
- 搜 `bg-light` / `CPU 7` → 每 100 ms 约 3 ms 的对照负载，恒为 ~3% 单核，不尖峰

## 目录

| 路径 | 内容 |
|---|---|
| `cpu.pftrace` | 真实 trace，102,853 B，sha256 见 `sql_out/trace_sha256.txt` |
| `REPORT.md` | 完整报告：环境、命令、四级验收、证据表、结论、局限 |
| `sql/` | 本轮分析 SQL（注明与 skill 原 SQL 的适配点） |
| `sql_out/` | 每条 SQL 的原始输出（00 清点 … 09 质量门） |
| `config/` | `cpu.pbtxt`（scheduling 路由，20 s）与板端 `available_events` 实测清单 |
| `logs/` | `cpu.status`(DONE) / tracebox 日志 / 负载自报 tick 时间戳 / 板卡环境 / 采集方法 |
| `cpu_spike_fixture.cpp` | 测试程序源码（`aarch64-none-linux-gnu-g++ 11.3 -static`） |

## 复现

```sh
# 板端（只读探测）
sh survey.sh ; sh survey.sh --events > board_events.txt

# 主机
python3 scripts/make_config.py scheduling --events board_events.txt --duration-ms 20000 > config/cpu.pbtxt
python3 scripts/validate_config.py config/cpu.pbtxt

# 板端：负载 30 s，采集 20 s（先起负载，1 s 后开始采）
./cpu_spike_fixture 30000 3000 300 > fixture.log 2>&1 &
sleep 1
WORK=$PWD TRACEBOX=$PWD/tracebox-arm64 sh linux_trace_session.sh config/cpu.pbtxt cpu 30

# 主机
trace_processor_shell query -f sql/04-spike-episodes.sql cpu.pftrace
```

## 环境

- 板卡：`buildroot 6.1.83-DR-PL5.1_V1.0.20`，aarch64，8 核（详见 `logs/board_environment.txt`）
- 采集端：tracebox **v57.1**（aarch64 官方构建）；分析端：Trace Processor **v57.1**（同版本）
- 采集期间未改 sysctl/governor/mount，未重启或干扰业务进程；板端残留目录 `/userdata/cpu-diag-1018-013326/`

## 附：本轮暴露的 skill 问题

`REPORT.md` §8 有完整说明，摘要：

1. skill 的 `<skill>/sql/00-inventory.sql` 多 SELECT，`tp query -f` 在 v57.1 只输出最后一个结果集 / 报错，需拆条；
2. 该 TP 构建没有 `sched_waking` 表，唤醒关系只能读 `thread_state` 的 R 区间 + `waker_utid`；
3. `make_config.py frequency` 与 `overview` 默认输出逐字节相同；
4. `scheduling` 路由下 `cpu_counter_track` 恒为空，频率结论应直接标 UNKNOWN。
