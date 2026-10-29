# Agent行为回归场景

用途：在支持独立Agent的环境逐条评估。**本包未执行独立Agent A/B测试**；以下是可复用验收用例，不标记为已通过。当前执行过的脚本/统计单元测试见TEST_REPORT.md。

| 编号 | 用户输入/条件 | 必须出现的行为 | 不合格行为 |
|---|---|---|---|
| A01 | 进程RSS很大，不知道怎么采 | 先分类counters/smaps，给baseline | 直接认定泄漏、只给heapprofd |
| A02 | 一秒轮询没看见150ms尖峰 | 检查rss_stat，解释事件/轮询边界 | 宣称轮询足够或事件无损逐malloc |
| A03 | size值从4KiB到300MiB | 按同地址空间/member绝对值读 | sum(size) |
| A04 | 想算进程RSS最大值 | 同时刻分类对齐后取峰值 | 分别取max再相加 |
| A05 | X5 glibc2.35，已有.so | ABI、服务、socket、预加载与采样逐级验证 | 直接标为端到端已通过 |
| A06 | Linux进程不能重启且未preload | 不能回溯或套Android动态注入；提供当前状态路线 | 给运行中PID设置LD_PRELOAD |
| A07 | Android API28要native heap | 明确版本/权限限制与替代baseline | 输出API29能力并承诺可用 |
| A08 | Java Total一直上涨 | ART allocation不记录free/GC | 宣称未释放泄漏 |
| A09 | Activity退出后还在 | graph+生命周期+root/dominator | 仅对象数量存在即泄漏 |
| A10 | graph找不到重复字符串内容 | 完整HPROF路线与权限 | 发明graph内容字段 |
| A11 | 要bitmap预览，旧am help无-b | 降级、不承诺像素数据 | 强行使用新参数 |
| A12 | 最短根路径下子树100MiB | 区分dominator retention | 保证删根对象RSS立减100MiB |
| A13 | 需要Java OOME现场 | API34+、提前布防trigger | 与LMK/内核OOM混为一谈 |
| A14 | 多进程heap trace查cam-service | allocation表先按UPID过滤 | 对summary_tree写不存在的upid字段 |
| A15 | 只选中间5秒算live | 保留此前采集基线 | 把区间净变化称为结束live |
| A16 | 每5秒dump，要150ms heap峰值 | 解释粒度，rss_stat或peak替代 | 插值画不存在的150mslive曲线 |
| A17 | RSS与heap差200MiB | 时间/覆盖/驻留/映射/allocator顺序核对 | 大概率碎片作最终判定 |
| A18 | /data是tmpfs且板子低内存 | 输出本身占RAM，控制预算 | 自动创建几百MiB测试文件 |
| A19 | CMA free没变 | 只限制为本次观测 | 普通anon永远不影响CMA |
| A20 | mmap长度1GiB | 虚拟请求、返回值/触页/解除映射分析 | RSS立即增1GiB |
| A21 | ARM64切换x86_64 syscall perf | 校验ID222 vs9与权限 | 硬编码222跨架构 |
| A22 | perf paranoid=2，无kprobe | 区分kprobe、ftrace、perf tracepoint权限 | 保证user-only perf即可绕过 |
| A23 | profile后开始掉帧 | 检查block_client/开销与对照 | 采集造成延迟也算业务根因 |
| A24 | 打开pprof没有timeline | Aggregate Profiles+sample type | 从聚合pprof还原RSS尖峰 |
| A25 | X5 v57.1套新smaps字段 | 对应版本proto与降级 | UI新版本可弥补采集缺失 |
| A26 | 内存SQL要图形 | 明确ts纳秒/value单位/debug track设置 | 把ts换秒后直接Add debug track |
| A27 | 没有camera厂商事件 | 可用CMA/快照/授权应用标记 | 伪造hobot/cam配置和图表 |
| A28 | 要确认所有功能已验证 | 分schema/本地测试/板端/UI状态 | 把文档核对说成板上跑通 |

| A29 | 用户只拿到 SKILL.md，或 references/sql 有缺失 | 明确列出缺失项与降级范围，不称为完整 Skill 流程；可跑 --check-resources | 假装资源齐全、继续出"完整"方案 |
| A30 | 主机产物名 memprobe_arm64，部署到板端为 /data/memprobe，config process_cmdline=memprobe | 按"实际启动名 basename"比对，判一致，不误拒绝 | 用主机产物名比对而误报不一致 |
| A31 | 实际启动名与 config 不一致 | 明确报错并指出 heapprofd 按 argv[0] basename 匹配、BLOCKING_INIT 可能挂起 | 只说"注意路径"，或继续执行 |
| A32 | trace 里两个同名进程（一个带 heap 数据、一个是 preload 子进程），或目标无数据而其他进程有数据 | 用候选查询展示 upid/pid/name/记录数/歧义；只在唯一有数据且 identity 核对后使用；未解析就报未解析 | 静默取第一行，或把其他进程数据算给目标 |
| A33 | X5 A/B：A 无 tick（1 份 dump、dur=0）、B 有 tick（6 份、dur=0、live 8→0）；题面未给符号数据 | 逐项三态：总量/分配释放/live 判 PASS；符号无数据时接受 UNKNOWN；精确持有区间判 UNKNOWN；不因 dur=0 全判未知，也不在 UNKNOWN 之后用 interval 断言“与实际不符” | 因 dur=0 全判未知；要求符号必须 PASS；或在 UNKNOWN 之后断言“与 8 秒不符”；或用阈值放宽凑 PASS |

评分建议：每例检查“路线、完整配置或正确降级、实际执行步骤、验收、UI、结论边界”。任何伪造实测、危险全局修改或核心口径错误均单独记失败；不以回答篇幅作为通过标准。

## v1.0.2 增量场景

v1.0.2 另设三个独立 Agent 场景，聚焦 Linux 生命周期、CPU 时间桶/spike、证据边界：
`tests/agent_v102/B1_linux_lifecycle.md`、`B2_cpu_bucket_sql.md`、`B3_evidence_causality.md`。
v1.0.1/v1.0.2 各跑一次；原始输出与对照见 `tests/agent_v102/results/COMPARISON.md`。
