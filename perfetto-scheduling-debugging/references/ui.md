# 手动 Perfetto UI 配方

本版不做自动浏览器/截图。打开实际 .pftrace；UI随版本改变，以下为操作语义，不承诺按钮位置固定。[S1,S8]

1. 目标线程 Thread State：缩放到慢窗口，看 Sleeping / Runnable / Running，不用颜色代替状态名字。点击等待结束后的Running或对应状态查看 Woken by；用表中UTID/TID核对身份。
2. CPU轨道：同窗查看目标相关核心与竞争线程，别只看进程内部轨道就判整核空闲。
3. 调度事件样本：block/wake 数据存在时点击切出边界/唤醒者对应的调用栈 chevron；区分事件源，查看实际样本而不是全trace聚合火焰图。
4. 可用时 Critical Path Lite 辅助跳转。它不是锁所有权链；IRQ上下文缺失、版本不支持时保持局限。
5. `01b-state-track.sql` 渲染后执行，Add debug track → Slice：ts / dur / state，按utid区分。单位仍为ns。
6. 对选定调用点运行 `06-callstack.sql`，核对叶帧、祖先、mapping、Build ID。UNKNOWN/歧义候选不要绘成确定的因果箭头。

请求日志可转换为对应trace时钟的queue/process片段后添加Debug Track。图必须追溯到实际trace、SQL与时钟转换；没有request边界时不画“业务响应时间”。UI没实际打开就写 UI_UNKNOWN，不声称已验收漂亮图表。
