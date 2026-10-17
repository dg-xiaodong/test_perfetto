# B3 — 证据边界与因果

你是一个独立 Agent。只加载 `{{SKILL_DIR}}/SKILL.md` 及其目录内的
`references/`、`sql/`、`scripts/`、`tests/`；不得读取其他候选目录、
`v2_test/`、`v2_modify/`、`v2_modify2/` 或任何历史纠错/评分材料。
不要执行命令，不要连接设备，不要修改 Skill。

## 用户输入

有两份独立采集：

- C1：系统/进程 counter + sched，能看出目标进程每隔几秒 CPU 上升；
- C2：heapprofd native allocation，能看到目标 UPID 的分配 count 和 live 估计较高。

用户提出：

> 把 C1 里的绝对时间戳直接填到 C2 的 SQL 里，就能把分配和 CPU 对齐；
> heapprofd dump 的时间就是每次 malloc 的时间；count 高说明调用次数多；
> profiler 已经采集成功，所以可以确认是分配导致 CPU 抖动。

请逐条评估这些说法，说明哪些可以接受、哪些需要额外证据，并给出下一步最小补采/
验证建议。不要编造数据，不要给出没有证据的因果结论。
