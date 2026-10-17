# Smoke Test Report — perfetto-memory-debugging v1.0.2 RC on RDK X5

- Test scope: S1 normal trace · S2 native heapprofd end-to-end · S3 error paths
- Test date: 2026-10-17 (board live session)
- Test record: `<TEST_RECORD>/` (outside the frozen candidate)
- Frozen candidate: `v2_modify/candidate-v1.0.2/` @ `0fa17e08eb8b93a9944232e380c7ddb39666fcf2`
- Host analyzer: Perfetto **v58.2**; board collector: tracebox/preload **v57.1**
- Execution levels used: **board actual** / **host offline (real TP)** / **static check** / **UNKNOWN**

## 0. Final verdict

**PASS** — all necessary checks of S1/S2/S3 that could be executed passed; no
code/config/execution defect was found in the frozen candidate. Recorded
UNKNOWNs (none of them is a silent pass):

1. `perfetto-memory-debugging-v1.0.2-rc1` **tag is not on the remote**; the test
   pinned the known frozen commit instead (explicitly allowed by the task).
2. Perfetto UI native-heap flamegraph was **not opened** (no browser/UI in this
   environment) → UI-level UNKNOWN.
3. No v57.1 descriptor set was available, so formal schema validation against the
   **collector** version is UNKNOWN; v58.2 descriptor validation passes only as a
   supplementary check.
4. heapprofd **dump timeline** is not analyzable with a v57.1 collector + v58.2
   analyzer: all raw dumps carry the same timestamp (`dur=0`, 1 visible dump).
   Data attribution is still valid (see S2).
5. Full frame symbolization is incomplete (top allocation frames named; libc and
   preload-internal frames unnamed) → deep-stack symbolization UNKNOWN.

## 1. Version freeze verification

| Check | Result | Evidence |
|---|---|---|
| Remote repo reachable | PASS | `git ls-remote origin` → `0fa17e08... HEAD`, `0fa17e08... refs/heads/main` |
| Expected RC tag `perfetto-memory-debugging-v1.0.2-rc1` exists | **UNKNOWN (absent)** | `git ls-remote --tags origin` returned no lines; local clone has no tags either |
| Frozen commit `0fa17e08...` accessible | PASS | local clone HEAD = `0fa17e08...`, worktree clean (`git status --porcelain` = 0 lines) |
| Candidate dir = frozen commit | PASS | `v2_modify/candidate-v1.0.2/` is the committed tree at `0fa17e08...` |
| MANIFEST vs files | PASS | 77/77 files present, **SHA-256 all match** (`MANIFEST.json` lists 77 entries; self and `CHANGES.diff` excluded by design) |
| Candidate not modified during test | PASS | final `git status --porcelain` = 0 lines; no writes to candidate dir |
| No moving `main` used | PASS | all runs used the pinned commit; `main` happened to equal it at test time, recorded but not relied on |

Per instruction #4, the missing tag was recorded as UNKNOWN and the test
continued on the pinned commit. No silent version switch was made.

## 2. S1 — normal Perfetto trace (board actual + real TP analysis)

### Setup
- `configs` generated from the frozen generator with the board's real
  `available_events`: `overview --sched`, `duration_ms=15000`, `poll_ms=500`,
  buffers 8192/4096 KiB, `linux.process_stats` + `linux.sys_stats` +
  `linux.ftrace(sched/sched_switch)`.
- Collector: board tracebox v57.1 (deployed); session script:
  `scripts/linux_trace_session.sh` (frozen, unmodified), `TIMEOUT_S=60`.
- Workload: `timeout 10 dd if=/dev/zero of=/dev/null bs=64k` started 2 s after
  capture start (a controlled CPU target; no business process touched).
- Pull: frozen `scripts/host_pull.sh`.

### Results

| Level | Check | Result | Evidence |
|---|---|---|---|
| Schema | Config accepted by v57.1 collector | PASS (runtime-level) | tracebox started, data sources configured, trace produced |
| Schema | Descriptor validation against v57.1 | **UNKNOWN** | no v57.1 descriptor set available; v58.2 descriptor `[PASS] schema` recorded as supplementary only |
| Runtime | tracefs available, events exist | PASS | `/sys/kernel/debug/tracing`, 1170 events, `sched:sched_switch` present, read via `survey.sh` (rc 0) |
| Runtime | writable output dir on tmpfs | PASS | `/data` tmpfs (668012 KiB total); test peak ~4.4 MiB, 0 used after cleanup |
| Runtime | session script returns normally | PASS | `SCRIPT_RC=0`, `DONE size_bytes=73088`; preflight run also `DONE size_bytes=74538` |
| Runtime | no leftover tracebox/traced after session | PASS | `ps -ef` empty for tracebox/traced |
| Data | trace parses with TP v58.2 | PASS | "Trace loaded: 0.07 MB" no parse errors |
| Data | `trace_bounds` duration in 10–20 s | PASS | `start=27646196027307 end=27660804887481` → **14.609 s** |
| Data | process info | PASS | process table populated; target `dd` UPID 194 pid 2411; 912 per-process counter samples |
| Data | system memory counters | PASS | 30 samples each of MemTotal/MemFree/MemAvailable/AnonPages/Shmem/Slab/CMA… at 500 ms; e.g. `MemAvailable` 1.136–1.137 GB, `MemTotal` 1.368 GB |
| Data | `sched_switch` data | PASS | 1532 `sched_switch` ftrace events; 1532 `sched_slice` rows |
| Data | target thread scheduling | PASS | `dd` (tid 2411): 90 slices, **9999.51 ms** CPU, first 27647533017433 → last 27657533583396 (matches `timeout 10`) |
| Data | data loss / errors | PASS | non-zero `error/warning/data_loss` stats: **none** (all `traced_buf_*` loss counters = 0) |
| Analysis | `sql/11-cpu-time-buckets.sql` (UPID 194, 100 ms) | PASS | 101 buckets (idx 13…113): leading partial **62.99 ms**, full buckets **100.00 ms**, trailing partial **37.56 ms** — interval intersection behaves as documented |
| Analysis | `sql/12-cpu-spike-episodes.sql` (UPID 194, 1 s, 100 ms) | PASS | one episode: `ts=27647196027307 dur=11 s buckets 1..11 peak 999.96 ms avg 909.05 ms` (sum ≈ 10 s CPU) |
| Analysis/UI | trace opened in Perfetto UI | not required for S1 | — |

Raw outputs: `sql_out/s1_summary.txt`, `sql_out/s1_sql11.txt`,
`sql_out/s1_sql12.txt`, `logs/s1_session*.log`, `hostwork/captures/s1/`.

**S1 = PASS** (with the v57.1 schema-descriptor UNKNOWN noted above).

## 3. S2 — native heapprofd end-to-end (board actual + real TP analysis)

### Setup
- Test program: existing `memprobe` (ARM64, dynamically linked, GLIBC ≤ 2.34,
  Build ID `26b6759f…`), deployed as `/data/smoke102/app/memprobe`; control run
  `live 1 500 0` rc=0. Profile run: `both 8 16000 512 40 20 12000`
  (8 MiB live + 40×512 KiB churn, then free, 12 s post-free window).
- Config generated from the actual executable basename:
  `make_config.py native --process memprobe --duration-ms 90000 --dump-ms 2000 --sampling 4096`;
  `validate_config.py --deploy-name memprobe` PASS; `--binary` PASS (PT_INTERP).
- Session: frozen `scripts/linux_heapprofd_session.sh`, `OBSERVE_S=25`,
  `--system-sockets` default path, preload and tracebox both v57.1.
- Producer registration observed separately from service start via
  `tracebox perfetto --query --long` (`heap.query.txt`).

### Results

| Level | Check | Result | Evidence |
|---|---|---|---|
| Schema | target name matches launched basename | PASS | `[PASS] deploy-name: 'memprobe' matches target(s) ['memprobe']`; trace process `./memprobe` |
| Schema | duration covers observation + margin | PASS | `duration_ms=90000 ≥ 25 s + 30 s`; actual session ≈ 29.5 s, no duration cut |
| Schema | config accepted by v57.1 collector | PASS (runtime) | heapprofd data source registered and sampled |
| Runtime | service start vs producer registration | PASS | `heap.query.txt`: service v57.1 up; producers include **`android.heapprofd` pid 2598**; both recorded in the same query |
| Runtime | BLOCKING_INIT bounded | PASS | session completed in bounded time; app log shows `Connected to the service, mode [child]` before allocation events; outer 200 s watchdog used; script's own stop path executed |
| Runtime | target process alive through window | PASS (attempt 2) | `SCRIPT_RC=0`, `DONE size_bytes=43576`; attempt 1 correctly failed with rc=6 when the program lifetime ≈ observation window |
| Runtime | safe stop + cleanup | PASS | script killed app (SIGTERM), SIGINT to tracebox, flush; `ps` shows no memprobe/tracebox/traced afterwards |
| Data | trace parses with TP v58.2 | PASS | loaded 0.04 MB; no parse errors |
| Data | target UPID / heap | PASS | UPID **190** pid 2595 `./memprobe`, heap `libc.malloc`; sidecar UPID 192 (`heapprofd` child inheriting cmdline) has `data_bearing=0` — `sql/00` candidate rule resolves unambiguously (`ambiguous=0`) |
| Data | heapprofd actually sampled the target | PASS | 44 heap samples; `heap_samples=44`, `unwind_samples=616`, `unwind_time_us=87164`, `client_disconnected=1`; 0 error/warning/data_loss stats |
| Data | allocation attribution | PASS | `sql/04`: `main → probe_churn_cycle → malloc` = **20 MiB (40 allocs)**, `main → probe_live_block → malloc` = **8 MiB (4 allocs)**; total **29,360,128 B allocated / freed** (exactly the program's 40×512 KiB + 4×2 MiB) |
| Data | dumps visible to TP | **1** (raw 14) | `sql/10`: `dumps=1, distinct_ts_end=1, zero_dur_dumps=1`; `heap_profile.dur=0` |
| Data | raw collector dumps | 14 dumps ≈ every 2 s | `traceconv text` parsed 14 `profile_packet`s (pkt ts 27767526527365 … 27792263263377); **all carry the same `process_dumps.timestamp = 27766343748698`** → TP collapses them into one `dur=0` row |
| Data | dump counts ≠ config periods | PASS (understood) | 14 raw dumps (≈ actual 29.5 s / 2 s) vs 45 possible periods (90 s config / 2 s) vs 1 analyzable dump — different quantities, reported separately |
| Data | live / total / RSS not conflated | PASS | total allocated 28 MiB; live-at-end 0 MiB; process `mem.rss` (separate process_stats counter) not used as heap; no metric substitution |
| Analysis | `sql/03-native-live.sql` usable | **UNKNOWN (temporal)** | returns a single point `0 MiB` because the only analyzable dump is the exit dump; a live-over-time curve is not derivable with this v57.1 collector + v58.2 analyzer |
| Analysis | `sql/10-native-dump-capability.sql` | PASS | matches the exact documented degradation pattern (`zero_dur_dumps == dumps == distinct_ts_end == 1`); not interpreted as collection failure |
| Analysis/UI | Perfetto UI native-heap flamegraph | **UNKNOWN** | no browser / Perfetto UI available in this environment; SQL-level attribution done instead |
| Data | symbolization | PARTIAL / UNKNOWN | frames named: `_start`, `__libc_start_main`, `main`, `probe_churn_cycle`, `probe_live_block`, `malloc`; mappings resolved (`/data/smoke102/app/memprobe`, `/usr/lib/libc.so.6`, preload .so); 12 frames unnamed (`""`) with `symbol_set_id = NULL` → deep stack not symbolized |

Attempt-1 note: with `OBSERVE_S=20` and a program lifetime of 20.85 s the script
returned **rc=6 "test process exited during observation; window incomplete"**.
The check happens after the 2 s startup guard + producer wait + the 20 s
observation sleep, so the target had already exited by then. This is the
intended strictness (no silent pass), not a skill defect; attempt 2 re-ran with
a longer program hold and passed.

Excerpts: `hostwork/captures/s2/heap.pftrace` (43,576 B), `heap.query.txt`,
`heap.app.log` (`SUMMARY ... alloc_calls=44 free_calls=44`), `sql_out/s2_*.txt`.

**S2 = PASS** for the necessary checks (collection + attribution + parse +
stats). Temporal live curve and UI are UNKNOWN, as explicitly allowed.

## 4. S3 — error paths and error propagation

| # | Check | Result | Evidence | Level |
|---|---|---|---|---|
| 1 | config target name ≠ launched program | PASS | `validate_config.py --deploy-name cam-service` → `[FAIL] deploy-name: ... not in config targets ['memprobe']; ... BLOCKING_INIT may hang`, **exit 1** | static (frozen tool, real config) |
| 2 | `duration_ms` too small → reject **before** capture starts | PASS | `ERROR: duration_ms=10000 < OBSERVE_S=30s + 30s margin (min 60000)`, **exit 2**; no tracebox/memprobe started; no new pftrace | board actual |
| 3 | normal capture timeout → non-zero + `TIMEOUT_STOPPED` | PASS | `linux_trace_session.sh` with `TIMEOUT_S=5` on a 15 s config: `TIMEOUT_STOPPED size_bytes=24947`, **exit 10**; partial `.pftrace` kept; no leftover tracebox | board actual |
| 4a | SCP failure (missing remote file) | PASS | `PULL FAIL: scp root@...:nonexistent_file.bin`, **exit 1** | host actual |
| 4b | empty file pulled | PASS | `PULL FAIL: .../empty_probe.bin missing or empty`, **exit 1** | host actual |
| 5 | missing skill resource → `--check-resources` non-success | PASS | copy of candidate with `sql/12-cpu-spike-episodes.sql` removed → `[UNKNOWN] resources: cannot complete resource check: sql/12-cpu-spike-episodes.sql`, **exit 2**; intact candidate → `[PASS] resources: 33 required files + 10 configs readable`, exit 0 | static, offline |
| — | candidate's own pytest suite | **UNKNOWN** | `python3 -m pytest tests -q` → `No module named pytest` (exit 1) on the host; not a candidate failure | host |

Minor observations (not failures, no action taken):

- `--check-resources` reports a missing file as `[UNKNOWN]` with exit 2 rather
  than `[FAIL]` with exit 1. It is still non-success and names the missing file,
  which satisfies the requirement; the label/exit-code split is a polish item.
- `linux_heapprofd_session.sh` validates `duration_ms` before deleting previous
  `$OUT.*` files (as documented), so a stale `heap.pftrace` can remain in the
  workdir after a rejected preflight. Callers must trust the exit code, not the
  file presence.
- `host_pull.sh` calls bare `scp`; it assumes pre-established SSH auth. On this
  board (password-only, no sftp) it needed a test-harness `scp` wrapper. This is
  an environment assumption, not a script bug; the frozen script was not edited.

**S3 = PASS** — errors are propagated, not swallowed; no failure was reported
as PASS.

## 5. Four-level acceptance summary

| Level | S1 | S2 | S3 |
|---|---|---|---|
| Schema | PASS (runtime); v57.1 descriptor UNKNOWN | PASS (deploy-name/duration/runtime); v57.1 descriptor UNKNOWN | PASS |
| Runtime | PASS | PASS | PASS (all 5 error paths) |
| Data | PASS (bounds/process/sched/counters/stats/loss) | PASS (UPID/heap/dumps/allocation/stats); temporal window UNKNOWN | n/a |
| Analysis/UI | PASS (SQL 11/12) | Attribution PASS; symbolization partial; UI UNKNOWN | n/a |

## 6. Key numbers (for reviewers)

- S1: trace 14.609 s, 73,088 B; 1532 sched_switch / sched_slice; 30 sys-mem
  samples per counter; 0 data-loss stats; `dd` 9999.51 ms CPU; SQL 11 = 101
  buckets (100 ms); SQL 12 = 1 episode 11 s / peak 999.96 ms.
- S2: trace 43,576 B, 28.467 s; UPID 190, heap `libc.malloc`; 44 samples;
  allocation 28 MiB total = 20 MiB churn + 8 MiB live; 14 raw dumps all with the
  same timestamp → 1 analyzable dump with `dur=0`; 0 error/loss stats.
- S3: exits observed: 1 (name mismatch), 2 (short duration), 10 (timeout
  `TIMEOUT_STOPPED`), 1 (scp missing), 1 (empty file), 2 (missing resource).

## 7. Minimal fix suggestions (no frozen code changed)

1. **Release process**: push `perfetto-memory-debugging-v1.0.2-rc1` to
   `0fa17e08...` (or publish an equivalent annotated tag). Until then the tag is
   UNKNOWN and only the commit is verifiable.
2. **Collector/analyzer pairing**: for heapprofd timelines, the v57.1 collector
   in this build does not advance per-dump timestamps; v58.2 then shows one `dur=0` dump. This
   is a collector-version limitation already documented by `sql/10` and
   `references/02-native.md`; to get a heap timeline, pair a v58.x tracebox with
   the v58.2 analyzer (skill text already says analyzer upgrade ≠ collector
   upgrade). No skill source change required.
3. **Optional doc clarification**: state that the *test program's* lifetime must
   also exceed `OBSERVE_S` (not only `duration_ms ≥ OBSERVE_S + 30 s`), because
   the session script fails with rc=6 when the target exits early.
4. **Optional**: make `--check-resources` return exit 1 `[FAIL]` (not
   `[UNKNOWN]`) for a missing file; and have `host_pull.sh` document that it
   requires pre-established SSH auth (or accept an SSH wrapper via env).

## 8. Safety / cleanup compliance

- No kernel, driver, DT, boot service, sysctl, SELinux or global Perfetto config
  change; `tracing_on`, `buffer_size_kb`, `current_tracer` were only read.
- No `pkill`; only PIDs created by this test were signalled (app/tracebox of the
  current session), and the scripts' own cleanup did it.
- Existing stale `/tmp/perfetto-*` socket files were detected as ownerless
  (no `/proc/net/unix` entry, no process) before use; no foreign service was
  terminated. They were left in place.
- All board test files lived in `/data/smoke102/` (tmpfs, ≤ ~4.4 MiB) and were
  removed: `/data` back to 0 used, 0 leftover trace/probe processes.
- Frozen candidate untouched (`git status` clean at the end).

## 9. Deliverables in this directory

- `SMOKE_REPORT.md` (this file)
- `ENVIRONMENT.md` — live board/host environment facts
- `COMMANDS.md` — commands actually run with exit codes
- `logs/` — survey, session, pull, error-path, environment logs
- `sql_out/` — SQL used (frozen originals + parameterized copies) and raw TP output
- `hostwork/captures/` — pulled traces (`.pftrace`), status/log files
- `hostwork/artifacts/` — raw trace text used to count heapprofd dumps
- `checksums.txt` — SHA-256 of commit, configs, traces, outputs
- `bin/scp` — test-harness wrapper used only to make the frozen `host_pull.sh`
  run on a password-auth board (documented above)

No `.pftrace` is being uploaded anywhere; traces stay in this test record.
