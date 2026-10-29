# 分析口径、完整性与边界

## 两个状态维度

- `integrity_status`：COMPLETE / INCOMPLETE / CENSORED / INVALID / UNKNOWN（UNKNOWN 用于尚不能分类的数据；当前引擎对可识别但缺字段的对象给具体 INCOMPLETE/INVALID）。
- `outcome_status`：SUCCESS / ERROR / DROP / TIMEOUT / CANCELLED / UNKNOWN。

显式 DROP 的输入与终态及声明完整，可以 COMPLETE+DROP；不进入成功延迟分布。仅缺结束只给 INCOMPLETE+UNKNOWN。反序、重复 begin/end、重复实例、未知阶段 Flow、身份冲突是 INVALID。boundary 见证才能将观测不完整分类为 CENSORED。

`lifecycle_status` 专门表示请求端点，pipeline integrity 还验证阶段闭合、阶段结果、计数声明、队列访问和实际 Flow。本版单个阶段缺失会阻止该请求进入严格成功统计，即使端点可计算 E2E。

Trace 全局 error/data_loss 使严格延迟样本暂不纳入；这是一项保守验收策略，不意味着已证明每个请求都受影响。可在有证据时人工限定受损流/窗口，必须保留依据和原报告。未归属业务身份的事件单独计数，也不默默丢掉后宣布完整。

## 时延维度

E2E = request_end - request_begin；queue = queue Slice 的 dur；stage = stage Slice 的 dur。

stage_work_wall_sum 是阶段墙钟总和；stage_wall_union 是同一请求中阶段区间的并集长度；两者差表示观测到的阶段重叠。它们不一定等于 CPU 工作量，不与队列总量直接相加当 E2E。重试全部独立保存。未解释间隙不自动归责 OS、锁或 BPU。

最长 Slice 不自动成为关键路径。首版固定输出 critical_path_status=NOT_COMPUTED；允许人工用完整、显式的边和业务依赖论证候选关键分支，但不声称已实现任意 DAG 关键路径算法。

## 函数与调度

函数统计来自已闭合 Slice 的 inclusive wall duration；不累加嵌套事件。thread_dur 只有采集实际写入且能绑定线程时才是可用线程时间；NULL 不是 0。generic custom Track 不映射到唯一线程，14-thread-overlay 将返回 NO_THREAD_BINDING。

只有线程 Track 可按相同纳秒窗口与 thread_state 求交。Running 的调度归属时间也不能无条件等同逐指令用户态计算：中断或其他运行时机制需要进一步证据。需要 On-CPU 热点交 CPU Skill，等待归因交 Scheduling，传递 trace hash/upid/utid/窗口。

## 帧与长尾

每个 run+stream 单独保留输入、有效输出、明确丢弃/超时。帧间隔按实际输出时间排序，不按 frame ID 排序。ID 缺口只是未观察到的序号，不自动变成丢帧。乱序单列，时间戳相同也单列。应用输出不等于硬件显示/呈现。

区间 FPS=(N-1)/(最后事件-首事件)，不足两帧返回 NULL；固定 Trace 窗口 FPS=N/窗口秒数，两种分母标清。不能用一个“FPS”混称相机输入、处理完成、显示刷新。

分位数使用 nearest-rank `ceil(q*N)`；只在 COMPLETE+SUCCESS+无全局损失样本上给严格请求统计。P99 带 N 和排除原因，N<1000 的提示是本包提醒策略，不是数学置信区间或“达到1000就一定稳定”。函数分布为观测到的闭合 Slice 群体，需单独看开口与数据丢失。

## 输出复核

`run_query.py` 保存一个 SELECT 的 query.sql/stdout.csv/stderr.txt/version.txt/run.json。不要把工具 stdout 的 `column 0 = ...` 当数据；分析器仅去掉已知前缀，保留原始 stdout 供检查。

10–14 号 SQL 可用于手动查看，但不是完整契约判定器。`analyze.py` 运行 00–04 导出后执行 `latency_core.py` 的测试过的契约逻辑。结果 JSON 包含 trace/TP SHA；原生表中没有本 Skill 的 integrity_status，这些是派生结论。

先不改阈值迁就结果。原始 SQL/Trace 不动；修正分析另存新结果，记录版本。
