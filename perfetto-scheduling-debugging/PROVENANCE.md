# Provenance / 归档来源（v0.1.0 Candidate / Usable Baseline）

本文件记录本目录这份 Skill 归档**从哪里来、改了什么、没改什么**，便于独立复核。

## 1. 来源与身份

| 项 | 值 |
|---|---|
| 原始包名 / 版本 | `perfetto-scheduling-debugging` / `v0.1.0 Candidate`（`MANIFEST.json` version=0.1.0, status=candidate） |
| 本机安装路径（实际用于上板） | `/root/.dsh/skills/perfetto-scheduling-debugging` |
| 安装版 `MANIFEST.json` SHA-256 | `d224b20463f5e74fd8817b3d44039d8caae0466db6c7468fabf1636916b1f291` |
| 安装版 `SKILL.md` SHA-256 | `71d5dd6662a038845493c68f75df5eca6aaa7a7b550cee5dba4d7272c778bcec` |
| 与原始 candidate 包的关系 | `diff -rq` 对安装版与原始解包副本 → **无差异**（即安装版未被本地改动） |
| 规模 | 57 个文件（含本文件）/ ≈324 KB；无 `__pycache__`、无 `.pyc`、无口令、无板端环境文件、无业务日志 |

## 2. 这是被 `v5_test` 验证过的那一版

板端测试仓库：<https://github.com/dg-xiaodong/test_perfetto/tree/main/v5_test>

- `v5_test` 的报告与命令记录明确使用本路径 `/root/.dsh/skills/perfetto-scheduling-debugging`（version 0.1.0 Candidate）。
- `v5_test/sql/` 下 19 个 SQL 与本归档 `sql/` **逐字节一致**（SHA-256 全等）。
- `v5_test` 的两套 TraceConfig 由本归档 `scripts/make_config.py` 生成，并经 `scripts/validate_config.py` 校验
  （`RESOURCES_PASS` / `POLICY_PASS`，并用官方 v57.1 `trace_config` descriptor 得到 `SCHEMA_PASS`）。
- 原始 Trace SHA-256：`cap1-overview.pftrace 42d885fefb35c2e74297c637f3f81f99ab5732562fd1b85a623c69f94c9d6693`、
  `cap2-blockwake.pftrace fd34cfd83dfe2d6ef6c24f5119f674bba97483eda79a4eec9d4d21a9d95040e6`（与板端采集值一致，归档未重写）。
- 采集器 `tracebox v57.1-c59f57dd4`；Trace Processor `v57.1-c59f57dd4`；板卡 `6.1.83-DR-PL5.1_V1.0.20`（RDK X5，8 核）。

## 3. 本归档相对安装版改了什么

**只动了版本记录与清单，没有动诊断逻辑或核心实现。**

| 文件 | 变更 |
|---|---|
| `README.md` | 标题加入 `/ Usable Baseline`；新增「版本状态」节：已完成真实 X5 验证、尚未完成专项验收、已知限制；未改安装/使用说明 |
| `TEST_REPORT.md` | 末尾追加「归档更新（2026-10-18）」：覆盖 authored 时的 NOT_RUN 记录，并把“未推送任何仓库”明确为 authored 时状态；未改原有章节 |
| `MANIFEST.json` | 更新 `status`/`baseline`/`verification`，并按本归档实际文件重算 SHA-256 |
| `SHA256SUMS.txt` | 重新生成（含 `MANIFEST.json`，不含自身） |
| `PROVENANCE.md` | 本文件（新增） |

其余 **52 个文件逐字节未变**（`SKILL.md`、`AGENT_HANDOFF.md`、`NOTICE.md`、`RESOURCE_LIST.json`、
`configs/`、`examples/`、`references/`、`scripts/`、`sql/`、`tests/`、`workflows/`）。可机检：

```sh
diff -r /path/to/installed-skill . \
  --exclude README.md --exclude TEST_REPORT.md --exclude MANIFEST.json \
  --exclude SHA256SUMS.txt --exclude PROVENANCE.md && echo CODE_IDENTICAL
```

## 4. 安装与校验

将本目录整体放入所用 Agent 的 skills 目录（`SKILL.md` 必须在目录顶层），然后在目录内执行：

```sh
python3 scripts/verify_package.py                      # MANIFEST 哈希 + 44 项必需资源
python3 scripts/validate_config.py --check-resources    # RESOURCES_PASS count=44
python3 -m unittest discover -s tests -v               # 59 个测试（58 通过 / 1 跳过：需真实 TP）
```

- 不依赖 Memory Skill、CPU Skill；也不修改已落盘的 Memory/CPU Skill。
- 官方 schema 校验需要 Python protobuf 与**对应版本** descriptor；板端脚本只需 POSIX sh + tracebox。
- 版本标记：**v0.1.0 Candidate / Usable Baseline**（不是 Stable）。C1–C6 未全部通过，见 `TEST_REPORT.md`。
