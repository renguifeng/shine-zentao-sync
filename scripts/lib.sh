#!/usr/bin/env bash
# lib.sh —— shine-zentao-skill 公共库（被 zentao CLI 与 hook 脚本 source）。
#
# 存储布局（扁平文件，避开嵌套 JSON 解析；均位于 $PROJECT/.claude/zentao/）：
#   current              当前任务 ID（单行）
#   project.conf         项目级覆盖（backend_host/backend_port/project_name），flat JSON
#   tasks/<id>.json      单个任务 flat 对象：id,name,execution_id,alias,last_report_ts,last_report_date,added_ts
#   sessions/<sid>.json  会话 token 偏移：{offset,last_ts}（M3 用）
#   entries.jsonl        追加日志，每行一条工作记录
# 全局：~/.claude/zentao.conf（账号/密码/默认 backend/secret，chmod 600）
#
# 配置优先级：项目 project.conf > 全局 zentao.conf > 环境变量($ZENTAO_*/$WEBHOOK_*) > .env > 默认。

# ---------------- 路径 ----------------
zz_paths() {
  PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
  STORE_DIR="$PROJECT_DIR/.claude/zentao"
  TASKS_DIR="$STORE_DIR/tasks"
  SESSIONS_DIR="$STORE_DIR/sessions"
  ENTRIES_FILE="$STORE_DIR/entries.jsonl"
  CURRENT_FILE="$STORE_DIR/current"
  PROJECT_CONF="$STORE_DIR/project.conf"
  GLOBAL_CONF="${HOME}/.claude/zentao.conf"
  ENV_FILE="$PROJECT_DIR/.env"
}

zz_ensure_dirs() {
  mkdir -p "$TASKS_DIR" "$SESSIONS_DIR"
}

# ---------------- flat JSON 读（无 jq）----------------
# 用法：zz_flat_num <file> <key>  /  zz_flat_str <file> <key>
zz_flat_num() {
  [ -f "$1" ] || return 0
  grep -oE "\"$2\":[0-9]+" "$1" 2>/dev/null | head -1 | cut -d: -f2
}
zz_flat_str() {
  [ -f "$1" ] || return 0
  grep -oE "\"$2\":\"[^\"]*\"" "$1" 2>/dev/null | head -1 | sed -E 's/^[^:]*://' | sed -E 's/^"//; s/"$//'
}

# 从 .env 读 KEY=VALUE（兼容 \r）
zz_env_get() {
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '\r'
}

# ---------------- 配置加载（填充 CFG_* 全局）----------------
# 项目 project.conf / 全局 zentao.conf 取值，回退环境变量 / .env / 默认。
zz_cfg_field() {  # <kind: p|g> <key>   p=project.conf g=global
  local kind="$1" key="$2" f
  [ "$kind" = "p" ] && f="$PROJECT_CONF" || f="$GLOBAL_CONF"
  zz_flat_str "$f" "$key"
}
zz_cfg_num() {
  local kind="$1" key="$2" f
  [ "$kind" = "p" ] && f="$PROJECT_CONF" || f="$GLOBAL_CONF"
  zz_flat_num "$f" "$key"
}

zz_load_config() {
  zz_paths
  # 账号密码：全局为主，回退环境 / .env
  CFG_ACCOUNT="$(zz_cfg_str g account)"
  [ -z "$CFG_ACCOUNT" ] && CFG_ACCOUNT="${ZENTAO_ACCOUNT:-$(zz_env_get ZENTAO_ACCOUNT)}"
  CFG_PASSWORD="$(zz_cfg_str g password)"
  [ -z "$CFG_PASSWORD" ] && CFG_PASSWORD="${ZENTAO_PASSWORD:-$(zz_env_get ZENTAO_PASSWORD)}"
  # backend：项目 > 全局 > 环境 > 默认
  CFG_HOST="$(zz_cfg_str p backend_host)"; [ -z "$CFG_HOST" ] && CFG_HOST="$(zz_cfg_str g backend_host)"
  [ -z "$CFG_HOST" ] && CFG_HOST="${WEBHOOK_HOST:-$(zz_env_get WEBHOOK_HOST)}"; [ -z "$CFG_HOST" ] && CFG_HOST="localhost"
  CFG_PORT="$(zz_cfg_num p backend_port)"; [ -z "$CFG_PORT" ] && CFG_PORT="$(zz_cfg_num g backend_port)"
  [ -z "$CFG_PORT" ] && CFG_PORT="${PORT:-$(zz_env_get PORT)}"; [ -z "$CFG_PORT" ] && CFG_PORT="9998"
  CFG_SECRET="$(zz_cfg_str g webhook_secret)"
  [ -z "$CFG_SECRET" ] && CFG_SECRET="${WEBHOOK_SECRET:-$(zz_env_get WEBHOOK_SECRET)}"
  CFG_PROJECT="$(zz_cfg_str p project_name)"; [ -z "$CFG_PROJECT" ] && CFG_PROJECT="$(zz_cfg_str g default_project_name)"
  [ -z "$CFG_PROJECT" ] && CFG_PROJECT="${WEBHOOK_PROJECT_NAME:-$(zz_env_get WEBHOOK_PROJECT_NAME)}"
  [ -z "$CFG_PROJECT" ] && CFG_PROJECT="$(basename "$PROJECT_DIR")"
}
# 配置读取统一入口（兼顾 str 在两种文件）
zz_cfg_str() { zz_cfg_field "$1" "$2"; }

# ---------------- 任务 ----------------
# 当前任务 ID（解析 alias）
zz_current_id() {
  [ -f "$CURRENT_FILE" ] || return 0
  local cur; cur="$(cat "$CURRENT_FILE" 2>/dev/null | tr -d '[:space:]')"
  [ -z "$cur" ] && return 0
  # 若是数字直接返回；否则按 alias 找
  if echo "$cur" | grep -qE '^[0-9]+$'; then
    echo "$cur"
  else
    local f id
    for f in "$TASKS_DIR"/*.json; do
      [ -f "$f" ] || continue
      [ "$(zz_flat_str "$f" alias)" = "$cur" ] && { id="$(zz_flat_num "$f" id)"; echo "$id"; return; }
    done
    return 0
  fi
}

zz_set_current() {  # <id>
  zz_ensure_dirs
  printf '%s\n' "$1" > "$CURRENT_FILE"
}

zz_task_file() { echo "$TASKS_DIR/$1.json"; }

# 读取任务字段：zz_task <id> <field>
zz_task() {
  local f; f="$(zz_task_file "$1")"
  [ -f "$f" ] || return 0
  case "$2" in
    id|execution_id|last_report_ts|added_ts) zz_flat_num "$f" "$2" ;;
    name|alias|last_report_date) zz_flat_str "$f" "$2" ;;
  esac
}

# ---------------- 时间 / 工时 ----------------
zz_now() { date +%s; }
zz_today() { date '+%Y-%m-%d'; }

# 多任务跨天工时：zz_compute_hours <last_ts> <last_date> [explicit_hours]
zz_compute_hours() {
  local last_ts="${1:-}" last_date="${2:-}" explicit="${3:-}"
  local now today raw hours midnight
  if [ -n "$explicit" ]; then
    awk -v h="$explicit" 'BEGIN{if(h<0.01)h=0.01; if(h>8)h=8; printf "%.2f", h}'
    return
  fi
  now=$(date +%s); today=$(date '+%Y-%m-%d')
  if [ -z "$last_ts" ]; then
    printf '0.01'; return
  fi
  raw=$(awk -v n="$now" -v l="$last_ts" 'BEGIN{printf "%.4f", (n-l)/3600}')
  if [ "$last_date" != "$today" ] && [ -n "$last_date" ]; then
    midnight=$(date -d "$today 00:00:00" +%s 2>/dev/null || echo "$now")
    hours=$(awk -v r="$raw" -v t="$now" -v m="$midnight" 'BEGIN{sec=(t-m)/3600; print (r<sec?r:sec)}')
  else
    hours="$raw"
  fi
  awk -v h="$hours" 'BEGIN{if(h<0.01)h=0.01; if(h>8)h=8; printf "%.2f", h}'
}

# ---------------- JSON 转义 / 写入 ----------------
# 转义 \ " \t \r 与换行（中文多字节原样保留）
zz_json_escape() {
  printf '%s' "$1" | awk '
  BEGIN { ORS = "" }
  {
    gsub(/\\/, "\\\\")
    gsub(/"/, "\\\"")
    gsub(/\t/, "\\t")
    gsub(/\r/, "\\r")
    if (NR > 1) print "\\n"
    print
  }'
}

# 更新任务锚点：zz_touch_task_anchor <id>
zz_touch_task_anchor() {
  local f; f="$(zz_task_file "$1")"; [ -f "$f" ] || return 0
  local name alias exec_id added
  name="$(zz_flat_str "$f" name)"; alias="$(zz_flat_str "$f" alias)"
  exec_id="$(zz_flat_num "$f" execution_id)"; added="$(zz_flat_num "$f" added_ts)"
  local n_esc a_esc
  n_esc="$(zz_json_escape "$name")"; a_esc="$(zz_json_escape "$alias")"
  printf '{"id":%s,"name":"%s","execution_id":%s,"alias":"%s","added_ts":%s,"last_report_ts":%s,"last_report_date":"%s"}\n' \
    "$1" "$n_esc" "${exec_id:-0}" "$a_esc" "${added:-0}" "$(date +%s)" "$(date '+%Y-%m-%d')" > "$f"
}

# 追加 entries.jsonl 一行。参数顺序：
#   task_id source hours in_tok out_tok cc_tok cr_tok ins del files summary
zz_append_entry() {
  zz_ensure_dirs
  local task_id="$1" source="$2" hours="$3" in_tok="$4" out_tok="$5"
  local cc_tok="$6" cr_tok="$7" ins="$8" del="$9" files="${10}" summary="${11:-}"
  local sid="${ZZ_SESSION_ID:-}"
  local sum_esc; sum_esc="$(zz_json_escape "$summary")"
  printf '{"ts":%s,"date":"%s","session_id":"%s","task_id":%s,"source":"%s","hours":%s,"in_tok":%s,"out_tok":%s,"cache_create_tok":%s,"cache_read_tok":%s,"ins":%s,"del":%s,"files":%s,"summary":"%s"}\n' \
    "$(date +%s)" "$(date '+%Y-%m-%d')" "$sid" "$task_id" "$source" "$hours" \
    "${in_tok:-0}" "${out_tok:-0}" "${cc_tok:-0}" "${cr_tok:-0}" \
    "${ins:-0}" "${del:-0}" "${files:-0}" "$sum_esc" >> "$ENTRIES_FILE"
}

# ---------------- HMAC / HTTP ----------------
# 对字符串算 HMAC-SHA256（hex）
zz_hmac_str() {  # <secret> <string>
  printf '%s' "$2" | openssl dgst -sha256 -hmac "$1" 2>/dev/null | awk '{print $NF}'
}
# 对文件字节算 HMAC（与既有 commit_sync 一致）
zz_hmac_file() {  # <secret> <file>
  openssl dgst -sha256 -hmac "$1" < "$2" 2>/dev/null | awk '{print $NF}'
}

# POST webhook：zz_webhook_post <body_file>  → 打印 "HTTPCODE|resp"
# 用 CFG_* 配置；签名（secret 非空时）。
zz_webhook_post() {
  local body_file="$1"
  local url="http://${CFG_HOST}:${CFG_PORT}/api/webhook/claude"
  local sig="" code
  if [ -n "$CFG_SECRET" ]; then
    sig="$(zz_hmac_file "$CFG_SECRET" "$body_file")"
  fi
  if [ -n "$sig" ]; then
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 6 -X POST "$url" \
      -H "Content-Type: application/json" -H "X-Claude-Signature: $sig" \
      --data-binary @"$body_file" 2>/dev/null)
  else
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 6 -X POST "$url" \
      -H "Content-Type: application/json" --data-binary @"$body_file" 2>/dev/null)
  fi
  printf '%s' "${code:-000}"
}

# ---------------- 只读查询：GET（canonical HMAC 签名 + creds header）----------------
# 用法：zz_signed_get <path> [k=v ...]  → 打印响应体
# 规范化串与服务端 app.auth.canonical_get 一致：GET\nPATH\n<sorted k=v&>\nTIMESTAMP
zz_signed_get() {
  local path="$1"; shift
  local ts sorted="" sig url
  ts=$(date +%s)
  if [ $# -gt 0 ]; then
    sorted="$(printf '%s\n' "$@" | sort | tr '\n' '&' | sed 's/&$//')"
  fi
  sig="$(printf 'GET\n%s\n%s\n%s' "$path" "$sorted" "$ts" \
    | openssl dgst -sha256 -hmac "$CFG_SECRET" 2>/dev/null | awk '{print $NF}')"
  url="http://${CFG_HOST}:${CFG_PORT}${path}"
  [ -n "$sorted" ] && url="$url?$sorted"
  curl -s --max-time 8 "$url" \
    -H "X-Claude-Signature: $sig" -H "X-Claude-Timestamp: $ts" \
    -H "X-Zentao-Account: $CFG_ACCOUNT" -H "X-Zentao-Password: $CFG_PASSWORD" \
    -H "X-Claude-Identity: ${USER:-shell}" 2>/dev/null
}

# JSON 美化（有 python3 用之，保留中文；否则原样）
zz_pretty() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin), ensure_ascii=False, indent=2))" 2>/dev/null || cat
  else cat; fi
}
