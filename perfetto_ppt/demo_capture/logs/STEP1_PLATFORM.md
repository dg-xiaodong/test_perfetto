# 第一步：平台与目标只读检查（实测记录）

执行时间：2026-10-21；连接：`ssh root@192.168.1.10`（sshpass；主机 `192.168.1.100`）。

## 1. 平台事实

| 检查 | 命令 | 结果 |
|---|---|---|
| 内核/架构 | `uname -a` | `Linux buildroot 6.1.83-DR-PL5.1_V1.1.1 #3 SMP PREEMPT aarch64` |
| 镜像版本 | `cat /etc/version` | `LNX6.1.83_PL5.1_V1.1.1_20261016-1017` |
| CPU | `nproc` / `getconf _NPROCESSORS_ONLN` | 8 |
| tracefs | `mount \| grep trace`；`ls /sys/kernel/tracing` | **不存在**；`mount -t tracefs tracefs /sys/kernel/tracing` 失败（No such file or directory） |
| tracepoint 符号 | `grep -c __tracepoint_sched_switch /proc/kallsyms` | **0** |
| 内核配置 | `/proc/config.gz` | 不可用（未导出）；由 tracefs 缺失 + kallsyms 无 tracepoint 判定 `CONFIG_FTRACE` 未开 |
| perf 权限 | `cat /proc/sys/kernel/perf_event_paranoid` | 2（root 可用） |
| perf 实测 | `perf stat -e cpu-clock -p <app> -- sleep 1` | 503.20 msec cpu-clock，成功 |
| perf 实测2 | `perf record -F 99 -g -p <app> -- sleep 2` | 193 samples，1.251 MB，成功 |
| perf 内存上限 | `cat /proc/sys/kernel/perf_event_mlock_kb` | 516 |
| cpufreq | `/sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq` | 8 核均 1,200,000 kHz（空闲时）；trace 内 300–1500 MHz |
| 可写目录 | `df -h /userdata` | 28 G ext4 rw，可用 26 G |
| 内存 | `/proc/meminfo` | MemAvailable ≈ 1.08 GB |

## 2. Perfetto 环境

| 项 | 值 |
|---|---|
| tracebox / traced / traced_probes / perfetto | 全部 `Perfetto v58.2-add693d8b` |
| 位置 | `/userdata/perfetto-training-demo/bin/perfetto/`（自启动副本）；另有 `/userdata/bin/` 旧副本 |
| 常驻 traced | `traced --background`（boot 时由 demo 自启动），持有 `/tmp/perfetto-{producer,consumer}` |
| 常驻 traced_probes | 已注册 `linux.ftrace`（但无 tracefs，实际不可用）、`linux.process_stats`、`linux.sys_stats`、`linux.sysfs_power`… |
| **未注册** | `linux.perf`、`android.heapprofd` |
| SDK producer | `pf-demo-x5` 注册 `track_event`，categories：pipeline,memory,sync,io,demo |
| 主机 TP | v57.1-c59f57dd4（`/root/.cache/perfetto-skill/trace_processor_shell`） |

## 3. 目标进程（采集时刻）

```
cmdline : /userdata/perfetto-training-demo/bin/pf-demo-x5 --data-dir /userdata/perfetto-training-demo
comm    : pf-demo-x5      pid: 1090      threads: 14
tids    : 1090 main, 1099 TracingMuxer(NULL comm at first scan), 1100 pf-capture, 1101 pf-preproc,
          1102 pf-infer, 1103 pf-postproc, 1104 pf-output, 1105 pf-contend1, 1106 pf-contend2,
          1107 pf-syncwait, 1108 pf-memheap, 1109 pf-ioworker, 1110 pf-monitor, 1111 pf-schedprobe
affinity: Cpus_allowed_list 0-7（进程级未绑定；线程级需要 sched 数据才能验证，本板无）
RSS     : 5,000–17,840 kB（随 MEMORY_PULSE 周期变化）
environ : 无 LD_PRELOAD（→ heapprofd 不可用）
SDK     : fd 指向 /memfd:perfetto_shmem，说明 producer 已连上系统 traced
```

## 4. tracing 冲突与已发生的事故

1. 常驻 `traced` 独占 `/tmp/perfetto-{producer,consumer}`，`perfetto` CLI 默认连接该 socket（可用）。
2. `tracebox` 不带 `--system-sockets` 时用抽象 socket `@traced-c-<pid>`，**看不到应用 track_event**；
   带 `--system-sockets` 时会去绑定系统路径，实测**替换了常驻 traced 的 socket 路径**，
   之后 `perfetto --query` 报 "Could not connect to /tmp/perfetto-consumer"。
3. 该操作后约 10 s 板卡重启一次（`hbootboot.reason=REBOOT_CMD`，dmesg 无 watchdog/panic）。
   重启原因无法 100% 归因于该操作，但时间重合，后续**不再使用 `--system-sockets`**。
4. 采集期间板卡又发生两次无预警重启（00:24、00:31 附近），原因同理无定论；因此所有采集都按
   "短时、立即拉回、记录 sha256"执行，最终数据均在重启窗口外完成（env.txt 有起止 uptime 为证）。
5. 其他 tracing 使用者：`/userdata/bin/traced`（旧副本，已被 demo 的 traced 取代）、
   `/userdata/bin/traced_probes`，以及我们额外启动的 `tracebox traced_perf`（producer）。
   **最终数据采集时只保留 1 个 traced + 1 个 traced_probes + 1 个 traced_perf。**

## 5. 周期确认（用于定采集时长）

`pf-demo-x5.log` 的 `PHASE` 行间隔实测 8.008 s，6 段一轮回 → **周期 48 s**；
两周期 96 s，取 **120 s（2.5 周期）**；trace 实测 119.995 s、含 15 个 PhaseChange（16 段）。
