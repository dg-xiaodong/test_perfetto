# pf-lat-case 时延诊断 — 交付索引（窗口 B，首轮盲测）

主报告：[FIRST_PASS_REPORT.md](FIRST_PASS_REPORT.md)
证据缺口：[SKILL_GAPS.md](SKILL_GAPS.md)　UI 复核：[UI_REVIEW.md](UI_REVIEW.md)

## 目录

```
FIRST_PASS_REPORT.md      诊断报告（结论、证据链、统计口径、复现、证据索引）
SKILL_GAPS.md             本轮实测暴露的 Skill 缺口（G1–G8）
UI_REVIEW.md              手动 Perfetto UI 复核步骤（基于真实存在的对象）
SHA256SUMS.txt            全部交付物哈希 + 报告/Trace 冻结哈希
README.md                 本文件

traces/
  cap-main-90s.pftrace    主证据（track_event only，90 s，1800 请求，0 open）
  cap-sched-70s.pftrace   补证（+ sched_switch/sched_waking，70 s，线程状态）
  cap-probe-15s.pftrace   冒烟测试（仅确认数据源/契约，不参与结论）
  p19.png                 UI 截图证据（q_out 深度三角形，峰值 51）
  p20-1.png              UI 截图证据：severe 窗口慢 output Slice（85ms 66µs）
  p20-2.png              UI 截图证据：mild 窗口慢 work Slice（22ms 06µs）
  p22.png                UI 截图证据：severe 窗口长请求（2.16s）+ 两个 lat.queue + q_out 三角形

configs/
  main.pbtxt, sched.pbtxt, probe.pbtxt          host 生成并校验的配置
  board-recorded-*.pbtxt                        板端采集目录里的逐字节副本

data/
  public_requests_pre.csv  采集前 15 分钟、无 tracing 的公共记录（现象独立见证）
  public_requests_post.csv 主采集后的公共记录快照（逐请求交叉验证）
  public_requests_sched.csv sched 采集后的快照
  crosscheck_trace_vs_csv.txt  Trace 生命周期 vs 公共记录的 1800/1800 交叉验证

analysis/
  main582/                 analyze.py 原始输出（00–04 SQL、stdout、run.json、analysis.json、明细 CSV）
  sched582/                同上（含 sched 的 Trace）
  summary/                 相位/影响面/逐请求时间线等派生汇总
  custom-sql/              本报告使用的自定义 SQL（每条含 query.sql/stdout.csv/stderr/run.json）

metadata/
  board.txt                板端 uname/内存/工具版本/二进制哈希/run.log
  versions.txt             环境、SDK、tracebox、TP、Skill 版本与哈希
  skill-files.sha256       实际调用的 20 个 Skill 文件哈希
  artifacts.sha256         Trace/Config/CSV/日志哈希
  collector-main.log, collector-sched.log, exit-*.txt  采集器原始日志/退出码

tooling/
  skill-files/             实际调用的 Skill 文件副本（与 /root/.dsh/skills/... 同字节）
  README.md                工具版本、哈希、采集命令
```

## 一句话结论

30 s 周期、双窗口：mild 窗口（app+20.0 s）`work` 阶段 +14 ms CPU（E2E 15.8→29.3 ms）；severe 窗口（app+6.0 s）`output` 阶段 +80 ms 定时阻塞（S 状态、~5 ms×16 轮询），服务率 11.75/s < 到达率 20/s，`q_out` 排队使 E2E 最高 2.565 s。端到端升高的主体是队列等待（最坏请求 96.3%），不是那个 85 ms 的 Slice。
