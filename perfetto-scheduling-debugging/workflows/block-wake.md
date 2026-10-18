# Block/Wake：一次等待的两端

来源 S1/S2/S3；这是核心路线，但不是默认全开。

## 采集

先有 overview 或现有 trace 的目标线程和未决问题。只读确认 Linux TID、TGID、生命周期、相关线程和两个事件 format。
生成器的 block-wake 生成两路 linux.perf：
- `sched_switch`：仅 `prev_pid == TID`（重复 TID 为 OR）。没有默认 next_pid 过滤。
- `sched_waking`：事件参数 `pid == TID`，抓执行唤醒操作的上下文。

两路都有 `period: 1`、明确 timebase 名与 PERF_CLOCK_MONOTONIC；Perfetto 将数据归一到 trace 时钟，仍需核对 ClockSnapshot/业务对时。`period=1` 不等于无丢失。
默认不设进程 scope：事件过滤已限定目标切出/相关唤醒，不能为减少栈而丢掉跨进程唤醒者。最多 8 个明确 TID；禁止全系统逐调度抓栈。仍可能有中断上下文、无法展开的线程或权限失败。

## 样本来源映射

1. 跑 `08-perf-streams.sql`，记录样本、带栈、unwind_error 数量。
2. `00c`/sqlite_master 看版本的 track 表；可用时 `08a-perf-tracks.sql` 核对名字 `scheduling.switch` / `scheduling.waking` 与 perf_session_id。也可用原始 PerfSampleDefaults 与该版本解析规则交叉核对。
3. **session ID 不是配置顺序**。若 table 没有提供来源且不能可靠恢复，标记 SOURCE_UNKNOWN，不设置 `streams_verified=1`。
4. 记录 trace SHA256、两条实际 session ID、来源核对方法、时钟依据、数据缺失情况。不混入其他 trace 的 ID。

## 查询

选 `02` 给出的真实 wait_id：

```sh
python3 scripts/render_sql.py sql/05-event-pair.sql \
  --utid 17 --wait-id 42 --switch-session 2 --waking-session 3 \
  --clock-verified 1 --streams-verified 1 > event-pair.sql
```

上述数字是示例；两个 proof 开关只能在完成实际核对后启用。默认 tolerance=0；不同事件传递路径确有时间偏差时，先验证偏差分布及唯一性，再显式传 `--tolerance-ns`，不得为凑匹配随意放宽。

SQL 检查：目标身份、状态连续边界、切出时 CPU、事件来源、采样执行者、唤醒事件参数、同一事件 CPU、单一候选、邻近其他可混淆事件、IRQ 上下文、栈缺失/展开错误。切出 CPU 与唤醒 CPU 可以不同。

- MATCH_UNIQUE：这些约束下唯一候选，仍不是 E3 根因。
- CONTEXT_UNKNOWN / IRQ_CONTEXT：可能有样本，但不认定用户态线程就是语义上的唤醒者/锁所有者。
- WAKE_EVENT_MISSING：状态可以存在 waker 信息，但完整双端事件证据不足。
- SAMPLE_AMBIGUOUS：不能取 MIN(id) 或最近样本当答案。

对实际选定的 callsite_id 用 `06-callstack.sql` 看叶帧到祖先，保留 mapping/Build ID/未解析帧。不要汇总整份 trace 后再拿某个等待函数解释这次等待。缺栈不降级成“没有阻塞”。

完整对应规则见 `references/correlation.md`。E2 不能自动推出锁所有权或业务条件成立。
