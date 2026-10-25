# SKILL_GAPS.md — `perfetto-cpu-debugging` v0.1.0-candidate 实盘缺口（第 2 轮，共享板环境）

- Skill 版本哈希：树 A `85e518409ee47f20ad012b1a1d0b05558fdd19dd2a6b56deeedaaf55c7ae073c`；树 B `eb062c4969f7c2a8e3b5ffd195ff92badb64dfb75e89177289500f97f439739b`；MANIFEST 自校验 0 mismatch
- 本轮场景：X5 / kernel 6.1.83 / 8 核同构 / root；**板上同时运行另外两个 benchmark 用例**（`pf-lat-case`、`pf-sched-case`）；被测进程已被环境重启（pid 1762 → 8143）
- 严重度：**blocker** 卡死流程；**high** 会误导结论；**medium** 需手工绕行；**low** 体验

---

## 本轮新增缺口

### GAP-12（high）周期性线程的 perf 样本数会被"相位锁定"放大 7.8 倍，文档没有判据

**实测**：

| 线程 | on-CPU | perf 样本 | 样本/CPU-s | 备注 |
|---|---|---|---|---|
| `pf-worker-p` | 2126.3 ms | 217 | 102.1 | 符合 100 Hz/CPU |
| `pf-worker-q` | 1327.9 ms | 132 | 99.4 | 符合 |
| **`pf-svc-tick`** | **559.1 ms** | **435** | **778.0** | **异常** |

两条硬判据证明这 435 个样本不是 CPU 时间：
1. 435 个样本中 **427 个**落在该线程自己的 Running 区间内，且相邻样本间隔**严格 = 50 ms**（该线程的唤醒周期）；
2. 按 100 Hz/CPU 时基，559.1 ms 应得 ~56 个样本，实测 7.8 倍。

**更糟的是排名不稳定**：同一份 TraceConfig 在另一个实例上给该线程 **0 个样本**（当时第一名是 `p_kernel_hot`）。也就是说"叶帧第一名"可以整体翻转，而 `sql/07-perf-samples.sql` 的 `ORDER BY samples DESC` 会把它直接摆在报告最显眼的位置。

**为什么是 high**：Skill §3 与 `03-profiling.md` 只说"采样是概率的、样本数不是精确执行次数"，但没有给"**如何判定某线程的样本数不可用于 CPU 时间**"的可执行判据。按 Skill 现有口径写报告，很容易把 `svc_compute_until` 写成"最热函数"。

**建议补丁**：
1. `03-profiling.md` 增加第 0 步判据（放在符号化之前）：
   ```sql
   SELECT th.name, COUNT(*) samples, SUM(sl.dur)/1e6 cpu_ms,
          COUNT(*)/(SUM(sl.dur)/1e6/1000.0) samples_per_cpu_s
   FROM perf_sample ps JOIN thread th USING(utid)
   LEFT JOIN sched_slice sl ON sl.utid=th.utid AND sl.dur>0
   GROUP BY th.utid ORDER BY samples DESC;
   ```
   `samples_per_cpu_s` 显著偏离 `frequency` 的线程（本次 778 vs 100）→ 标记"样本数不可当 CPU 时间"。
2. `07-perf-samples.sql` 增列 `samples_per_cpu_s`，并在注释里写明"周期性线程可能相位锁定"。
3. 加一条"样本间隔自检"：若某线程样本间隔等于其周期，几乎必然是该伪影。

---

### GAP-13（high）共享板上"CPU 占比大 ≠ 延迟贡献大"，Skill 缺少"逐段归属"这一查询范式

**实测**：板上三个用例同时在跑，CPU 占比排序是
`pf-lat-case 32.1%` > `pf-sched-case 27.1%` > **`pf-cpu-case` 16.8%（被测）**；
但心跳延迟的逐段归属是
**`pf-worker-p` 94.5%（227.018 ms）** ≫ 空闲 5.4% ≫ **外来负载合计 0.06%（0.144 ms）**。

**为什么是 high**：Skill 反复强调"CPU 高不等于卡顿根因"，但给的方法都停在"看谁 CPU 高 + 看 Runnable"。在**多负载共享板**上，真正决定心跳延迟的是"**在心跳线程等待的那几毫秒里，究竟是谁占着那个核**"，这需要把 `thread_state(R)` 与 `sched_slice` 按 **cpu + 时间区间**做关联，Skill 现有的 01/02/03/05/06/08 没有任何一条做这件事。缺了这一条，分析者只能靠"时间窗吻合"猜，正好落进 Skill 自己警告的陷阱。

**建议补丁**：新增 `sql/09-who-held-the-core.sql`（本次已自造并验证，闭口误差 2 µs）：

```sql
-- 对目标线程的每段 Runnable 等待，统计同核上各进程/线程实际持有的时长
WITH tgt AS (SELECT utid, <CPU> AS cpu FROM thread WHERE tid=<TID>),
     r AS (SELECT st.ts, st.dur FROM thread_state st JOIN tgt USING(utid)
           WHERE st.state IN ('R','R+') AND st.dur>0)
SELECT p.name proc, th.name thr, COUNT(DISTINCT r.ts) waits,
       ROUND(SUM(MIN(s.ts+s.dur,r.ts+r.dur)-MAX(s.ts,r.ts))/1e6,3) held_ms
FROM r JOIN sched_slice s ON s.cpu=(SELECT cpu FROM tgt)
      AND s.ts < r.ts+r.dur AND s.ts+s.dur > r.ts
JOIN thread th USING(utid) JOIN process p USING(upid)
GROUP BY p.name, th.name ORDER BY held_ms DESC;
```
验收口径：`SUM(held_ms)` 应≈目标线程该窗口的 `thread_state(R)` 总时长（本次 240.170 vs 240.168 ms）。

---

### GAP-14（medium）被测进程可能被环境重启，Skill 没有"实例一致性"前置检查

**实测**：两次会话之间 `pf-cpu-case` 从 pid 1762 变成 8143，`heartbeat_latency.csv` 被重建，main 线程绑核从 cpu3 变成 cpu6。旧 `.pftrace` 因此**无法**与当前公共时延对齐。

Skill §4 说"已有 `.pftrace` 时优先分析，不重复上板"——这条在实例漂移时是**错的**，会让人拿旧 trace 配新 CSV。

**建议补丁**：`04-platforms.md` 增加前置检查三件套：
```sh
pgrep -x <proc>; ps -o pid,etime,lstart -p $(pgrep -x <proc>)   # 实例存活与启动时刻
stat -c '%y %s' <public_latency_csv>                            # 公共记录是否被重建
for t in /proc/<pid>/task/*; do ... Cpus_allowed_list ...; done # 亲和性是否变了
```
并与 `trace_bounds` 的绝对时间比对，确认 trace 覆盖当前实例。

---

### GAP-15（medium）没有"枚举板上外来负载"的检查清单

`04-platforms.md` 只提醒"不要改变其他 tracing 会话/生产业务"，但**没有**要求"先枚举、记录并保留在报告中"。本轮正是靠枚举才发现板上还有两个 benchmark 在跑（其中一个的线程就在被测 main 线程的核上），并直接决定了报告必须做逐段归属而不是按 CPU 占比归因。

**建议补丁**：`scripts/survey.sh` 增加一段只读的"邻居进程"报告：
```sh
ps -eo pid,ppid,pcpu,comm,args | sort -k3 -nr | head -20
for p in $(ls /proc | grep -E '^[0-9]+$'); do c=$(tr '\0' ' ' </proc/$p/cmdline); case "$c" in *perfetto*|*tracebox*|*traced*) echo "$p $c";; esac; done
```
并把 `loadavg` 与采集窗口一起写进报告的"环境"节。

---

### GAP-16（low）`make_config.py` 缺少"事件量 → buffer 估算"的指引

本轮系统负载从 0.04 升到 1.1、采集时长 20 s → 24 s，trace 体积从 1.61 MB 涨到 2.31 MB。Skill 只给 `--ftrace-kb` 的范围（128–16384），没有说怎么根据 CPU 数 × 事件率 × 时长估。建议在 `04-platforms.md` 给一条经验公式与"先 2048、看 `traced_buf_data_loss_*` 再调"的建议。

---

## 上一轮遗留（仍然成立，未修复）

| # | 严重度 | 缺口 |
|---|---|---|
| GAP-1 | high | **collector 自身会落到被测核**，造成 10–20 ms 同量级干扰；Skill 全文零提示。上一轮实测 3/5 个 ≥10 ms 尖峰由 tracebox 造成。本轮已用 `taskset` 规避（cpu1/2 占用 0 ms）。**建议**：`05-quality.md` 增"Observer placement"一项 + `09-observer-overhead.sql` |
| GAP-2 | **blocker** | `trace_processor_shell query -f sql/00-inventory.sql` **照抄必报错**（多语句多结果集：`Result rows were returned for multiples queries`）。Skill §2 与 `04-platforms.md` 写的正是这条命令。**建议**：拆文件或提供逐语句执行脚本 |
| GAP-3 | high | `scope.target_cmdline` **未生效**：本轮 19192 个样本中 16873 属 `pid 0`，另有 922 属 `pf-lat-case`、510 属 `pf-sched-case`。`03-profiling.md` 却写"scope 按进程名筛选"。**建议**：加硬性验收 `SELECT p.name,COUNT(*) FROM perf_sample ... GROUP BY upid` |
| GAP-4 | high | 栈深度只有 **1**（28 callsite，仅叶帧，无内核帧即便 `kernel_frames: true`）。`06-ui.md` 却让用户去开 Flamegraph 看调用链 |
| GAP-5 | medium | `host_pull.sh` 缺 legacy `scp -O`，本板必失败（多文件 scp 也须逐个传） |
| GAP-6 | medium | `make_config.py` 无 freq+perf 组合路线，只能手工追加 `linux.perf` 段 |
| GAP-7 | medium | `linux_trace_session.sh` 里 `"$TRACEBOX"` 整体引用，无法传 `taskset ...` 多词命令（本轮再写一个壳脚本绕开） |
| GAP-8 | medium | tracebox 获取/版本对齐无闭环（`04-platforms.md` 只说"非随包附赠"） |
| GAP-9 | low | `05/06/02/03/07/08` 参数全靠人肉 `sed` |
| GAP-10 | low | `configs/cpu-overview.pbtxt` 与 `cpu-frequency.pbtxt` 字节相同 |
| GAP-11 | low | `00-inventory.sql` 的 `cpu_counter_track` 汇总粒度太粗（分不清 perf 时基与 cpufreq） |

---

## 被本轮实测**证实**的 Skill 断言（建议补进 TEST_REPORT）

| Skill 断言 | 本轮实测 |
|---|---|
| "X5 `perf_event_paranoid=2` 不等于 `linux.perf` 已可采样；必须实际检查 producer/结果" | paranoid=2 + root + tracebox 含 `traced_perf`（有 `stack-unwinding` 线程）→ 可采样，19192 样本；`perf_samples_skipped=0` |
| "性能采样必须检查符号" | mapping build_id `5216590986a25ab51f5c924c25db8dee675320b7` 与 RUN_INFO 一致，3 个叶帧成功反解 |
| "Runnable 不等于业务延迟" | 本轮恰好相反地证明了它的**可对齐性**：tick 的 R 段与心跳 1:1 对齐（14.064+1.059=15.124 ms），因为心跳本身就是该线程的周期性唤醒 |
| "频率与慢同窗不直接构成因果" | 本轮 1175 MHz 的秒是最快（1.087 ms），450 MHz 的秒平稳（1.220 ms）→ 无单调关系 |
| "CPU 时间桶必须做区间交集" | `05` 在 p-burst 边界正确切出 100.9 / 200.0 ms 两段，未把整段计入起始桶 |
| "采样热点不能当 CPU 毫秒" | 本轮给出极端反例：tick 778 样本/CPU-s（标称 100），样本间隔 = 线程周期 50 ms |
| "不要用系统级 summary tree 冒充目标进程热点" | 本轮 16873/19192 个样本属 `pid 0`，另有外来进程样本；必须按 utid 归属 |

---

## 汇总（按优先级）

| # | 严重度 | 一句话 |
|---|---|---|
| GAP-2 | **blocker** | `query -f 00-inventory.sql` 直接报错，而文档给的就是这条命令（遗留） |
| GAP-12 | high | 周期性线程样本数被相位锁定放大 7.8×，叶帧排名会整体翻转，无判据（新） |
| GAP-13 | high | 共享板上"CPU 占比大 ≠ 延迟贡献大"，缺"逐段归属"SQL（新） |
| GAP-1 | high | collector 自干扰落到被测核，无提示（遗留） |
| GAP-3 | high | `scope.target_cmdline` 未生效，97.6%→87.9% 样本不属目标（遗留） |
| GAP-4 | high | 栈深度 1，Flamegraph 调用链不可用（遗留） |
| GAP-14 | medium | 实例漂移无前置检查，旧 trace 会被误配新 CSV（新） |
| GAP-15 | medium | 无"枚举外来负载"清单（新） |
| GAP-5/6/7/8 | medium | `scp -O` / 无组合路线 / TRACEBOX 不能传参 / tracebox 获取无闭环（遗留） |
| GAP-16 | low | 缺 buffer 估算指引（新） |
| GAP-9/10/11 | low | SQL 参数靠 sed / overview 模板重复 / inventory 粒度粗（遗留） |
