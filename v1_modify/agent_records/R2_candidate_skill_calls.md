# R2_candidate — 实际加载/调用记录（从会话记录提取）

- 会话 id：`d54aefe7-7448-411b-a80a-92f3180433dd`；来源：`~/.dsh/sessions/--root-code_1.0.20--/d54aefe7-7448-411b-a80a-92f3180433dd/session.v4.jsonl.zstd`
- 提取方式：`zstd -dc … | 解析 type=="tool/call" 的 name + arguments`；**未含**消息正文与系统提示。
- 原始回答另存：`candidate-v1.0.1/tests/agent_ab/R1_old_skill_raw.md` / `R2_candidate_skill_raw.md`。
- 路径为本机原始路径；仓库内对应关系：`/root/.dsh/skills/perfetto-memory-debugging` → `baseline-v1.0.0/`（内容一致），`/root/code_1.0.20/tmp/skill_candidate/candidate-v1.0.1` → `candidate-v1.0.1/`。

| # | 工具 | 目标（file_path/path/pattern/name/command） |
|---|---|---|
| 01 | `bash` | `find /root/code_1.0.20/tmp/skill_candidate/candidate-v1.0.1 -type f \| head -50; echo "---"; du -sh /root/code_1.0.20/tmp/skill_candidate/candidate-v1.0.1` |
| 02 | `read` | `/root/code_1.0.20/tmp/skill_candidate/candidate-v1.0.1/SKILL.md` |
| 03 | `read` | `/root/code_1.0.20/tmp/skill_candidate/candidate-v1.0.1/references/02-native.md` |
| 04 | `read` | `/root/code_1.0.20/tmp/skill_candidate/candidate-v1.0.1/references/06-quality.md` |
| 05 | `read` | `/root/code_1.0.20/tmp/skill_candidate/candidate-v1.0.1/references/05-platforms.md` |
| 06 | `read` | `/root/code_1.0.20/tmp/skill_candidate/candidate-v1.0.1/references/09-advanced-configs.md` |
| 07 | `bash` | `cd /root/code_1.0.20/tmp/skill_candidate/candidate-v1.0.1; for f in sql/00-inventory.sql sql/03-native-live.sql sql/04-native-callstacks.sql sql/10-native-dump-capability.sql sql/05-native-global-summ` |
| 08 | `read` | `/root/code_1.0.20/tmp/skill_candidate/candidate-v1.0.1/references/08-worked-examples.md` |
| 09 | `bash` | `cd /root/code_1.0.20/tmp/skill_candidate/candidate-v1.0.1; sed -n 1,200p scripts/make_config.py` |
| 10 | `bash` | `cd /root/code_1.0.20/tmp/skill_candidate/candidate-v1.0.1; echo "===== native.pbtxt"; cat configs/native.pbtxt; echo "===== survey.sh"; cat -n scripts/survey.sh; echo "===== validate_config resources ` |
| 11 | `read` | `/root/code_1.0.20/tmp/skill_candidate/candidate-v1.0.1/scripts/validate_config.py` |
| 12 | `bash` | `cd /root/code_1.0.20/tmp/skill_candidate/candidate-v1.0.1; echo "=== 00-routing"; sed -n 1,80p references/00-routing.md; echo "=== 04-ui"; sed -n 1,80p references/04-ui.md` |
| 13 | `bash` | `cd /root/code_1.0.20/tmp/skill_candidate/candidate-v1.0.1; grep -n "v57.1\\|v58" references/*.md \| head -20; echo ---; grep -rn "300\\|窗口\\|held" references/06-quality.md \| head` |
| 14 | `bash` | `cd /root/code_1.0.20/tmp/skill_candidate/candidate-v1.0.1; sed -n 63,84p references/02-native.md; echo "=== md5"; md5sum references/02-native.md; stat -c '%y %s' references/02-native.md` |
| 15 | `send_message` | `` |

共 15 次工具调用。

缺失：未保存逐 step 的模型输入/token 统计；本文件只覆盖工具调用。
