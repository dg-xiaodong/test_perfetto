# X5 Smoke Test Record — perfetto-memory-debugging v1.0.2 RC

Independent smoke test of the frozen Skill candidate
`v2_modify/candidate-v1.0.2/` on a real RDK X5.

- Frozen commit: `0fa17e08eb8b93a9944232e380c7ddb39666fcf2`
- RC tag: `perfetto-memory-debugging-v1.0.2-rc1` — **created and pushed at
  delivery wrap-up**, annotated, pointing at the frozen commit (it was absent
  during the test; no existing tag was moved).
- Collector: board tracebox/preload v57.1; analysis: host Trace Processor v58.2.

## Status — do not conflate these

| State | Result |
|---|---|
| **S1/S2/S3 functional smoke test** | **PASS** |
| Native heap **dump timeline**, complete **symbolization**, **Perfetto UI** | **Not fully verified (UNKNOWN)** |
| **Real X5 end-to-end** execution | Executed on the live board; evidence in this record |
| **Official v1.0.2 release / deployment approval** | **Not decided here** — separate formal review |

UNKNOWNs (details in `SMOKE_REPORT.md`): heapprofd dump timeline is collapsed by
the v57.1-collector / v58.2-analyzer pairing (14 raw dumps → one `dur=0` dump);
full symbolization is incomplete; Perfetto UI was not opened; no v57.1 descriptor
set was available for schema validation.

The candidate's own tests are `unittest`-based:
`python3 -m unittest discover -s tests -v` → **76/76 OK**. `pytest` is not a
dependency and its absence is not a Skill defect.

## Contents

| Path | What |
|---|---|
| `SMOKE_REPORT.md` | S1/S2/S3 results, evidence, four-level acceptance, status separation |
| `ENVIRONMENT.md` | live board/host environment (versions, mounts, tracefs, tools) |
| `COMMANDS.md` | commands actually run, with exit codes |
| `checksums.txt` | SHA-256 of the frozen commit, configs, traces and outputs |
| `DATA_CLEANUP_PLAN.md` | public-trace exposure inventory, authorization status, history-cleanup plan |
| `logs/` | survey, session, pull, error-path, environment and unit-test logs |
| `sql_out/` | SQL used (frozen originals + parameterized copies) and TP output |
| `hostwork/captures/` | **raw `.pftrace` files** pulled from the board + status/app logs |
| `hostwork/artifacts/` | `traceconv` text of the heapprofd trace (dump-count evidence) |
| `bin/scp` | test-harness wrapper used only so the frozen `host_pull.sh` could run on a password-auth board (`SSHPASS` env; no secret stored) |

## Traces in this directory (raw, unmodified collector output)

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

## Public-data notice

This repository is **public**, so the raw traces above (and the two pre-existing
traces under `x5_heapprofd_traces/` that are part of the frozen commit) are
publicly readable. The 5 traces in this directory were published on explicit
owner instruction. No credentials are included; raw traces contain device paths
and process command lines by their nature. See `DATA_CLEANUP_PLAN.md` for the
exposure inventory, authorization record, and the procedure to make the
repository private and purge traces from Git history. Deleting this directory
alone does not remove them from history.

## Redaction note

Text files in this published copy are sanitized: board IP → `<BOARD_IP>`, host
workspace paths → `<WORKSPACE>` / `<TEST_RECORD>` / `<SDK_ROOT>`, host name →
`<HOSTNAME>`. `.pftrace` files are raw and unmodified; their hashes equal the
capture hashes.
