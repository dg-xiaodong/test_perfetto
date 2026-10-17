# COMMANDS — actual commands run (with exit codes)

Working context:

- `CAND=<REPO_CLONE>/v2_modify/candidate-v1.0.2` (frozen; never modified)
- `B=<TEST_RECORD>` (this test record; all generated files stay here)
- `BOARD=<BOARD_IP>` (root SSH; password redacted below, test-only credential)
- The board has no sftp subsystem and no key auth, so every `scp` call used
  legacy protocol + password. The frozen `host_pull.sh` calls bare `scp`, so a
  **test-harness wrapper** was placed first in `PATH` (`$B/bin/scp` = `sshpass -e
  /usr/bin/scp -O ...`; the board password is exported as `SSHPASS` only for the
  duration of the pull). The frozen script itself was not edited.
- "exit" below is the shell exit status actually observed.

## 0. Version freeze verification (host, static)

| # | Command | Exit |
|---|---|---|
| 0.1 | `git -C <REPO_CLONE> remote -v` → `origin git@github.com:dg-xiaodong/test_perfetto.git` | 0 |
| 0.2 | `git ls-remote origin` → `0fa17e08eb8b93a9944232e380c7ddb39666fcf2 HEAD`, `... refs/heads/main` | 0 |
| 0.3 | `git ls-remote --tags origin` → **no output, 0 lines** (tag `perfetto-memory-debugging-v1.0.2-rc1` not on remote) | 0 |
| 0.4 | `git -C .../test_perfetto_push rev-parse HEAD` → `0fa17e08eb8b93a9944232e380c7ddb39666fcf2` | 0 |
| 0.5 | `git -C .../test_perfetto_push status --porcelain \| wc -l` → `0` (clean) | 0 |
| 0.6 | Python: verify every `MANIFEST.json` SHA-256 against files (77 entries) → `ok 77 missing 0 mismatch 0` | 0 |
| 0.7 | `git -C .../test_perfetto_push status --porcelain \| wc -l` after the whole test → `0` | 0 |

Conclusion: frozen commit = `0fa17e08...`; remote main is the same commit at
test time; **the RC tag is absent** → tag existence UNKNOWN, commit pinned.

## 1. Host preparation

| # | Command | Exit |
|---|---|---|
| 1.1 | `mkdir -p $B/{logs,hostwork/{cfg,captures,artifacts},sql_out,bin,checksums}` | 0 |
| 1.2 | `sha256sum $SDK/tracebox $SDK/libheapprofd_glibc_preload.so > $B/checksums/collector_artifacts.sha256` | 0 |
| 1.3 | create `$B/bin/scp` wrapper (`sshpass -e` + `scp -O`), `chmod +x` | 0 |

## 2. Board reachability and environment (read-only)

| # | Command (board side unless noted) | Exit |
|---|---|---|
| 2.1 | `ping -c1 -W2 <BOARD_IP>` (host) | 0 |
| 2.2 | `ssh ... root@<BOARD_IP> 'echo OK; uname -a; cat /etc/os-release'` | 0 |
| 2.3 | `mount`, `df -h`, `uptime`, `ps -ef`, `ls /tmp` | 0 |
| 2.4 | `cat /proc/sys/kernel/perf_event_paranoid`, `kptr_restrict`, `/proc/meminfo`, `nproc` | 0 |
| 2.5 | `/lib/libc.so.6 \| head -1` → glibc 2.35 | 0 |
| 2.6 | `wc -l < /sys/kernel/debug/tracing/available_events` → 1170; `grep sched:sched_switch`; `cat current_tracer` → `nop` | 0 |
| 2.7 | `command -v perfetto tracebox python3` → none | 0 (expected non-zero per lookup) |

## 3. Deploy collector + scripts (board `/data/smoke102/`)

| # | Command | Exit |
|---|---|---|
| 3.1 | `ssh ... 'mkdir -p /data/smoke102/work'` | 0 |
| 3.2 | `sshpass -p <pw> scp -O <tracebox> <preload> <survey.sh> <linux_session_lib.sh> <linux_trace_session.sh> <linux_heapprofd_session.sh> <memprobe_arm64> root@<BOARD_IP>:/data/smoke102/` | 0 |
| 3.3 | `ssh ... 'chmod +x /data/smoke102/tracebox /data/smoke102/memprobe_arm64 /data/smoke102/*.sh; ls -l'` | 0 |
| 3.4 | `tracebox --version` → `Perfetto v57.1-c59f57dd4`; `ldd tracebox`; `ldd libheapprofd_glibc_preload.so` | 0 |

Note: the first `scp` attempt failed (not prefixed with `sshpass`, and the board
has no sftp): exit 1 / "lost connection". Re-run with `sshpass ... scp -O` → 0.

## 4. S1 — normal trace

| # | Command | Exit |
|---|---|---|
| 4.1 | board `sh /data/smoke102/survey.sh` → `$B/logs/survey_report.txt` | 0 |
| 4.2 | board `sh /data/smoke102/survey.sh --events` → `$B/logs/board_available_events.txt` (1170 events) | 0 |
| 4.3 | host `python3 scripts/make_config.py overview --platform linux --events board_available_events.txt --duration-ms 15000 --poll-ms 500 --sched > hostwork/cfg/s1_overview_sched.pbtxt` | 0 |
| 4.4 | host `python3 scripts/validate_config.py --check-resources <cfg>` → `[PASS] resources ...` | 0 |
| 4.5 | host `python3 scripts/validate_config.py --descriptor-set <WORKSPACE>/trace_config_v58.2.desc <cfg>` → `[PASS] schema` (v58.2 descriptor, supplementary; board collector is v57.1) | 0 |
| 4.6 | preflight capture (no workload): board `WORK=/data/smoke102/work TRACEBOX=/data/smoke102/tracebox sh linux_trace_session.sh <cfg> /data/smoke102/work/s1 60` → `DONE size_bytes=74538`, `SCRIPT_RC=0` | 0 |
| 4.7 | host `PATH=$B/bin:$PATH sh scripts/host_pull.sh root@<BOARD_IP> /data/smoke102/work captures/preflight_s1 s1.pftrace s1.log s1.status` | 0 |
| 4.8 | primary capture with controlled workload: board `sh -c "sleep 2; exec timeout 10 dd if=/dev/zero of=/dev/null bs=64k" &` then `WORK=... TRACEBOX=... sh linux_trace_session.sh <cfg> /data/smoke102/work/s1 60` → `DONE size_bytes=73088`, `SCRIPT_RC=0` | 0 |
| 4.9 | host `PATH=$B/bin:$PATH sh scripts/host_pull.sh ... captures/s1 s1.pftrace s1.log s1.status` → `PULL OK` ×3 | 0 |
| 4.10 | host `trace_processor_shell query -f sql_out/s1_summary.sql hostwork/captures/s1/s1.pftrace` (bounds/process/sched/counters/stats/ftrace) | 0 |
| 4.11 | host `sed 's/SELECT -1 AS target_upid/SELECT 194 AS target_upid/' sql/11-cpu-time-buckets.sql > sql_out/11_run.sql`; `trace_processor_shell query -f sql_out/11_run.sql s1.pftrace` | 0 |
| 4.12 | same substitution for `sql/12-cpu-spike-episodes.sql` (UPID 194, 1 s buckets, 100 ms threshold) | 0 |

`dd` workload process: pid 2411, UPID 194; it ran 2 s after capture start for
10 s (`timeout 10 dd ...`), i.e. fully inside the 15 s trace.

## 5. S2 — heapprofd

| # | Command | Exit |
|---|---|---|
| 5.1 | host `python3 scripts/make_config.py native --platform linux --process memprobe --duration-ms 90000 --dump-ms 2000 --sampling 4096 > hostwork/cfg/s2_native_memprobe.pbtxt` | 0 |
| 5.2 | host `python3 scripts/validate_config.py --deploy-name memprobe <cfg>` → `[PASS] deploy-name` | 0 |
| 5.3 | host `python3 scripts/validate_config.py --deploy-name cam-service <cfg>` → `[FAIL] deploy-name` (S3-1 evidence) | 1 |
| 5.4 | host `python3 scripts/validate_config.py --binary memprobe_arm64 <cfg>` → `[PASS] binary ... dynamic ELF (PT_INTERP present)` | 0 |
| 5.5 | board socket/autostart preflight: `tracebox --system-sockets --txt -c s1_overview_sched.pbtxt -o preflight.pftrace --background`; `tracebox perfetto --query --long`; `kill -INT <pid>`; `ps -ef \| grep tracebox` → none | 0 |
| 5.6 | board `./memprobe live 1 500 0` (no preload, control) → rc=0 | 0 |
| 5.7 | board `scp` config to `/data/smoke102/work/` and `cp memprobe_arm64 app/memprobe` | 0 |
| 5.8 | **attempt 1** board `WORK=/data/smoke102/work TRACEBOX=/data/smoke102/tracebox OBSERVE_S=20 sh linux_heapprofd_session.sh <cfg> <preload> /data/smoke102/app ./memprobe "both 8 14000 512 40 20 6000"` → `FAIL: test process exited during observation; window incomplete`, `SCRIPT_RC=6` (program lifetime 20.85 s ≈ observation window; correct strict failure) | 6 |
| 5.9 | pull attempt-1 artifacts with frozen `host_pull.sh` (heap.pftrace/log/app.log/query.txt) | 0 |
| 5.10 | **attempt 2** same command with `OBSERVE_S=25` and `both 8 16000 512 40 20 12000` → `DONE size_bytes=43576`, `SCRIPT_RC=0` | 0 |
| 5.11 | host `PATH=$B/bin:$PATH sh scripts/host_pull.sh ... captures/s2 heap.pftrace heap.log heap.status heap.query.txt heap.app.log` → `PULL OK` ×5 | 0 |
| 5.12 | host `trace_processor_shell query -f sql/00-inventory.sql captures/s2/heap.pftrace` (no params needed) | 0 |
| 5.13 | host `sed 's/SELECT -1 AS target_upid/SELECT 190 AS target_upid/'` for `sql/03-native-live.sql`, `sql/04-native-callstacks.sql`, `sql/10-native-dump-capability.sql`; run each with TP v58.2 | 0 |
| 5.14 | host `traceconv text captures/s2/heap.pftrace > hostwork/artifacts/s2_trace_text.txt`; parsed 14 `profile_packet` dumps | 0 |
| 5.15 | host TP queries: `heap_profile`, `heap_profile_allocation`, `process`, `stack_profile_frame`, heap-related `stats` | 0 |

UI flamegraph: **not opened** (no browser / Perfetto UI in this environment) → UNKNOWN.

## 6. S3 — error paths

| # | Command | Exit |
|---|---|---|
| 6.1 | host `python3 scripts/validate_config.py --deploy-name cam-service hostwork/cfg_used/s2_native_memprobe.pbtxt` → `[FAIL] deploy-name: launched basename='cam-service' not in config targets ['memprobe'] ...` | 1 |
| 6.2 | board `WORK=... TRACEBOX=... OBSERVE_S=30 sh linux_heapprofd_session.sh <s3_short_duration.pbtxt> <preload> /data/smoke102/app ./memprobe "live 8 5000 2000"` → `ERROR: duration_ms=10000 < OBSERVE_S=30s + 30s margin (min 60000)`, `SCRIPT_RC=2`; no tracebox/memprobe started | 2 |
| 6.3 | board `WORK=... TRACEBOX=... sh linux_trace_session.sh <s1 cfg> /data/smoke102/work/s3_timeout 5` → `TIMEOUT_STOPPED size_bytes=24947`, `SCRIPT_RC=10`; no leftover tracebox | 10 |
| 6.4 | host `PATH=$B/bin:$PATH sh scripts/host_pull.sh root@<BOARD_IP> /data/smoke102/work captures/s3_pull nonexistent_file.bin` → `PULL FAIL: scp ...` | 1 |
| 6.5 | board `touch /data/smoke102/work/empty_probe.bin`; host pull `empty_probe.bin` → `PULL FAIL: ... missing or empty` | 1 |
| 6.6 | host `cp -a <candidate> hostwork/candidate_copy_missing_resource && rm .../sql/12-cpu-spike-episodes.sql`; `python3 .../validate_config.py --check-resources` → `[UNKNOWN] resources: cannot complete resource check: sql/12-cpu-spike-episodes.sql` | 2 |
| 6.7 | host `python3 scripts/validate_config.py --check-resources` (intact candidate) → `[PASS] resources: 33 required files + 10 configs readable` | 0 |
| 6.8 | host `python3 -m pytest tests -q` | 1 (no module pytest → UNKNOWN, not a candidate failure) |

## 7. Cleanup

| # | Command | Exit |
|---|---|---|
| 7.1 | board `rm -rf /data/smoke102`; `ls -la /data` → empty (only pre-existing `tee` symlink); `df -k /data` → 0 used | 0 |
| 7.2 | board `ps -ef \| grep -Ei 'tracebox\|traced\|memprobe' \| grep -v grep \| wc -l` → `0` | 0 |
| 7.3 | board `grep -ci perfetto /proc/net/unix` → `0` (only stale socket files in `/tmp`) | 0 |
| 7.4 | host `git -C .../test_perfetto_push status --porcelain \| wc -l` → `0` | 0 |

## 8. Reproduction outline (host + board)

```sh
CAND=<REPO_CLONE>/v2_modify/candidate-v1.0.2
B=<TEST_RECORD>
# 1) regenerate configs exactly
python3 $CAND/scripts/make_config.py overview --platform linux \
  --events $B/logs/board_available_events.txt --duration-ms 15000 --poll-ms 500 --sched \
  > $B/hostwork/cfg_used/s1_overview_sched.pbtxt
python3 $CAND/scripts/make_config.py native --platform linux --process memprobe \
  --duration-ms 90000 --dump-ms 2000 --sampling 4096 \
  > $B/hostwork/cfg_used/s2_native_memprobe.pbtxt
# 2) deploy tracebox+preload+scripts (see §3), run sessions (see §4/§5)
# 3) analyze with TP v58.2 (see §4.10-4.12, §5.12-5.15)
```
