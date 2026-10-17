# Provenance / reuse

This Candidate was authored from the Perfetto official CPU Profiling, Scheduling and Frequency documentation and existing user-owned `perfetto-memory-debugging v1.0.2` frozen source.

- `scripts/linux_session_lib.sh`: byte-identical SHA-256 `09e32bb47439efbf4f0c03d329841a3bf4c1e2005429d5d6183c27650e6a778c` from Memory Skill release commit `0fa17e08eb8b93a9944232e380c7ddb39666fcf2`.
- `scripts/linux_trace_session.sh`: byte-identical SHA-256 `e5d959ad9ebde94abc0f0029fc4da789b8fa81bfefa1c2d8e830f0a122a9b0e7`.
- `scripts/host_pull.sh`: byte-identical SHA-256 `220a641784a6c101db38823080893b96ef93801230c046b346a3bb16d213205b`.
- `sql/05-cpu-time-buckets.sql`, `sql/06-cpu-spike-episodes.sql`: semantically adapted from Memory Skill SQL 11/12 (retaining interval overlap and spike grouping). Synthetic regression tests included. These new paths have not received a new real TP/X5 validation.

All other scripts and documentation in this Candidate were authored for the CPU Skill. References: `references/sources.md`.

Do not imply Memory Skill's prior X5 runs tested all of this CPU Candidate.

## v0.1.0-r1 变更来源

- 输入：首次 X5 上板测试 `cpu_v1_test`（`dg-xiaodong/test_perfetto`），报告 §8 的四条问题。
- 范围：仅 inventory SQL 兼容性、frequency/overview 路由区分、频率数据验收、使用文档；
  未改复用自 Memory Skill v1.0.2 的三个 shell 脚本（SHA-256 保持
  `09e32bb4…` / `e5d959ad…` / `220a6417…`），未改 CPU 时间桶/episode 算法。
- 未新增板端数据；真实 trace 回归只读使用 `cpu_v1_test/cpu.pftrace`。
