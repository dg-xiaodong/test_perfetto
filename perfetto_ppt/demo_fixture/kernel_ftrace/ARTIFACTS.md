# Artifacts used for the recorded kernel-ftrace runs

Binaries are intentionally **not** committed (23 MB Image, 26 MB initramfs).
Rebuild them with `build/build-ftrace-kernel.sh` and
`build/build-kexec-initramfs.sh`; the hashes below identify the exact builds
that produced `logs/kernel-ftrace-full-52s.pftrace`.

| artifact | value |
|---|---|
| tracing kernel Image | sha256 `036d11392ed2df30205efd1824047b31c92e590e06177a6dc828351a5d40cc61`, 23 646 720 bytes |
| kernel release | `6.1.83+` (built from `kernel_ftrace/board.config` + tracing delta) |
| kernel build id string | `#4 SMP PREEMPT Wed Oct 21 21:01:50 CST 2026 aarch64` |
| stock kernel it replaces (only for the kexec boot) | `6.1.83-DR-PL5.1_V1.1.1 #3 SMP PREEMPT Fri Oct 9 21:26:08 CST 2026` |
| initramfs (final, `pf.duration` support + `wc -c` fix) | sha256 `dd549aa8ea892a6a7c22e67c7af54330743b74358a9da4cca3507450919a811e` |
| initramfs (the one used for the committed 52 s trace) | rebuilt later; same init logic except the explicit `pf.duration` cmdline support was already present at capture time |
| kexec loader | sha256 `dd977f5d73798174400b86ca39f274b25a098cbe334e67d4e7a16ab4ed3073ae` |
| stock config base | `kernel_ftrace/board.config` (= board `/proc/config.gz`, diff 0) |
| tracing delta | `kernel_ftrace/config.ftrace.enabled` (33 options, all tracing) |
| trace configs | `kernel_ftrace/trace_full.cfg`, `kernel_ftrace/trace_min.cfg` |

The captured trace itself is `logs/kernel-ftrace-full-52s.pftrace` (sha256
recorded in git history; 9 890 250 bytes when captured).
