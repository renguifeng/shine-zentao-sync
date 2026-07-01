#!/usr/bin/env bash
# 兼容入口：旧 settings.json 以 `hook_sync.sh start` 注册 SessionStart hook。
# 实际逻辑已迁至 hook_session.sh；本脚本薄封装转发，保持旧引用可用。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/hook_session.sh" "$@"
