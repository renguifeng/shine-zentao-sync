---
name: shine-zentao-sync
description: 禅道工时 / Token / 代码行统计与提交工具。触发词——提交推送代码、commit push、上报禅道、记工时、补录工时、开会记录、切换任务、开始做任务、查任务、列任务、找任务、禅道统计、token 统计、用了多少 token、配置禅道。支持多任务切换、手动记工时（会议/调研/测试）、commit 时自动上报、token 与代码行本地统计、跨天汇总、统计回显。
---

# shine-zentao-sync —— 禅道工时与开发统计

commit 时自动上报禅道工时；手动记非编码工时；本地统计每任务的 token / 工时 / 代码行并回显。
纯 shell（bash + curl + openssl + git + awk），后端走 Claude2Zen 服务。

## 何时触发（按意图路由到流程）

| 用户说 | 流程 |
|---|---|
| 提交推送代码 / commit push / 发布代码 | A 提交并上报 |
| 记工时 / 补录 / 开了会记录一下 / 调研花了 2 小时 | B 手动记工时 |
| 切换任务 / 开始做任务 X / 列任务 / 找任务 / 查任务 | C 查询与切换任务 |
| 禅道统计 / 今天用了多少 token / 工时统计 | `zentao stats` |
| 配置禅道 / 第一次用 / 安装 | D 配置引导 |

子命令都在 `zentao` CLI（随 skill 装在 `.claude/skills/shine-zentao-sync/scripts/zentao`）。
下面示例假设已在该路径可执行；全局安装（`skills add -g`）路径前缀改为 `~/.claude/skills/...`。

## 流程 A：提交并上报（顺序不可颠倒：先上报、再 commit）

`git commit` 后工作区 diff 清空，汇总与行数无从生成。

1. `git diff HEAD`（必要时 `git status`）查看改动。
2. 生成**带序号的中文改动汇总**，逐项分点 `1. ……` `2. ……`，每点一句（做了什么 + 关键文件/原因）。多行原样作为禅道备注。
3. 上报（脚本会算工时、采集 `git diff --shortstat` 行数、签名、POST 禅道、写本地记录）：
   ```bash
   bash .claude/skills/shine-zentao-sync/scripts/commit_sync.sh "<上面带序号的多行汇总>"
   ```
   - 也可加 `--task <id>` 指定上报到非当前任务。
   - 上报归属**当前任务**（见流程 C 的 `task use`）。
   - 上报失败**不阻塞**提交（HTTP 非 200 / 服务未起仍继续）。
4. `git add -A` → `git commit -m "<提交信息>"` → `git push`。

## 流程 B：手动记工时（与代码无关）

用于会议、调研、测试等非编码工作。先确认：**工时数**（小时；不填则按「上次上报→现在」墙钟算）、**内容摘要**、**目标任务**（默认当前任务）。

```bash
zentao log 1.5 "需求评审会，确认接口字段"            # 1.5h，记到当前任务
zentao log 2   "调研 token 采集方案" --task 78000     # 指定任务
zentao log 1   "测试上报链路" --date 2026-06-30       # 补录到指定日期
```

- 不算 diff、不计代码行；只记工时 + 备注，上报禅道（status=sync，工日记到 `--date` 或当天）。
- **显式工时不推进计时锚点**（非墙钟工作）；省略工时则按墙钟算并推进。

## 流程 C：查询与切换任务

```bash
zentao query executions                     # 列可见执行（sprint/迭代）
zentao query tasks --execution 1234         # 列某执行下的任务（id/名称/状态/工时）
zentao query task 77563                     # 查单个任务详情
zentao task search 登录                      # 本地任务按关键字搜（也可先 query 拉远端）
zentao task add 77563 shine 全功能 --alias skill   # 注册任务（--alias 便于 use）
zentao task use skill                       # 切换当前任务（接 id 或 alias）
zentao task list                            # 列出已注册任务，* 标当前
```

提交前若要选任务：`zentao task list`（或 `query tasks`）→ 与用户确认 → `zentao task use <id>` → 再走流程 A/B。

## 统计回显

```bash
zentao stats                # 今日（默认）每任务 token/工时/代码行 + 合计
zentao stats --week         # 近 7 天
zentao stats --all          # 全部
zentao stats task 77563     # 仅某任务
```

口径：token 来自本地 Stop hook 采集（只本地，不进禅道）；工时 = sync + manual 条目之和；代码行 = commit 时的 insertions/deletions。

## 流程 D：配置引导（首次）

```bash
zentao setup --account <禅道账号> --password <密码> --secret <与后端一致的密钥> \
             [--host localhost --port 9998 --project <项目名>]
```

写入全局 `~/.claude/zentao.conf`（chmod 600）。再注册首个任务并接 hook。接 hook（粘进目标项目 `.claude/settings.json`）：

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command",
      "command": "bash .claude/skills/shine-zentao-sync/scripts/hook_session.sh" }] }],
    "Stop": [{ "hooks": [{ "type": "command",
      "command": "bash .claude/skills/shine-zentao-sync/scripts/hook_stop.sh" }] }]
  }
}
```

`SessionStart`：初始化 store、迁移旧 `.zentao_session.json`。`Stop`：增量采集 token 归属当前任务。
配置改完**重开会话**生效。

## 配置

- **全局**（账号密码 + 默认后端）：`~/.claude/zentao.conf` —— 多项目共用一份。
- **项目级覆盖**（可选）：`$PROJECT/.claude/zentao/project.conf`（`backend_host`/`backend_port`/`project_name`）。
- 兼容旧 `$ZENTAO_*` / `$WEBHOOK_*` 环境变量（Claude 从旧 `settings.local.json` env 注入）与项目根 `.env`。
- 本地数据（gitignore）：`$PROJECT/.claude/zentao/`（`tasks/`、`sessions/`、`entries.jsonl`、`current`）。

## 工时口径（重要）

工时 = **当前任务「上次上报→现在」的墙钟时长**（÷3600，clamp 0.01–8h/次）。每个任务独立锚点。
跨天时取 `min(墙钟, 当天已过时长)`，避免跨多日报巨值。**墙钟含会话间隔**，禅道工时本为估算；
若中途切任务，间隔会算进切回后的任务——如需精确，多分几次 `log/sync`。详见 `zentao` 源码注释。

## 子命令速查

```
zentao setup [--account --password --secret --host --port --project]
zentao task add <id> [名称] [--execution E] [--alias A]
zentao task use <id|alias> | list | search <关键字>
zentao sync "<汇总>" [--task <id>] [--lines "ins del files"]   # commit 时用 commit_sync.sh 包装
zentao log  [工时] "<内容>" [--task <id>] [--date YYYY-MM-DD]
zentao stats [task <id>] [--today|--week|--all]
zentao query executions | tasks --execution <id> | task <id>
```

## 前提

- 团队已部署 **Claude2Zen 服务**（POST `/api/webhook/claude` 写工时；GET `/api/executions|tasks|tasks/{id}` 供查询）。
- `WEBHOOK_SECRET` 客户端与服务端必须一致（POST 签 body、GET 签 canonical）。
- commit 上报需 git 仓库；token 采集需接 Stop hook。

## 安装 / 更新

```bash
npx skills add <owner>/shine-zentao-sync        # 装到项目 .claude/skills/
npx skills add -g <owner>/shine-zentao-sync     # 装到用户级 ~/.claude/skills/
npx skills update                                # 更新已装 skill
```

详见 [README.md](README.md)。
