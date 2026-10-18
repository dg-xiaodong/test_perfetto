# C1/C2/C3 有界测试程序

`schedprobe.cpp` 是构造窗口用的源码，不是答案盲测材料。主机本机构建：

```sh
g++ -std=c++17 -O1 -g -pthread -fno-omit-frame-pointer -fno-optimize-sibling-calls \
  -Wl,--build-id=sha1 -Wall -Wextra examples/schedprobe.cpp -o /tmp/schedprobe
/tmp/schedprobe c1 0 30 1
```

上 X5 使用实际 SDK 的 aarch64 C++ 工具链，核对架构、glibc/libstdc++依赖、Build ID；保留未strip符号。不默认加-static，不注入heapprofd。编译器/板端链接是否可用需实际验证。

参数：`c1|c2|c3 [start_delay_ms=3000] [hold_ms=100] [cycles=3]`。

- C1：worker通过条件变量等主线程；日志 WAIT_BEGIN/WAKE/WAIT_END 是应用侧Ground Truth。用户态打印时间不等于内核调度边界。
- C2：worker和两个竞争者只改变自己的 affinity，在一个允许CPU竞争。worker用线程CPU时间预算计算；日志CPU/墙钟差不直接判Runnable，必须由trace验证。该模式 hold_ms不控制竞争窗口，竞争窗口固定200ms，最多5轮，非持续压力。
- C3：父进程在共享mmap中的futex上唤醒子进程，不用FUTEX_PRIVATE。只fork一次，目标TID在多轮中保持。父子PID与事件日志可核对。

程序打印THREAD_READY后开始延迟窗口，构造Agent可只读取得实际TID，生成block/wake配置后启动采集；3秒可能不足部署，允许设置≤8秒或预先部署配置工具。更稳妥是先部署工具，再启动样例并及时采集，不承诺一定覆盖启动期。默认程序只跑有限轮，退出后TID不能再用于下一次配置。

每次测试要保存二进制哈希、版本、参数、进程/TID、实际返回码与日志，不把期望时长当实测。主机C1/C3 smoke只证明样例程序基本运行，不证明事件栈在X5可采、可展开或可关联。
