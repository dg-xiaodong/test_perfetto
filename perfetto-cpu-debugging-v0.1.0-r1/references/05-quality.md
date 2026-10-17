# 质量验收、证据边界与停止条件

## 四级验收

1. **Schema**：同**板端 collector** 版本匹配的 TraceConfig descriptor 解析；结构检查和主机 TP 版本不代表 collector schema PASS。
2. **Runtime**：事件实际存在；tracebox、traced_perf、权限/生产者/内核 ftrace 实际就绪；命令行、退出码、停止/flush/拉回有记录。
3. **Data**：目标 UPID/UTID、窗口、真实 sched_slice、thread_state、counter、perf_sample 数量、stats data loss 逐项有数据；空结果不等于零 CPU/没有热点。
4. **Analysis/UI**：SQL 单位和裁剪、时间线、上下文、采样方差/符号正确；未打开 UI 就写 UI UNKNOWN。

分别给 PASS / FAIL / UNKNOWN，不得以总状态代替细项。抓到 perf_sample 不证明慢由函数造成；Runnable 长不证明调度器错误；频率低不证明热降频。

## 最小充分证据 / 任务预算（v0.1.0 重要规则）

- 首轮优先一个已授权、短时、最小可复现 trace；只对数据缺失/冲突部分补采。
- 如果问题是“哪个线程烧 CPU”，`sched_slice` + 合理时间窗已经定位就停止；**不强行加 perf/freq/压力测试**。
- 如果问题是“哪个函数烧 CPU”，`linux.perf` 的权限未知要先做单次短 smoke；失败则明确 UNKNOWN 和替代路径，不自动调整系统 sysctl。
- 不得为提高报告完整度自行执行十几轮压力、`SIGKILL`、清缓存、修改 governor、覆盖服务、广泛 `rm -f`；破坏性操作需明确授权。
- 用户已有 trace，则先分析文件；不以“重新采集更新”代替交付。

## 关键误区

- 线程 on-CPU ms 与 % 的分母不同；单线程 100ms/100ms 是满一核，不等于 8 核 SoC 全系统 100%。
- `sched_switch` 不保证恢复完整 Runnable 状态；须验证 wakeup 数据。只统计 S/D 时间不能证明锁竞争，还需进一步机制证据。
- CPU 时间桶必须做区间交集，不能整片计入起始桶；多个线程的 CPU 时间加总可以 > 1s/s（多核）。
- CPU 频率图空可能是未发生变频、无 sysfs、无权限、采集器不支持；低频时可能 CPU idle。
- perf samples 按概率采样；缺符号会降低热点定位粒度；系统级 summary tree 不可冒充目标 UPID 热点。
- 安全清理：仅删本会话唯一文件；不要使用通配符删 `/data` 下别人的临时文件。
