#!/usr/bin/env bash
# commit_sync.sh —— 「提交推送代码」时上报禅道的入口（采集代码行数 + 转发 zentao sync）。
#
# 用法（兼容旧调用）：
#   bash .../commit_sync.sh "<改动汇总>"
#   bash .../commit_sync.sh "<改动汇总>" --task <id>
# 本脚本在 commit 之前采集 `git diff HEAD --shortstat`（commit 后 diff 清空），
# 解析 insertions/deletions/files，连同汇总转发给 `zentao sync --lines ...`。
#
# 顺序约束：必须先上报、再 git commit（commit 后 diff 清空，汇总与行数无从谈起）。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

ins=0; del=0; files=0
shortstat="$(cd "$PROJECT_DIR" 2>/dev/null && git diff HEAD --shortstat 2>/dev/null || true)"
if [ -n "$shortstat" ]; then
  f="$(printf '%s' "$shortstat" | grep -oE '[0-9]+ files?' | grep -oE '[0-9]+' | head -1)"; files="${f:-0}"
  i="$(printf '%s' "$shortstat" | grep -oE '[0-9]+ insertions?' | grep -oE '[0-9]+' | head -1)"; ins="${i:-0}"
  d="$(printf '%s' "$shortstat" | grep -oE '[0-9]+ deletions?' | grep -oE '[0-9]+' | head -1)"; del="${d:-0}"
fi

exec bash "$SCRIPT_DIR/zentao" sync "$@" --lines "$ins $del $files"
