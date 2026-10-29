# 主机 / X5 操作与收尾

默认主机准备 SDK、编译、验证配置和运行 TP；板端只需要二进制、shell 和可写目录，不需要 Python。所有变量必须取自实际环境；复用已知兼容工具，不重复下载。

## 只读调查

【目标机】`sh survey.sh`；联合采集再 `sh survey.sh --events > available_events.txt`。两个 tracefs 路径以实际非空内容为准，不能把空壳目录当无事件。检查剩余内存和目录挂载类型；tmpfs 中 Trace 本身也占内存。

【主机】在全新的工作目录交叉构建例子，readelf 核实 AArch64、动态加载器、GLIBC/GLIBCXX 符号版本及 Build ID；没有权限修改生产服务则只部署测试程序。

## System backend 示例顺序

下列路径是布局示例，TRACEBOX 必须替换为实际已验证工具，不能把示例路径当存在。

1. 部署测试二进制、record.sh、候选配置到独立 `/userdata/latency-lab/`；不覆盖原应用。
2. 启动 `latency_demo --backend system --wait-ms 30000 --frames 24`。它等待 SDK category 启用。调用方对进程加有界超时，只管理本次测试 PID。
3. 在另一 shell 启动：

```sh
TRACEBOX=/absolute/tracebox sh /userdata/latency-lab/record.sh \
  /userdata/latency-lab/app.pbtxt /userdata/latency-lab/capture-001 45
```

例子对应 duration 15000 ms。45 秒是示例运行上限，不是承诺耗时；更长配置要相应设置。脚本使用 --system-sockets 与 --notify-fd，只有 byte=0 才置 READY；状态 RECORDED_DATA_UNCHECKED 不冒充数据验收通过。

4. 等待测试程序退出，检查 rc/日志；等待 collector 正常退出。不要把看到非空文件当作已 flush；强杀文件按不完整处理。
5. 将 trace/config/status/exit 拉回独立主机目录。`pull.sh` 对指定文件要求非空；collector.log 允许正常为空时可单独 scp 保存，不为凑非空制造日志。
6. 运行 analyzer，确认 request/stage/Flow/Counter 实际存在，才说联合采集或应用采集通过。

`record.sh` 适用于实验中启动独立 tracebox 服务；现有 traced 正在服务其他任务时，应使用已管理的官方 consumer 会话流程，不能再强占同一 socket，禁止清理别人的 session。

## 身份 / 文件 / 授权

本脚本不启动/重启业务、不修改 governor/sysctl/rootfs、自启动项。只能终止自己持有启动时间标识的 collector 子进程。输出必须新建绝对目录。SSH 使用密钥、agent 或受控认证环境，不把口令写脚本/仓库。

已有记录工具能力不满足时记录 BLOCKED；不为了测试而修改系统 glibc、重挂载 rootfs 或开放全局安全设置。版本/运行/数据/分析/UI分别标状态。

## 可选官方 schema

`validate_config.py CONFIG --descriptor trace_config.desc --descriptor-metadata metadata.json --collector-version ACTUAL_VERSION`。
metadata 至少包含 collector_version、sha256、descriptor_source。必须来自对应版本/提交，不能随便把 metadata 版本改成目标串来骗过校验。本地仅验证 sidecar 一致性，无法替代来源可信度。无 descriptor 时只记录 POLICY_PASS + SCHEMA_UNKNOWN。
