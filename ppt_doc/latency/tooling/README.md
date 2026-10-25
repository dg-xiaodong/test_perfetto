# 工具与版本（本轮实际使用）

| 角色 | 版本 | SHA256 | 说明 |
|---|---|---|---|
| 板端 collector | Perfetto tracebox `v58.2-add693d8b` | `2d21883e9c55818f851fd8c391afb9b366032b3110076b4fd41f31f30b5849fa` | `/userdata/perfetto-skill-lab/work/b/tracebox`（板端既有，未替换） |
| TrackEvent SDK | v58.2 | `e56126ff81f0f914d35fe03c72419d147acf2890f36fbda7d4558fd5b84c4b09`（sdk archive，按 PUBLIC_BRIEF/FROZEN） | 应用预编译，未改动 |
| Host Trace Processor | `v58.2-add693d8b` | `58042408e6cc861fb1a731c26bb082dc222285561eaa4e12a48a8b2b90dca7b9` | `trace_processor_shell`（linux-amd64），与 tracebox 同版本 |
| 交叉校验 TP（仅比对） | `v57.1-c59f57dd4` | `79ae477e2f7c1a80a74a48cb0eb660caab29b36cc4f9bdb511b61155d55eaf4d` | `/root/.cache/perfetto-skill/trace_processor_shell`；结果与 v58.2 完全一致 |
| Skill | `perfetto-latency-debugging` v0.1.1 candidate | 见 `../metadata/skill-files.sha256` | `/root/.dsh/skills/perfetto-latency-debugging`；副本在 `skill-files/` |

## 采集命令

```sh
# host: 生成/校验配置
python3 skill-files/scripts/make_config.py --duration-ms 90000 --buffer-kib 16384 --output main.pbtxt
python3 skill-files/scripts/validate_config.py main.pbtxt --check-resources
# -> POLICY_PASS；SCHEMA_UNKNOWN（无同版本官方 descriptor）

# board: 独立目录采集，不启动/停止业务
TRACEBOX=/userdata/perfetto-skill-lab/work/b/tracebox \
  sh /userdata/latency-lab-b/record.sh /userdata/latency-lab-b/main.pbtxt \
     /userdata/latency-lab-b/cap-main 130

# host: 分析
python3 skill-files/scripts/analyze.py --tp <TP> --trace traces/cap-main-90s.pftrace --out analysis/main582
```

## 未做的事（纪律）

- 未改 Skill / 应用 / tracebox / 系统 tracing 服务；
- 未运行“关阶段/换负载/加对照”实验；
- 未读源码、未反编译、未取私有 Ground Truth；
- 未自动化 UI（只给出手动复核步骤）。
