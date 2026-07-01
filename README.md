# shine-zentao-sync

[![skills.sh](https://skills.sh/b/renguifeng/shine-zentao-sync)](https://skills.sh/renguifeng/shine-zentao-sync)

一个 [Claude Code Skill](https://skills.sh/)：在「提交推送代码」时自动上报禅道工时，支持手动记非编码工时（会议/调研/测试）、多任务切换、token 与代码行的**本地统计**及回显、跨天汇总。后端走 [Claude2Zen](https://github.com/) 服务。

纯 shell（bash + curl + openssl + git + awk），零 Python 依赖。

## 功能

- **commit 上报**：commit 前总结改动 + 采集代码行数 → 上报禅道工时（status=sync）。
- **手动记工时**：非编码工作（会议/调研）事后记，支持 `--date` 补录。
- **多任务**：一个项目多个禅道任务，随时 `task use` 切换；统计按任务/日期聚合。
- **token 统计**：Stop hook 解析 transcript 增量采集，归属当前任务，**只记本地**。
- **代码行统计**：每次 commit 的 insertions/deletions/files，记本地。
- **统计回显**：`zentao stats` 表格展示 token / 工时 / 代码行（today/week/all，按任务）。
- **任务查询**：`zentao query` 列执行/任务、查详情（走后端 GET，canonical HMAC 签名）。
- **全局账号**：禅道账号密码存 `~/.claude/zentao.conf`，跨项目共用。

## 安装

```bash
# 标准安装（skills.sh 生态，GitHub owner/repo 短链）：
npx skills add renguifeng/shine-zentao-sync
npx skills add -g renguifeng/shine-zentao-sync     # 用户级（~/.claude/skills/）
npx skills update                                   # 更新已装 skill
# 也支持任意完整 git URL（GitHub/GitLab/Gitea 等）：
#   npx skills add https://github.com/renguifeng/shine-zentao-sync.git
```

安装位置取决于方式：`skills add` 默认装到 `.agents/skills/shine-zentao-sync/`（或按 `--agent`），
手动拷贝可放 `.claude/skills/`。跑 `npx skills list` 确认实际路径——settings.json 里的 hook
命令与流程示例里的脚本路径都以该路径为准（脚本靠自身位置定位 `lib.sh`，放哪都能跑）。

## 配置（3 步）

1. **配全局账号**（写 `~/.claude/zentao.conf`，chmod 600）：
   ```bash
   zentao setup --account <禅道账号> --password <密码> --secret <与后端一致的密钥> \
                [--host localhost --port 9998 --project <项目名>]
   ```
   （`zentao` 在 `.claude/skills/shine-zentao-sync/scripts/zentao`。）
2. **接 hook**：把 SessionStart + Stop hook 片段粘进 `.claude/settings.json`（见 [`SKILL.md`](SKILL.md#流程-d配置引导首次)）。
3. **重开会话**：env 在会话启动时加载。

> 项目级后端覆盖可选：`$PROJECT/.claude/zentao/project.conf`（模板见 [`templates/project.conf.example`](templates/project.conf.example)）。
> 也兼容旧 `.claude/settings.local.json` 的 env（`ZENTAO_*`/`WEBHOOK_*`）与项目根 `.env`。

## 用法

```bash
zentao task add 77563 shine 扩展 --alias skill
zentao task use skill
# commit 时（由 Claude 在「提交推送代码」触发）：
bash .claude/skills/shine-zentao-sync/scripts/commit_sync.sh "1. 改 A\n2. 修 B"
# 手动记工时：
zentao log 1.5 "需求评审会"
# 看统计：
zentao stats
# 查任务：
zentao query tasks --execution 1234
```

完整流程、触发词、命令速查见 [`SKILL.md`](SKILL.md)。

## 数据口径

- **工时**：当前任务「上次上报→现在」墙钟时长，clamp 0.01–8h/次，跨天取 `min(墙钟, 当天已过)`。
- **token**：本地 entries.jsonl，不进禅道（来自 transcript 的 input/output/cache tokens）。
- **代码行**：commit 时 `git diff --shortstat`。
- 本地数据在 `$PROJECT/.claude/zentao/`（gitignore），全局账号在 `~/.claude/zentao.conf`。

## 前提

- 已部署 **Claude2Zen 服务**：`POST /api/webhook/claude`（写工时）+ `GET /api/executions|tasks|tasks/{id}`（查询）。
- `WEBHOOK_SECRET` 客户端与服务端一致。

## 结构

```
scripts/
  lib.sh             公共库（配置/路径/JSON/HMAC/webhook/token/diff/聚合）
  zentao             CLI 入口（setup/task/sync/log/stats/query）
  hook_session.sh    SessionStart：初始化 store + 迁移旧状态
  hook_stop.sh       Stop：增量采集 token
  commit_sync.sh     commit 入口（采集行数 → zentao sync）
SKILL.md / README.md / templates/ / .gitignore
```
