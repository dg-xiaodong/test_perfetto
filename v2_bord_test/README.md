# X5 Smoke Test Record — perfetto-memory-debugging v1.0.2 RC

Independent smoke test of the frozen Skill candidate
`v2_modify/candidate-v1.0.2/` (Perfetto memory-debugging) on a real RDK X5.

- Frozen commit: `0fa17e08eb8b93a9944232e380c7ddb39666fcf2`
- Expected tag: `perfetto-memory-debugging-v1.0.2-rc1` — **not present on the
  remote at test time** (recorded as UNKNOWN; the test pinned the commit).
- Verdict: **PASS** for S1 (normal trace), S2 (native heapprofd), S3 (error
  paths); UNKNOWNs are listed in `SMOKE_REPORT.md` §0.
- Collector: board tracebox/preload v57.1; analysis: host Trace Processor v58.2.

## Contents

| Path | What |
|---|---|
| `SMOKE_REPORT.md` | S1/S2/S3 results, evidence, four-level acceptance, UNKNOWNs |
| `ENVIRONMENT.md` | live board/host environment (versions, mounts, tracefs, tools) |
| `COMMANDS.md` | commands actually run, with exit codes |
| `checksums.txt` | SHA-256 of the frozen commit, configs, traces and outputs |
| `logs/` | survey, session, pull, error-path and environment logs |
| `sql_out/` | SQL used (frozen originals + parameterized copies) and TP output |
| `hostwork/captures/` | **raw `.pftrace` files** pulled from the board + status/app logs |
| `hostwork/artifacts/` | `traceconv` text of the heapprofd trace (dump-count evidence) |
| `bin/scp` | test-harness wrapper used only so the frozen `host_pull.sh` could run on a password-auth board (`SSHPASS` env; no secret stored) |

## Traces in this directory

| File | Note |
|---|---|
| `hostwork/captures/preflight_s1/s1.pftrace` | S1 preflight capture (no workload) |
| `hostwork/captures/s1/s1.pftrace` | **S1 primary**: 14.609 s, `dd` CPU workload, 1532 sched_switch |
| `hostwork/captures/s2/heap.pftrace` | **S2 primary**: 28.467 s heapprofd trace, UPID 190, 44 samples |
| `hostwork/captures/s2_attempt1/heap.pftrace` | S2 first attempt (window incomplete, rc=6) — kept as evidence |
| `hostwork/captures/s3_timeout/s3_timeout.pftrace` | S3 timeout case, **partial** trace (`TIMEOUT_STOPPED`, rc=10) |

Inspect with a matching Trace Processor:

```bash
trace_processor_shell query hostwork/captures/s1/s1.pftrace \
  "select start_ts, end_ts, (end_ts-start_ts)/1e9 dur_s from trace_bounds"
trace_processor_shell query hostwork/captures/s2/heap.pftrace \
  "select * from heap_profile"
```

## Redaction / privacy note

Before publication the text files were sanitized: board IP → `<BOARD_IP>`,
host workspace paths → `<WORKSPACE>` / `<TEST_RECORD>` / `<SDK_ROOT>`,
host name → `<HOSTNAME>`. No credentials (passwords/keys) are included anywhere.
`.pftrace` files are **raw, unmodified** collector output; they may contain device
paths and process command lines (e.g. `/data/smoke102/...`). `checksums.txt` is
computed over the published (sanitized) text files; trace hashes are unchanged
from capture.
