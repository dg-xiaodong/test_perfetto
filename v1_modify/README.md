# perfetto-memory-debugging v1.0.1 候选交付

| 项 | 路径 |
|---|---|
| 只读基线快照（v1.0.0） | `baseline-v1.0.0/`（`chmod a-w`，未改动） |
| 基线校验 | `baseline-v1.0.0.SHA256SUMS`（44 文件） |
| **候选版** | `candidate-v1.0.1/` |
| 候选校验 | `candidate-v1.0.1.SHA256SUMS`（52 文件） |
| 补丁 | `diff-baseline-to-candidate.patch`（842 行，不含 `__pycache__`） |
| 变更摘要 | `CHANGES.md` |
| 测试记录 | `TEST_RECORD.md` |
| 真实 TP 回归脚本 | `verify/tp_check.py` |
| Agent 行为对照 | `AGENT_AB.md` + `candidate-v1.0.1/tests/agent_ab/` |

## 快速核对

```bash
cd candidate-v1.0.1 && python3 -m unittest discover -s tests      # 51 passed
cd ../ && python3 verify/tp_check.py                              # 真实 TP v58.2 + X5 A/B
cd candidate-v1.0.1 && ../scripts_noop 2>/dev/null || true
python3 scripts/validate_config.py --check-resources              # 资源完整性
python3 scripts/validate_config.py <cfg> --deploy-name memprobe    # 静态名称一致性
python3 scripts/validate_config.py --binary ./memprobe_arm64      # PT_INTERP 检查
```

## 未改变

- 部署目录 `/root/.dsh/skills/perfetto-memory-debugging` **未覆盖**（仍等于 baseline，`diff -rq` 已核验）。
- 未修改任何真实 trace、程序日志或验收阈值；未上板、未提交/推送。

## 未执行

- Perfetto UI 实际打开、X5 现场采集、官方 descriptor 校验、Android/kCentral 与其他 `dump_interval_ms` 的适用性。
