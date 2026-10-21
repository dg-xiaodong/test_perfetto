# demo_capture — RDK X5 Perfetto 真实采集与分析（窗口 B）

本目录是窗口 B 的独立诊断交付物：在 RDK X5 上对常驻测试程序 `pf-demo-x5` 完成真实采集、
四 Skill 分析、逐项能力验收、UI 演示指南与 Ground Truth 对照。

**先读** [`REPORT.md`](REPORT.md)（结论与 8 个问题的答案），再按需打开：

| 文件 | 内容 |
|---|---|
| [REPORT.md](REPORT.md) | 完整诊断报告、Trace 清单与 SHA256、事故与限制 |
| [UI_DEMO_GUIDE.md](UI_DEMO_GUIDE.md) | P2–P12 逐页操作（真实时间戳/字段/SQL）；截图状态：待执行 |
| [COVERAGE_MATRIX.md](COVERAGE_MATRIX.md) | 14 项能力 PASS/FAIL/UNKNOWN + 证据路径 |
| [SKILL_GAPS.md](SKILL_GAPS.md) | 四个 Skill 的缺口 G1–G17 |
| [GROUND_TRUTH_COMPARISON.md](GROUND_TRUTH_COMPARISON.md) | 与窗口 A 私有答案的逐项对照 |
| `traces/` | 9 个 `.pftrace` + 1 个 `perf.data`（见 [traces/README.md](traces/README.md)） |
| `configs/` | 实际使用的 cfg、四个 Skill 原配置、[COMPOSITION.md](configs/COMPOSITION.md) |
| `sql/skills/` | 四个 Skill 原样 SQL（未修改） |
| `sql/custom/` | 本次补充的分析 SQL（24 条，已标注"临时补充"） |
| `results/skill/`、`results/custom/`、`results/custom-blockwake/` | 每条查询的 query.sql / stdout.csv / stderr.txt / rc.txt |
| `results/ROUND1_DIAGNOSIS.md` | 首轮独立诊断（冻结稿 + 独立 SHA256，先于 Ground Truth） |
| `logs/` | 环境版本、Skill 哈希、第一步平台探测、采集日志、Trace 哈希 |
| `screenshots/` | 3 张真实"UI 已打开"截图；P2–P12 轨道截图待执行 |

## 复现

```sh
# 板端（192.168.1.10）：只读探测 -> 唯一 perf producer -> 120 s 采集
sh logs/remote_capture_only.sh /userdata/perfetto-b/cfg/overview_120s_v2.cfg /userdata/perfetto-b/out/run
# 主机：拉回后逐条执行目录内的 query.sql
TP=/root/.cache/perfetto-skill/trace_processor_shell
$TP query traces/overview_system_app.pftrace -f results/custom/c20-phase-metrics/query.sql
```

## 体积提醒

`traces/` 合计约 41 MB（最大单文件 14.3 MB）。本目录的 `.gitignore` 默认忽略
`traces/*.pftrace` 与 `traces/*.perfdata`，避免无意把大文件推上 GitHub；
需要共享时先确认仓库限制。原始文件路径与 SHA256 见 `traces/README.md`。
