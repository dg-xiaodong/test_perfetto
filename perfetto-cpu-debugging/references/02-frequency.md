# CPU Frequency / Idle

官方依据：<https://perfetto.dev/docs/data-sources/cpu-freq>。

## 采集路线（v0.1.0-r1）

- `scripts/make_config.py frequency`：**轻量**路线，默认只做 `linux.sys_stats` 的 cpufreq 轮询 + 可用的
  `power/cpu_frequency` / `power/cpu_idle`；**默认不含 sched**（不采 `sched_switch`）。需要把频率和
  具体线程/CPU 时间对齐时，显式加 `--with-sched`。
- `scripts/make_config.py overview`：综合路线，sched + power + 轮询一起采，用于还不知道问题类型时定位。
- 板端事件能力必须先用 `sh scripts/survey.sh --events` 核实：缺 `power/*` 时 generator 会自动退化为
  **纯轮询**配置（会打印 NOTE），不假设 X5 一定有全部 power 事件。

## 选择

- `power/cpu_frequency`：**频率变化时**才产生 event，因此短 trace 缺样本很正常。
- `linux.sys_stats` 的 `cpufreq_period_ms`：周期性读取 sysfs（不同版本/平台具体文件可能有差异），帮助取得起始频率；采样周期须 >10 ms；有时目标内核/驱动没暴露完整接口，需核查。
- `power/cpu_idle`：可选；`cpu_counter_track` 中 `cpuidle` 状态的值 `4294967295` 表示返回非 idle（不要当深度 4e9）。
- 不同核的频率可能在同一 cluster 内联动，不能独立解释每个 CPU 的频率变化。

## 验证和分析

## 数据验收（先做这一步）

1. 先跑 `sql/04a-frequency-inventory.sql`（单条 SQL）。它输出 `freq_tracks/freq_cpus/freq_units/freq_samples`
   和 `verdict`：
   - `UNKNOWN: no cpufreq counter track`：该 trace 没采频率（scheduling 路由属正常情况）→ 频率 **UNKNOWN**，
     **不得**解释为 0 MHz；
   - `UNKNOWN: ... no samples`：有轨道无样本，同样 UNKNOWN；
   - `WEAK: single sample`：只有初始值，无趋势；
   - `OK`：有样本，且必须再确认样本落在分析窗口内、覆盖足够时间。
2. 只有 `OK/WEAK` 才继续跑 `sql/04-cpu-frequency.sql` 出时间线；空结果 = 未采集，不是 0 MHz。

## 单位

- `cpufreq` 原始 counter 值是 **kHz**（`power/cpu_frequency` 与 sysfs `scaling_cur_freq` 同单位）；
  `sql/04-cpu-frequency.sql` 用 `value/1000.0` 输出 MHz，并保留 `raw_unit`/`raw_value` 便于核对。
- `cpuidle` 的值是**状态深度**，`4294967295` 表示离开 idle，不能当深度或频率。

频率下降不等于热限制或性能瓶颈；必须结合 Running/idle、实际任务延迟，必要时平台温度、功率/thermal 限制事实。避免简单“频率低 → 用户卡顿”的因果断言。
