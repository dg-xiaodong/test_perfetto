# RUNNING_BRIEF — task-service

（仅运行事实，可交给诊断 Agent。不含设计与机制说明。）

## 服务

| 项 | 值 |
|---|---|
| 服务名 | `task-service` |
| 状态 | **running** |
| PID | `10285`（以 `/userdata/cpu-lab/run/task-service.pid` 为准；重启会变） |
| 线程数 | 9（线程名见 `/proc/<pid>/task/*/comm`） |
| 启动命令 | `/userdata/cpu-lab/bin/task-service --cpu-a 6 --cpu-b 7` |
| 可用 CPU | `6`、`7`（进程级 affinity，不会跑出这两个核） |
| 周期 | 48 s 一个周期，周期内 6 个 8 s 阶段循环；无终止条件（直到收到停止指令） |
| 内存 | RSS ≈ 2.1 MiB（HWM 2.1 MiB） |
| CPU 占用 | 全周期平均 ≈ 0.11 个逻辑核 |

## 路径

| 用途 | 路径 |
|---|---|
| 程序 | `/userdata/cpu-lab/bin/task-service` |
| 符号文件 | `/userdata/cpu-lab/bin/task-service.sym`（`nm -C`）、`/userdata/cpu-lab/bin/task-service.debug`（独立调试信息）；主二进制**未 strip**，自带 `.symtab`/`.debug_*`，保留 frame pointer |
| 业务日志 | `/userdata/cpu-lab/logs/requests.jsonl`（JSONL；每条请求 `st/en`(monotonic ns) + `st_b/en_b`(boottime ns) + `enq` + `qw_us` + `dur_us` + `res`；每周期一条 `clk` 行给 realtime/monotonic/boottime 对时；轮转到 `.1`~`.3`） |
| 运营日志 | `/userdata/cpu-lab/logs/service.log`（JSONL；`start/stop/slot/calc/cycle/warn`；轮转到 `.1`~`.3`） |
| 控制脚本 | `/userdata/cpu-lab/task-servicectl` |
| 启动钩子 | `/userdata/startup.sh`（由既有 `/etc/init.d/S99auto_startup` 调用） |

## 构建哈希

| 项 | 值 |
|---|---|
| Build ID | `7cd00d399205f0a9f67ea31f2d8d382fafabf15f` |
| md5 | `ba1435bb164ae95e6ac1dbe5998a76e4` |
| 构建 | aarch64，`-O2 -g -fno-omit-frame-pointer -fno-optimize-sibling-calls`，**未 strip**，保留 frame pointer |

## 运行状态

- 当前 **running**（PID 10285），已连续跑过多个 48 s 周期。
- 日志目录占用很小（上限 9 MiB，自动轮转）。

## 自启动状态

- **已配置自启动：是**。入口 `/userdata/startup.sh`，由 rootfs 内**既有**的
  `/etc/init.d/S99auto_startup` 在启动末期（`/userdata` 挂载之后）后台调用；
  **未修改 rootfs、未重挂载、未改启动关键文件**。单实例由 `flock` 保证。
- **重启后已验证启动：否**（未重启板子）。等价验证已完成：实跑 `/etc/init.d/S99auto_startup start`
  能拉起服务；`disable-autostart` 后不会启动。

## 停止 / 禁用方法

```sh
/userdata/cpu-lab/task-servicectl status              # 状态（含 pid/线程/内存/日志路径）
/userdata/cpu-lab/task-servicectl stop                # 停止（SIGTERM；实测 0.04 s 退出）
/userdata/cpu-lab/task-servicectl start               # 启动（单实例，第二个实例会 exit 3）
/userdata/cpu-lab/task-servicectl restart
/userdata/cpu-lab/task-servicectl disable-autostart   # 禁止开机自启（不删钩子、不改 rootfs）
/userdata/cpu-lab/task-servicectl enable-autostart    # 恢复开机自启
```

- 停止只 kill `/userdata/cpu-lab/run/task-service.pid` 中的进程；不会 `pkill`，不删其它路径。
- 完全撤销自启动：删除 `/userdata/startup.sh`（该文件为本次新建）。

## 注意

- 本服务**只产生负载**：不写 sysctl、不改 governor/频率、不用实时调度、不修改其它进程。
- 服务自身不做任何 tracing；板端 tracefs 未被本服务使用。
