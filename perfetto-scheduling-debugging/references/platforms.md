# 平台与执行

## 条件

主机：Python3，现有 Trace Processor；可选 protobuf + 对应 descriptor、SDK C++ 编译器。
目标：Linux/Android 的数据源与权限按实际检查。X5 历史基线是 ARM64、Linux6.1.83、rootfs只读、/data tmpfs、/userdata可能持久可写；**本次不替代探测**。不修改生产进程、sysctl、governor、启动脚本、挂载或他人 tracing。

Linux 常用 tracebox（集成服务），Android 一般使用系统 perfetto 服务及 /data/local/tmp；本包 record.sh 专为 Linux tracebox，不冒充已验证 Android 全流程。Android event perf 的访问、栈和符号条件另依对应系统规则。

## 主机/板端操作（以真实探测得到 8 核、4KiB 页为例）

【板端，只读与新取证目录】

```sh
sh /absolute/skill-copy/scripts/survey.sh
sh /absolute/skill-copy/scripts/survey.sh --events > /absolute/new-work/events.txt
sh /absolute/skill-copy/scripts/survey.sh --formats /absolute/new-work/formats
```

将事件文件和 formats 拉回主机；从 `/proc/PID/task` 确认目标 TID 与生命期。不要把 TGID、TID、TP 的 UPID/UTID 混用。

【主机，Skill 根目录】

```sh
python3 scripts/make_config.py overview --cpu-count 8 --events /host/work/events.txt \
  --duration-ms 15000 --output /host/work/overview.pbtxt
python3 scripts/validate_config.py /host/work/overview.pbtxt
```

需要事件栈才生成：

```sh
python3 scripts/make_config.py block-wake --cpu-count 8 --page-size 4096 \
  --tid 12345 --events /host/work/events.txt --formats /host/work/formats \
  --duration-ms 15000 --output /host/work/block-wake.pbtxt
```

`12345` **必须换成仍存活的目标 TID**。block/wake 范围扩大时重复 --tid，不改成全系统。内核帧只有已具备权限时加 `--kernel-frames`；不加内核帧不等于 tracepoint 不需要权限。

【目标】只推当前配置和 `scripts/record.sh`；无需 Python 或整包。

```sh
TRACEBOX=/actual/tracebox sh /actual/record.sh \
  /actual/block-wake.pbtxt /actual/new-capture 40
```

配置 15s，示例总看门狗40s，必须包含启动与正常收尾余量。输出目录必须不存在；脚本不覆盖历史文件，采集程序是它的直接子进程，`--notify-fd` 字节核对成功后写 READY；正常等待子进程退出后只报告 RECORDED_DATA_UNCHECKED。需要触发受控动作时，另一个终端等 READY 后执行已授权动作；脚本自身不启动/停止任何业务。

TIMEOUT 返回10；非零退出、未就绪和空文件返回非零，部分 trace 保留。SIGKILL 不作为成功收尾。脚本默认拒绝已启用的外部 tracing；不要用 mock 专用 SKIP_TRACEFS_CHECK 绕过真实会话保护。

【主机】

```sh
sh scripts/pull.sh user@board /actual/new-capture /host/new-capture trace.pftrace config.pbtxt status.txt
```

只要求指定非空文件；collector.log 可能为空，可另行复制。使用 SSH 密钥/agent 或交互认证，不在脚本/日志写密码。不要把不能交互的认证失败说成采集器缺陷。

## 预算

默认 block/wake 2×8×(64+1)×4KiB = 4160KiB perf rings（含每ring一个metadata页的规划估算）；ftrace 512KiB×8；traced 8192KiB；共享 unwinder队列8192KiB；预留16384KiB。合计约40MiB，默认预算64MiB。**不是实测峰值或系统硬限制**；展开缓存、程序、输出和其他会话还会占空间。配置 ring 单位参考 S3 的4KiB约定，本版对非4KiB目标页明确拒绝事件栈配方，留待单独验证。

## 官方 schema

已有匹配源码和 protoc 时生成 descriptor，不在每次诊断自动下载/编译整仓库：

```sh
protoc -I "$PERFETTO_SRC" --include_imports \
  --descriptor_set_out=/host/work/config.desc \
  "$PERFETTO_SRC/protos/perfetto/config/trace_config.proto"
```

metadata 为可信构建记录：`{"collector_version":"v58.2","sha256":"该descriptor实际SHA256"}`。

```sh
python3 scripts/validate_config.py /host/work/block-wake.pbtxt \
  --descriptor /host/work/config.desc --descriptor-metadata /host/work/config.desc.json \
  --collector-version v58.2
```

版本标签本身不能证明 descriptor 来自那个版本，维护者须保存真实源码提交与生成命令。无 descriptor 时只得 POLICY_PASS + SCHEMA_UNKNOWN，不能将手写子集校验当成官方 schema 通过。
