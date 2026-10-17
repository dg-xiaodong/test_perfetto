# UI 证据与状态

## 已完成

`ui_loaded_partial.png`：真实 headless Chrome 打开 https://ui.perfetto.dev/（stable v58.3），
通过页面 **Open trace file** 上传本次真实 `traces/heap.pftrace` 后的一次成功加载截图。

截图可核对：

- 当前 trace：`heap.pftrace (1 MB)`
- `Start: 08:26:25.076 047 696`、`Duration: 48s 951ms 756µs 149ns`，与 `sql/00` 的
  `trace_bounds`（48.951756 s）一致；
- 轨道列表包含目标 **`/memphase 3127`** 与 preload fork 的辅助进程 `/memphase 3130`；
- 底部已出现 “Native heap profile” 面板（未选中 profile slice，所以显示 root 0 B）。

这是一张**真实 UI 渲染**截图，不是模拟图；但它只证明“真实 trace 能在 UI 打开并识别目标进程”，
**不**覆盖 RSS 曲线、火焰图和 SQL Debug Track 三项。

## 未完成（UI_UNKNOWN）

多次尝试自动展开 `/memphase 3127`、定位 RSS 轨道、点击 heap profile slice、在 Query 页面创建
Debug Track；由于无外网加速环境下 8.2 MB 前端 bundle / wasm 加载不稳定，只有一次成功加载，
展开与点击未能可靠生效。按任务要求停止重试，未取得两张关键视图，UI 总体标 **UNKNOWN**。

## 本机手动打开与核查清单

见 `../VISUAL_REPORT.md` 第 8.3 节，含每步的预期数值（RSS 两段平台、profile 切片位于
trace ≈ 4.638 s、火焰图应出现 `phase_a`、SQL Debug Track 的两条 SQL）。如 UI 读数与 SQL
不一致，以 Trace Processor v58.2 的 SQL 结果为准，并记录 UI 版本（v58.3）。
