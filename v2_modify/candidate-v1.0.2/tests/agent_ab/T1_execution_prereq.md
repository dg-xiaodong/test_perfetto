# 任务 1：执行前提

目标机：RDK X5（Linux ARM64，glibc 2.35，/data 为 tmpfs）。
你有一个测试程序：交叉编译产物在本机叫 `memprobe_arm64`，计划部署到板端 `/data/memprobe`；
采集配置里 `process_cmdline: "memprobe"`；用 `LD_PRELOAD` + `PERFETTO_HEAPPROFD_BLOCKING_INIT=1` 启动。

请回答：
1. 采集前必须做哪些检查？分别属于"只能静态完成"还是"必须运行期证据"。
2. 如果实际部署/启动名写成 `memprobe_arm64`（与配置不一致），会发生什么？
3. 给出可直接执行的检查命令。
