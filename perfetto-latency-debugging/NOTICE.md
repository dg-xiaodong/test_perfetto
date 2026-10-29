# 来源与复用

本包为独立实现的 Agent Skill，不是 Google/Perfetto 官方发布物。Perfetto 商标和上游 SDK 的版权属于原权利人；SDK 保持独立，获取时保留其原始版权/许可头和 SDK_PROVENANCE。

`record.sh`、`pull.sh` 与配方子集 parser/descriptor 校验沿用此前 Scheduling v0.1.0 Candidate 的实现基础。record.sh 专门改为 system sockets，以支持外部 TrackEvent producer，移除 Scheduling 特定 TID 预检。策略校验改为 TrackEvent 配方；其余状态与超时方法沿用。来源包由同一用户此前提供；归档 SHA256 见 docs/REUSE.json。

既往 X5 Scheduling 测试不是本版 TrackEvent 联合采集的验收证据。C++ 示例、业务契约、分析引擎和新增 SQL/测试为本次编写；合成 fixture 不是真实应用 Trace。

不得发布含口令、敏感业务 ID、客户符号或未授权 Trace 的产物。本包不包含任何账号凭据或目标业务日志。
