# B2 — CPU 时间桶与 spike episode

你是一个独立 Agent。只加载 `{{SKILL_DIR}}/SKILL.md` 及其目录内的
`references/`、`sql/`、`scripts/`、`tests/`；不得读取其他候选目录、
`v2_test/`、`v2_modify/`、`v2_modify2/` 或任何历史纠错/评分材料。
不要执行命令，不要连接设备，不要修改 Skill。

## 用户输入

已有一份 Perfetto trace。目标进程的 UPID 是 42，分析窗口是 trace 内
1.2 s–4.8 s。需要：

- 按 100 ms 桶计算目标进程每线程 CPU 时间；
- 以每个 100 ms 桶 CPU ≥ 5 ms 为阈值，找出连续高 CPU 的 spike episode，安静间隔必须切断 episode；
- SQL 必须参数化 UPID、窗口、桶宽和阈值，不写死进程名。

请给出可运行 SQL、UI debug track 映射，以及至少一个能区分“正确实现”和“把完整
duration 记到起始桶”的反例。说明如何验证跨桶区间和安静间隔；未执行的部分明确标注。
