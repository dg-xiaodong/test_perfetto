# 平台/执行：Linux、RDK X5 与 Android

## RDK X5 已知环境（历史事实 ≠ 当前保证）

用户既有 X5 板：ARM64 Linux 6.1.83、glibc 2.35、rootfs 只读；`/data` 是 tmpfs，`/userdata` 常为可写 ext4；板上缺 Python 与外网。tracebox 曾使用 v57.1/v58.2，主机 TP 同版本/较新。**每次执行仍需用只读 survey 核实。** 特别是 X5 `perf_event_paranoid=2` 不等于 `linux.perf` 已可采样；必须实际检查 producer/结果。

## 主机与板端的最短完整流程

```bash
# 【主机】假定当前在 Skill 根目录，先生成配置
python3 scripts/make_config.py scheduling --events /path/to/board_events.txt \
  --duration-ms 15000 > /tmp/cpu.pbtxt
python3 scripts/validate_config.py /tmp/cpu.pbtxt

# 【主机】上传脚本和配置（变量仅在主机展开）
BOARD='root@BOARD_ADDRESS'
REMOTE='/userdata/perfetto-cpu-session'  # 核实存在/有余量，避免 tmpfs 自身干扰
ssh "$BOARD" "mkdir -p '$REMOTE'"
scp /tmp/cpu.pbtxt scripts/linux_session_lib.sh \
  scripts/linux_trace_session.sh "$BOARD:$REMOTE/"
# 另须按本机实际版本/架构把 tracebox 安装到该目录：非随包附赠

# 【主机】启动远程脚本；WORK/TRACEBOX 在目标机有效
ssh "$BOARD" "WORK='$REMOTE' TRACEBOX='$REMOTE/tracebox' \
  sh '$REMOTE/linux_trace_session.sh' '$REMOTE/cpu.pbtxt' cpu 45"

# 【主机】拉回，遇到 scp 失败则退出非零
sh scripts/host_pull.sh "$BOARD" "$REMOTE" ./captures \
  cpu.pftrace cpu.log cpu.status
```

- 输出 `.pftrace` 文件**非空还不够**：先检查状态 `DONE`，然后用 Trace Processor 查 trace_bounds、UPID、sched/频率/perf 样本和 data loss。
- 业务负载应在采集窗口内受控复现；不要悄悄重启正在运行的客户服务。
- `TIMEOUT_STOPPED` 为脚本的超时非正常状态。可保留 trace 但不能标完整 PASS。
- 若远程 `scp` 环境需要 legacy `scp -O`/账号认证，先设置主机 SSH/SCP 客户端或安全封装；**不硬编码明文密码**。
- 对目标机 `$!`/`$(...)` 的引用必须在目标机上下文解析，避免主机双引号提前展开。
- 复用的 shell 脚本仅处理当前会话；不要 pkill 其他进程或清空已有 tracefs。

## TP 与 UI

在【主机】运行已确认的 `trace_processor_shell --help`，以本机版本支持的语法调用（v57.1/v58.2 均为
`trace_processor_shell query -f <单个 .sql> <trace>`），或在 Perfetto UI 的 Query(SQL) 运行。

**一次一个文件**：v57.1/v58.2 的 `query -f` 遇到一个文件里的多条 SELECT 会报
`Result rows were returned for multiples queries` 或只输出最后一个结果集，所以清点拆成
`sql/00-inventory.sql`、`00a-trace-bounds.sql`、`00b-thread-states.sql`、`00c-counter-tracks.sql`、
`00d-stats.sql` 五个单语句文件；频率另用 `sql/04a-frequency-inventory.sql` 做数据验收。
不同工具 CLI 可能不同，不把最新版的参数套到旧版本。

## Android

`linux.ftrace`、`linux.perf` 的权限、API、profileable 和 SELinux 可能不同。`adb shell`、`tools/record_android_trace`、Perfetto 系统服务等应按实际 Android 版本指导；本 Candidate **未完成 Android 实测**，不能直接复用普通 Linux 的 root shell 部署流程作为 Android 操作证明。
