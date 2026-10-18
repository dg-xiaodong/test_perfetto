# 交给独立 Agent 的最小验收任务

把整目录解压放进 Agent 可以读取的 Skill 路径，或在任务中明确让其读取 `perfetto-cpu-debugging/SKILL.md`。

**第一轮仅检查这两个问题，避免过度测试：**

1. “RDK X5 上一个 C++ 服务每隔几秒 CPU 占用变高，请用 perfetto-cpu-debugging 选择合适采集方式，短时上板采集并分析哪个线程在忙。不要重启业务。”
2. “另一个任务：CPU 占用不高，但一条测试线程偶发执行得晚。请区分 Running / Runnable / Sleeping，告诉我还需要什么数据才能判断调度延迟。”

有设备时允许只读 survey + 一个短 trace。没有设备时应标 `BLOCKED`，不要伪造实测。测试时不要给 Agent 具体 SQL 名称、配置字段或既有标准答案；记录首轮结果、实际调用/命令、已采 Trace/SQL、未验证项及执行耗时。先看能否自动选路和及时停止，再决定是否扩展。

**独立评审重点：** 实际是否读取了 SKILL.md 和相关引用；X5 数据源是否真实存在；是否先确认 UPID/UTID；CPU 时间与 Runnable 分离；失样/空结果是否标 UNKNOWN；linux.perf 受限时是否尊重权限；有没有超范围新增压力或系统配置操作。不能仅根据最终报告包含术语推定 Skill 已被加载。
