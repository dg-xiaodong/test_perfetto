# ENVIRONMENT — RDK X5 Smoke Test, perfetto-memory-debugging v1.0.2 RC

All values below were read from the live device/host during this test run
(2026-10-17, board boot `up 7:3x`). Historical values from earlier sessions are
listed separately as "baseline claim / not authoritative".

## 1. Host (Ubuntu / WSL2)

| Item | Value |
|---|---|
| uname | `Linux <HOSTNAME> 6.18.40.1-microsoft-standard-WSL2 #1 SMP PREEMPT_DYNAMIC Fri Jul 31 22:12:15 UTC 2026 x86_64` |
| Distro | Ubuntu 22.04.4 LTS |
| CPU arch | x86_64 |
| OpenSSH client | OpenSSH_8.9p1 Ubuntu-3ubuntu0.18 |
| sshpass | 1.09 (password auth for the board, test-only) |
| Python | 3.10.12 (no pytest installed) |
| Trace Processor | `<TRACE_PROCESSOR_DIR>/trace_processor_shell` — **Perfetto v58.2-add693d8b** |
| Test record root | `<TEST_RECORD>/` (outside the frozen candidate) |

## 2. Target board (RDK X5)

| Item | Value |
|---|---|
| Reachability | `<BOARD_IP>` ping OK, SSH OK, SCP OK (legacy protocol, no sftp) |
| uname | `Linux buildroot 6.1.83-DR-PL5.1_V1.0.20 #3 SMP PREEMPT Mon Aug 24 21:03:38 CST 2026 aarch64 GNU/Linux` |
| `/etc/version` | `LNX6.1.83_PL5.1_V1.0.20_20260824-2105` |
| CPU | 8 cores (`nproc`) |
| RAM | `MemTotal: 1336028 kB` (~1.27 GiB) |
| C library | glibc 2.35 (Arm), `/lib/ld-linux-aarch64.so.1` |
| Python on board | **absent** (`python3: none`) |
| `timeout`, `dd`, `od`, `ldd`, `strace`, busybox | present (`/usr/bin/...`) |
| `tracebox` in PATH | absent (deployed by this test to `/data/smoke102/`) |
| `perf_event_paranoid` | `2` (read-only check; not changed) |
| `kptr_restrict` | `0` (read-only check; not changed) |

### 2.1 Mounts / writability / budget

| Mount | Type | Options | Size/usage |
|---|---|---|---|
| `/` | ext4 | `ro,relatime` | 133M, 100% used |
| `/data` | tmpfs | `rw,relatime` | 668012 KiB total; **0 used after cleanup**, max ~4.4 MiB during test |
| `/userdata` | ext4 | `rw,relatime` | 28G, ~26G free (not used for artifacts in this run) |
| `/tmp` | tmpfs | `rw` | used by tracebox system sockets |
| `/dev/shm` | tmpfs | `rw,mode=777` | used by heapprofd shared memory; empty before/after |
| `/usr/hobot` | ext4 | `ro,noatime` | not touched |
| `/app` | ext4 | `rw` | not touched |
| tracefs | tracefs | `rw` | `/sys/kernel/debug/tracing` |

All test files were written only under `/data/smoke102/` (tmpfs, ~4.4 MiB peak,
including the 3.0 MiB tracebox + 1.0 MiB preload + 2 traces); everything was
removed after the test. Rootfs, `/usr/hobot`, `/app` and system settings were
never modified.

### 2.2 tracefs state (as found, unchanged)

| Item | Value |
|---|---|
| tracefs path | `/sys/kernel/debug/tracing` (the `/sys/kernel/tracing` alternative is not mounted) |
| `available_events` | 1170 events; `sched:sched_switch` present; `kmem:rss_stat` present; `cma:*` present |
| `current_tracer` | `nop` |
| `tracing_on` | `1` |
| `buffer_size_kb` | `1410` (pre-existing state; **not** reset) |
| `available_tracers` | `function_graph function nop` |

### 2.3 Existing Perfetto sockets (pre-test)

`/tmp/perfetto-consumer` and `/tmp/perfetto-producer` socket files existed with
mtime at boot, but `/proc/net/unix` had **no** perfetto entries and `ps -ef` had
**no** perfetto/traced/tracebox process. They were therefore stale files, not a
live service. The frozen heapprofd script's `--system-sockets` autostart mode
re-bound them successfully; no foreign service was stopped or overwritten.
Stale files remain after the test (no owner); they were not deleted because they
pre-dated this test.

## 3. Collector / preload used on the board

| Item | Value |
|---|---|
| `tracebox` | ARM64 ELF, **Perfetto v57.1-c59f57dd4**, build from `<SDK_ARM64>/` |
| tracebox SHA-256 | `58f44bbb430d1bf955a5216e2660cc45c03d877c0cba6a01c53307caee8c57f3` |
| preload | `libheapprofd_glibc_preload.so`, same build series, **v57.1-c59f57dd4** |
| preload SHA-256 | `d8fde29ca20fb0398a6002ffa9b9523653d2ef2c03ed757d23e0d57bf7c417c1` |
| tracebox `ldd` | all resolved: libpthread, librt, libdl, libm, libgcc_s, libc, ld-linux-aarch64 |
| preload `ldd` | all resolved (same set); warning only because the `.so` has no exec bit |
| Board-side capture dir | `/data/smoke102/` (deployed binaries/scripts) and `/data/smoke102/work/` (outputs); removed after test |

## 4. Test program (S2)

| Item | Value |
|---|---|
| File | `/data/smoke102/app/memprobe` (deployed from `memprobe_arm64`, chmod +x) |
| Provenance | existing `memprobe` from `<MEMPROBE_DIR>/memprobe_arm64` (reused, not rebuilt) |
| Format | ELF 64-bit ARM aarch64, **dynamically linked**, interpreter `/lib/ld-linux-aarch64.so.1` |
| `DT_NEEDED` | `libc.so.6` only |
| Max GLIBC symbol | `GLIBC_2.34` (board has 2.35) |
| Build ID | `26b6759f454caf5b89bff494d03513943fc2bf31` (not stripped, debug_info) |
| Control run (no preload) | `./memprobe live 1 500 0` → rc=0, alloc 1 MiB / free 1 MiB |
| S2 run | `./memprobe both 8 16000 512 40 20 12000` → 8 MiB live + 40×512 KiB churn, 44 alloc/free calls |

## 5. Version-mismatch notes vs. historical baseline

| Historical claim | Live value | Action |
|---|---|---|
| Kernel 6.1.83 | 6.1.83-DR-PL5.1_V1.0.20 | matches kernel line, build differs (newer image) |
| glibc 2.35 | 2.35 | matches |
| board tracebox v57.1 | v57.1-c59f57dd4 | matches |
| host TP v58.2 | v58.2-add693d8b | matches |
| `/data` writable tmpfs | 668012 KiB tmpfs | matches |
| board has no Python / no internet | confirmed no python3; no network use from board | matches |
| rootfs read-only | `/` ext4 ro | matches |

The board hostname/version value (`V1.0.20_20260824-2105`) differs from the
`V1.0.12` / `V1.1.1` values recorded in earlier notes; the live value above is
authoritative for this report.
