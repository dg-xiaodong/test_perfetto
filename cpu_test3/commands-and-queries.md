# task-service / Perfetto CPU 诊断 —— 实际命令、SQL 与判读口径

> 本文件是首轮诊断的**可复核记录**：板端/主机的实际命令、所用 SQL、以及每条结论的判读口径。
> 完整会话工具调用记录在同一次 DSH 会话日志中；本文件把其中会影响结果的部分固化成可重放文本。
> 所有操作均为只读或**新增文件**，未改服务、未改 sysctl/governor、未改 Skill。

## A. 只读探测（板上）

```bash
sshpass -p root ssh -o StrictHostKeyChecking=no root@192.168.1.10 '...'
```

1. 服务状态
```bash
/userdata/cpu-lab/task-servicectl status
cat /userdata/cpu-lab/run/task-service.pid
ps -o pid,ppid,stat,pcpu,time,comm,args -p 10285
nproc; cat /proc/loadavg; uptime; head -3 /proc/meminfo
```

2. 线程与亲和性
```bash
for t in /proc/10285/task/*; do
  printf "tid=%s comm=%s stat=%s aff=%s\n" "$(basename $t)" "$(cat $t/comm)" \
    "$(awk '{print $3}' $t/stat)" "$(grep Cpus_allowed_list $t/status | cut -f2)";
done
```

3. 事件能力与平台调查（Skill 自带、只读）
```bash
# survey.sh 由主机 scp 到 /userdata/cpu-lab/survey.sh 后执行
sh survey.sh --events > /tmp/avail_events.txt      # 1170 行，导出到主机 available_events.txt
sh survey.sh                                        # 平台/tracefs/cpufreq/perf 参数/挂载空间
grep -E '^(sched|power)/' /tmp/avail_events.txt
command -v tracebox perfetto perf
perf stat -e cpu-clock -a -- sleep 0.2             # 只读验证 perf_event_open（root 可用）
ls -d /sys/devices/system/cpu/cpufreq/policy*
cat /sys/devices/system/cpu/cpufreq/policy0/{affected_cpus,scaling_governor,scaling_cur_freq,scaling_min_freq,scaling_max_freq,scaling_available_frequencies}
for t in /sys/class/thermal/thermal_zone*; do echo "$t $(cat $t/type) $(cat $t/temp)"; done
```

4. 业务日志（允许使用）
```bash
tail -40 /userdata/cpu-lab/logs/service.log
tail -5   /userdata/cpu-lab/logs/requests.jsonl
wc -l     /userdata/cpu-lab/logs/requests.jsonl   # 采集前 4589
```

## B. 配置生成与校验（主机）

```bash
cd /root/.dsh/skills/perfetto-cpu-debugging
OUT=/root/code_1.0.20/tmp/cpu-task-service-diag
EV=$OUT/available_events.txt
python3 scripts/make_config.py overview    --events $EV --duration-ms 55000 > $OUT/cfg-overview.pbtxt
python3 scripts/make_config.py scheduling  --events $EV --duration-ms 55000 > $OUT/cfg-scheduling.pbtxt
python3 scripts/make_config.py frequency   --events $EV --duration-ms 55000 > $OUT/cfg-frequency.pbtxt
python3 scripts/make_config.py profiling   --events $EV --target task-service --frequency-hz 100 \
                                            --duration-ms 55000 > $OUT/cfg-profiling.pbtxt
# 实际下发的合并配置是手工编写：$OUT/cpu-combined.pbtxt（理由写在其注释里）
for f in cfg-overview cfg-scheduling cfg-frequency cfg-profiling cpu-combined; do
  python3 scripts/validate_config.py $OUT/$f.pbtxt
done
python3 scripts/validate_config.py --check-resources
python3 scripts/validate_config.py $OUT/cpu-combined.pbtxt \
  --descriptor-set /root/code_1.0.20/trace_config_v58.2.desc   # 版本不匹配，仅参考
```

## C. 采集（板上，55 s）

```bash
R=/userdata/cpu-lab/perfetto-session
ssh root@192.168.1.10 "mkdir -p $R && cp /userdata/cpu-diag-1018-013326/tracebox-arm64 $R/tracebox && chmod +x $R/tracebox"
scp cpu-combined.pbtxt linux_session_lib.sh linux_trace_session.sh root@192.168.1.10:$R/
ssh root@192.168.1.10 "echo UPTIME_BEFORE=\$(cut -d' ' -f1 /proc/uptime); wc -l < /userdata/cpu-lab/logs/requests.jsonl"
ssh root@192.168.1.10 "WORK='$R' TRACEBOX='$R/tracebox' sh '$R/linux_trace_session.sh' '$R/cpu-combined.pbtxt' cpu 90; \
   echo UPTIME_AFTER=\$(cut -d' ' -f1 /proc/uptime); wc -l < /userdata/cpu-lab/logs/requests.jsonl"
# 预期输出：tracebox_pid=10744 / DONE size_bytes=7024848 / CAPTURE_RC=0
```

拉回（`host_pull.sh` 内部 scp 不支持密码认证，用等价显式校验替代）：

```bash
for f in cpu.pftrace cpu.log cpu.status cpu.pid; do
  sshpass -p root scp -q root@192.168.1.10:$R/$f ./$f || exit 1
  [ -s ./$f ] || exit 1
  echo "PULL OK: $f size=$(wc -c < ./$f) sha256=$(sha256sum ./$f | cut -d' ' -f1)"
done
```

## D. 分析（主机，Trace Processor v57.1）

`trace_processor_shell query` **一次只接受一条 SELECT**（多条会报 "Result rows were returned for multiples queries"），因此 `sql/00-inventory.sql` 逐条拆开执行；其余 SQL 单语句。

```bash
TP=/root/.cache/perfetto-skill/trace_processor_shell
$TP query -f sql-run/01-cpu-usage.sql   cpu.pftrace
$TP query -f sql-run/02-thread-states.sql cpu.pftrace
$TP query -f sql-run/03-runnable-latency.sql cpu.pftrace
$TP query -f sql-run/04-cpu-frequency.sql cpu.pftrace     # 全量原始点，量大
$TP query -f sql-run/05-cpu-time-buckets.sql cpu.pftrace
$TP query -f sql-run/06-cpu-spike-episodes.sql cpu.pftrace
$TP query -f sql-run/07-perf-samples.sql cpu.pftrace
$TP query -f sql-run/08-core-busy.sql cpu.pftrace
sh export_data.sh          # 导出 q-slices/q-states/q-cpufreq/q-cpuidle/q-pf/q-cs/q-fr 为 CSV
python3 analysis.py         # 复现本报告的分类/窗口/相位/频率数字
```

### D.1 Skill SQL 的改动（仅参数）

`sql-run/*.sql` 相对 Skill 原件的唯一改动：`target_upid` 由占位 `-1` 改为实测 **3**（`00-inventory` 得到）。其余窗口/桶宽/阈值保持默认（桶 100 ms；spike 阈值 100 ms/1 s）。

### D.2 追加的针对性查询（`q-*.sql`，全部只读）

| 文件 | 用途 | 关键判读 |
|---|---|---|
| `q-slices.sql` | UPID 3 全部 `sched_slice` + `end_state` | 每线程在哪个核、每片多长 |
| `q-states.sql` | UPID 3 全部 `thread_state` | Running / R / S 分开；**无 D** |
| `q-cpufreq.sql` / `q-cpuidle.sql` | `cpu_counter_track` 的 cpufreq/cpuidle 原始点 | kHz；4294967295 = 离开 idle |
| `q-pf.sql` / `q-cs.sql` / `q-fr.sql` | perf 样本 + callsite 父子 + frame 名 | 按 UTID 还原调用树 |
| `q-block.sql` / `q-longs.sql` | 长状态区间 | 定位 91.6 ms 的 S 段 |
| `q-waker.sql` / `q-waker2.sql` | `raw`+`args` 解析 `sched_waking` | 谁唤醒了 req-worker |
| `q-raw2.sql` | 91.6 ms 前后的 `sched_waking`/`sched_switch` 明细 | 交叉核对唤醒时刻 |
| `q-mig.sql` / `q-migtime.sql` / `q-mig-win.sql` | `sched_migrate_task` 计数与 orig/dest CPU | 跨核频率与方向 |
| `q-cpu67.sql` / `q-busy6.sql` | CPU6/7 按线程占用、逐秒占用 | 单核饱和 vs 空闲 |
| `q-freq-bucket.sql` / `q-idle-bucket.sql` | 逐秒频率层/Idle 计数 | 频率不是降频 |
| `q-overhead.sql` / `q-overhead2.sql` / `q-stats.sql` | 采集器自身开销、`stats` 行数 | 观测开销披露、无丢数 |

### D.3 判读口径（避免常见误读）

- CPU 时间来自 `sched_slice` 区间，**不是** `ps %CPU`、也不是墙钟；多核下可超过墙钟。
- `R`/`R+` 是 **Runnable 等待**，不等于运行；`S`/`D` 是等待/阻塞。本次 92.8 ms 的慢请求是 **S**，不能记成"调度不及时"。
- 判断"等谁"必须看**同核同窗口**的切片（本报告 §5.5 的逐片列表），不能只用 Runnable 时长下结论。
- 桶统计必须与切片求交（Skill SQL 已做交集裁剪）；95 ms 级事件跨桶时不能整段计入起始桶。
- `power/cpu_frequency` 只在**变化**时产生事件；空档≠0 Hz；初始值靠 `cpufreq_period_ms` 轮询。
- 频率低≠瓶颈：本次饱和窗口频率是 **1500 MHz**；阻塞窗口频率 300 MHz 是因为**空闲**。
- `linux.perf` 是**概率采样**：600 个样本≈6.0 s CPU，与 sched 口径 6.56 s 吻合，但样本数不是函数调用次数。
- 业务延迟必须有业务日志/时间窗：本报告用 `requests.jsonl` 的 `st/en` 与 trace 切片互证对齐，未用 Runnable 时长直接代替请求延迟。
- 一次 `scp` 失败即视为失败（`host_pull.sh` 的设计），本轮改用显式非空+sha256 校验。

## E. 采集窗口内请求 ↔ 日志对齐

```python
# requests-after.jsonl 中 enq 落在 [trace_bounds.start_ts, end_ts] 内的请求
T0, T1 = 46290515351739, 46345505419807
# 快请求 dur_us≈13.4：req-worker 切片完全覆盖窗口（trace 粒度内）
# 慢请求 dur_us≈92813.8：req-worker 仅 0.11 ms Running，其余为 S → 对齐成立
```

## F. 未执行/不可用的操作（如实记录）

- 未使用 `host_pull.sh` 原样执行（内部 `scp` 无密码认证；已用等价命令）。
- 未使用 `--descriptor-set` 做**同版本** schema 验证（板端 v57.1 的 descriptor 不可得；v58.2 只作参考）。
- 未做 Perfetto UI 操作/截图（无 GUI 自动化条件）→ `UI_UNKNOWN`，只给手动步骤。
- 未读 cpu_test2 仓库 / 测试源码 / GROUND_TRUTH / selfcheck 材料；未反编译被测服务。
- 未修改 `perf_event_paranoid`、`kptr_restrict`、governor、挂载；未停止/重启/改服务。
