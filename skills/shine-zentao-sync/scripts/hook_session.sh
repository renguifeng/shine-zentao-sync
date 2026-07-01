#!/usr/bin/env bash
# SessionStart hook —— 初始化/迁移 store、清理过期会话偏移。
#
# 计时锚点已改为「每任务 last_report_ts/date」（见 lib.sh zz_compute_hours），
# 故此处不再做全局锚点的跨天重置；仅负责 store 初始化、旧文件迁移、session 清理。
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"
zz_paths
zz_ensure_dirs

# 迁移旧 .claude/.zentao_session.json（单任务全局锚点）→ 每任务锚点；幂等。
legacy="$PROJECT_DIR/.claude/.zentao_session.json"
if [ -f "$legacy" ] && [ ! -f "$STORE_DIR/.migrated" ]; then
  last=$(grep -oE '"last_report_ts":[0-9]+' "$legacy" 2>/dev/null | grep -oE '[0-9]+$')
  ldate=$(grep -oE '"date":"[0-9]{4}-[0-9]{2}-[0-9]{2}"' "$legacy" 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
  tid="${ZENTAO_TASK_ID:-}"
  if [ -n "$tid" ] && echo "$tid" | grep -qE '^[0-9]+$'; then
    f="$(zz_task_file "$tid")"
    [ -f "$f" ] || printf '{"id":%s,"name":"迁移自旧会话","execution_id":0,"alias":"migrated","added_ts":%s,"last_report_ts":%s,"last_report_date":"%s"}\n' \
      "$tid" "$(date +%s)" "${last:-0}" "${ldate:-}" > "$f"
    zz_set_current "$tid"
    echo "[hook] 已从旧 .zentao_session.json 迁移任务 #$tid"
  else
    echo "[hook] 发现旧 .zentao_session.json 但无 ZENTAO_TASK_ID，仅归档"
  fi
  mv "$legacy" "$legacy.migrated" 2>/dev/null || rm -f "$legacy"
  : > "$STORE_DIR/.migrated"
fi

# 清理 7 天前的 session 偏移文件
now=$(date +%s); cutoff=$((now - 7 * 86400))
for f in "$SESSIONS_DIR"/*.json; do
  [ -f "$f" ] || continue
  t=$(grep -oE '"last_ts":[0-9]+' "$f" 2>/dev/null | grep -oE '[0-9]+$')
  if [ -n "$t" ] && [ "$t" -lt "$cutoff" ] 2>/dev/null; then rm -f "$f"; fi
done

# 自动同步 /zentao slash command 到用户级（幂等；不改任何环境变量，仅写 ~/.claude/commands/）。
# 装完 skill、重开会话后 /zentao 即可直接用，无需手建、无需改 PATH。
if [ -n "${HOME:-}" ]; then
  cmd_src="$SCRIPT_DIR/../templates/zentao.md"
  cmd_dst="$HOME/.claude/commands/zentao.md"
  if [ -f "$cmd_src" ] && { [ ! -f "$cmd_dst" ] || ! cmp -s "$cmd_src" "$cmd_dst"; }; then
    mkdir -p "$(dirname "$cmd_dst")" && cp "$cmd_src" "$cmd_dst"
    echo "[hook] 已安装 /zentao 命令 → $cmd_dst"
  fi
fi

echo "[hook] session ready: store=$STORE_DIR current=$(zz_current_id 2>/dev/null || echo -)"
