# 使用演练：从问题到交付

这些是教学配方与预期判读，不是本包在X5/Android上采出的实验结果。最终应用时由Agent填入真实设备、UPID与版本。

## 例一：X5某次相机卡顿，怀疑匿名内存瞬时暴涨

先验证的假设：“故障窗口有目标RSS快速上涨，并伴随内存管理/线程延迟”。不是预设“尖峰就是掉帧根因”。

确认实际相机流是否运行、目标进程与帧事件可用。用户先前报告真实camera/CMA尚未验证，不把旧memprobe实验算成相机负载结果。

【主机】根据目标事件文件生成：

```bash
python3 scripts/make_config.py kernel-pressure --platform linux \
  --events available_events.txt --sched --duration-ms 10000 > camera-memory.pbtxt
```

它会组合基础RSS/system counters、存在的rss_stat与压力/CMA事件及sched。配置可生成不表示cam/isp厂商事件存在。按05-platforms的流程推送采集，另终端起已获准的业务复现，拉回trace、日志、实际配置和帧标记。

【验收与UI】先inventory找到cam-service真实UPID；运行RSS时间线和kernel marker SQL，再加入已有业务帧轨道。选择一段包含正常帧、异常帧、恢复期的时间。对疑似CMA分配按实际format正确配对；没有可配对字段时只显示标记。

【判读】RSS尖峰但无回收/规整/分配阻塞，只能说明占用变化；CMA重试与帧间隔异常同窗是更值得追的线索，但仍需相关线程分配耗时。没有RSS上涨而CMA分配异常时，转设备buffer路径，不反复要求heapprofd解释不存在的malloc。

### 先验证尖峰观测能力

主机编译或用SDK交叉编译器编译：

```bash
cc -g -O1 -fno-omit-frame-pointer -fno-optimize-sibling-calls \
  examples/memprobe.c -o memprobe
# ARM64版本必须改用对应SDK编译器；用file/readelf确认，不把上述主机产物推到X5
```

目标机仅在有余量且允许测试时：

```bash
/data/memprobe spike 16 150 6 > /data/memprobe.log
```

默认从小量验证，不能为追求明显曲线直接占满板端。16MiB的升降只是测试动作；分配器是否保留页面、实际驻留和基线会影响RSS形状，预期不是每个点必须完全等于16MiB。需更明显且可控的释放时可用direct mmap模式并明确它不属于malloc heap测试。

不要宣称150ms一定落入轮询盲区。程序日志使用CLOCK_MONOTONIC；与trace时钟/业务时钟关联后再比较，不能拿日志纳秒不经检查直接当Perfetto内部ts。

## 例二：cam-service慢慢变大，想知道哪段代码分配

先问/检查：能否在测试环境重启、SDK heap组件是否已证明可用、是否有匹配符号。若只能拿到当前RSS但不能重启且进程未preload，先输出smaps分流与明确局限，不伪造运行时注入。

先用独立memprobe走05-platforms的Linux/X5流程。目标名称选memprobe，30秒采集、5秒dump；程序：

```bash
/data/memprobe heap 16 6000 2
```

预期：两次`allocate_live_pool`分配并触页，持有到程序结束前统一free。Native图上应能归因到该函数；绝对采样量可能含libc启动/stdio开销，不要求与RSS逐字节相等。此程序最终全部释放，不能把中间Unreleased增大当成真正泄漏。

验收后再对真实业务选择cam-service名称，以相同“开始采集→业务操作→清理→下一轮”的流程抓取。查看Unreleased和Total两类指标、保持UPID与时间窗口一致；有明确不该存活的路径后才能形成修改建议。

## 例三：Android页面退出后Activity仍存在

使用java-graph，不使用ART allocation的累计曲线当泄漏证据。确认API>=30和app权限，基线/多次打开关闭后的相同阶段分别取graph；在Explorer定位应已退出的实例，通过root/dominator路径查看实际持有者。需要定位“谁创建了大量对象”时才另采java-alloc；两者互补但不互相替代。

## 例四：UI想看重复字符串或相同图片

问题是内容去重，不只总占用。确认HPROF输入与设备am dumpheap参数。没有内容时，直接说明graph无法回答重复文本/像素，给出03-managed的完整dump路线。打开Explorer的Strings/Bitmaps，看内容与引用；大对象或同尺寸不是重复的证据。

## 给Agent的一条标准使用请求

> 使用perfetto-memory-debugging。目标是Linux ARM64设备，/只读、/data可写且是tmpfs，无外网和Python。目标进程cam-service，现有tracebox版本是57.1。我怀疑一次短时内存上涨导致掉帧。先只读确认能力，给出完整配置、主机/板端命令、数据验收SQL和Perfetto UI轨道操作；没有验证的条件单独列出，不要重启现有业务。

另外可以直接说“用这个Skill分析我提供的trace”，此时先读实际trace与现有配置，不先要求重新采集。若现有数据不足，只指出缺失的决定性数据源并提出最小补采。
