# Futex：可选补证

来源 S1 附录、S7。这不是“看到 futex 就识别出 mutex/owner”的路线。

仅在已知等待与同步有关、缺少 syscall 证据时启用。先核对采集器对应版本的 `FtraceConfig.syscall_events`、目标支持的 raw syscall 事件和架构映射。生成器支持 `--with-futex`，要求显式传入含 `raw_syscalls:sys_enter/sys_exit` 的事件清单；仍须同版本 schema/runtime 验证。

`09-futex-slices.sql` 列出目标 UTID 的 futex syscall slice。syscall 持续时间、睡眠时间、Runnable 时间、锁持有时间四者不相等；同一地址还可能复用，不直接将地址当成永久锁身份。

FUTEX_WAIT 可以超时、受信号影响或被唤醒后仍需重查条件；明确返回码与业务条件才能判断为什么结束。跨进程测试必须用共享内存及非 PRIVATE futex。没有参数/返回值/对象证据，保持等待类别而非具体业务原语的结论。

本版没有在 X5 验证 syscall tracing；可选路线失败不影响已有 E1 状态分析，不放宽权限或改内核来凑 PASS。
