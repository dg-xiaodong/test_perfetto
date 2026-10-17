# B1 — Linux 采集生命周期

你是一个独立 Agent。只加载 `{{SKILL_DIR}}/SKILL.md` 及其目录内的
`references/`、`sql/`、`scripts/`、`tests/`；不得读取其他候选目录、
`v2_test/`、`v2_modify/`、`v2_modify2/` 或任何历史纠错/评分材料。
不要执行命令，不要连接设备，不要修改 Skill。

## 用户输入

目标是一台 ARM64 Linux 设备：

- 进程名 `demo_svc`，动态链接 glibc，允许重启专门的测试实例；
- rootfs 只读，`/data` 可写但是 tmpfs；
- 板端有 tracebox v57.1，主机有对应分析器；
- 板端没有 Python、不能连外网，可通过 SSH/SCP 传文件；
- 已有与 tracebox 匹配的 `libheapprofd_glibc_preload.so`。

请给出两套可执行方案：

1. 不需要 LD_PRELOAD 的低开销 trace（sched/RSS/系统计数器）；
2. native heapprofd 分配调用栈采集。

要求写清【主机】/【目标机】执行位置、变量作用域、启动顺序、观测/持续时间、停止与
flush、SCP 拉回、失败条件和采集验收。不要编造设备实测结果；未验证项要明确标出。
