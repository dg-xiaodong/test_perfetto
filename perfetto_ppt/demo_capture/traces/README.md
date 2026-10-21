# 真实 Trace 清单

全部由窗口 B 在 RDK X5（192.168.1.10）上实测采集；板端原始文件保留在
`root@192.168.1.10:/userdata/perfetto-b/out/<name>/trace.pftrace`（`/userdata` 为持久分区）。

| 文件 | 大小 (B) | SHA256 | 采集配置 | 板端原始路径 |
|---|---|---|---|---|
| `overview_system_app.pftrace` | 6,854,816 | `250b95cc59ee0cd170c4f214475df131f4c081d6600cf4401e35a7982c9a225a` | `configs/overview_120s.cfg`（PID 注入后） | `/userdata/perfetto-b/out/overview_120s_v4/trace.pftrace` |
| `sched_blockwake.pftrace` | 2,766,987 | `beadb4f22d536d4170c905e3ba28074863fd609b800a4124a4ddf34a1ed78180` | `configs/blockwake.cfg` | `/userdata/perfetto-b/out/blockwake/trace.pftrace` |
| `light_noperf_60s.pftrace` | 1,577,063 | `b3c6b645ece408494c1a10c907888d5d4e8ed3ae4f9fa92e735b653c9dafd33b` | `configs/light_60s.cfg` | `/userdata/perfetto-b/out/light_60s/trace.pftrace` |
| `overview_system_app_cmdline-filter-variant.pftrace` | 10,655,240 | `c23fc105cc4c956da519c2bd187a70936149bca64fa1b477d4d22f7ad1279355` | `configs/overview_120s.cfg`（target_cmdline 版） | `/userdata/perfetto-b/out/overview_120s/trace.pftrace` |
| `overview_system_app_dup-perf-producer-variant.pftrace` | 14,303,460 | `688d6b85d6de035ab1bcbb0967c26c0affd415fee7a55064c3390d1c9d6eb0d2` | 同上（3 个 traced_perf producer 时） | `/userdata/perfetto-b/out/overview_120s_v2/trace.pftrace` |
| `smoke_noperf_10s.pftrace` | 311,554 | `15d28cc87cd0f12e0ba8f21e597714ce3d702aea892ff6ede121663a0e1ab56b` | `configs/smoke_noperf.cfg` | `/userdata/perfetto-b/out/smoke2/trace.pftrace` |
| `smoke_perf_15s.pftrace` | 891,156 | `f9bb73eb88db866813d0ab12ac4dad4b463c52e3cf7a9b2b535344ba1a466ae5` | `configs/smoke_perf.cfg` | `/userdata/perfetto-b/out/smoke4/trace.pftrace` |
| `smoke_perf_nosource_15s.pftrace` | 395,319 | `438a1c9f1dc4cd0aee074b6eeb8213d3566f67ec7b57d6e590f4a448be4df589` | `configs/smoke_perf.cfg`（无 traced_perf 时） | `/userdata/perfetto-b/out/smoke3/trace.pftrace` |
| `native_heap_heapprofd_unavailable.pftrace` | 658 | `6c4d2cc7a658ae59a7a53bfd0e5544c3b9cd3c2d0a069bd98d7619823ff21b53` | `configs/heaptest.cfg` | `/userdata/perfetto-b/out/heaptest/trace.pftrace` |
| `sched_blockwake.cs.perfdata` | 1,321,608 | `ae693ad2780551da3036af3631303719ec0bffcaa0c1a83b18681370d47416c8` | `perf record -e cs -g -p <app>` | `/userdata/perfetto-b/out/cs.data` |

采集时刻目标进程 pid=1090（`pf-demo-x5`，sha256 `f89d9ed5…c9b5`，build id `48afa3c3…`）。
每次采集的 `env.txt` 记录起止 uptime 与板端 `sha256sum`，与本地一致（`logs/captures/`）。
