#!/usr/bin/env bash
# Stop hook —— 每个 turn 结束时增量采集 token 消耗，归属当前任务，写本地 entries。
#
# 原理（字节偏移增量法，O(增量)）：
#   - stdin 收到 {session_id, transcript_path, ...}（Stop hook 不直接给 token 数）。
#   - transcript 是只追加 JSONL；每条 assistant 消息含 usage.{input,output,
#     cache_creation_input,cache_read_input}_tokens。
#   - sessions/<sid>.json 记上次处理到的字节 offset；本次 tail offset 之后的增量段到
#     临时文件（**写文件而非 $(...) 变量**，避免 bash 命令替换吞掉末尾换行导致最后一行被推迟）。
#   - 用 4 个独立正则分别累加（usage 内可能嵌套 server_tool_use 等子对象，[^}]* 会截断）。
#   - offset 推进到当前文件大小。Stop hook 在 assistant 消息完整落盘后才触发，无半截行风险。
#   - 任何异常都静默 exit 0，绝不阻断用户。
#
# 任务归属：读 tasks/current（无当前任务则跳过）。token 只记本地，不进禅道。
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
. "$SCRIPT_DIR/lib.sh"

{
  INPUT="$(cat)"
  session_id="$(printf '%s' "$INPUT" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:"([^"]*)"[[:space:]]*$/\1/')"
  transcript="$(printf '%s' "$INPUT" | grep -oE '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*:"([^"]*)"[[:space:]]*$/\1/')"
  [ -z "$transcript" ] && exit 0
  [ -f "$transcript" ] || exit 0

  zz_paths; zz_ensure_dirs
  tid="$(zz_current_id 2>/dev/null || true)"
  [ -z "$tid" ] && exit 0

  fsize="$(stat -c%s "$transcript" 2>/dev/null || stat -f%z "$transcript" 2>/dev/null || echo 0)"
  [ "$fsize" -le 0 ] 2>/dev/null && exit 0
  sid_file="$SESSIONS_DIR/${session_id}.json"
  prev_offset="$(zz_flat_num "$sid_file" offset)"
  [ -z "$prev_offset" ] && prev_offset=0
  [ "$fsize" -le "$prev_offset" ] 2>/dev/null && exit 0

  # 增量段写到临时文件（保留末尾换行，避免命令替换截断最后一行）
  tmp_region="$(mktemp)"
  tail -c +$((prev_offset + 1)) "$transcript" > "$tmp_region" 2>/dev/null

  # 4 个独立正则分别累加 assistant 行 token 字段
  sum_in="$(grep '"type":"assistant"' "$tmp_region" | grep -oE '"input_tokens":[0-9]+' | grep -oE '[0-9]+$' | awk '{s+=$1} END{print s+0}')"
  sum_out="$(grep '"type":"assistant"' "$tmp_region" | grep -oE '"output_tokens":[0-9]+' | grep -oE '[0-9]+$' | awk '{s+=$1} END{print s+0}')"
  sum_cc="$(grep '"type":"assistant"' "$tmp_region" | grep -oE '"cache_creation_input_tokens":[0-9]+' | grep -oE '[0-9]+$' | awk '{s+=$1} END{print s+0}')"
  sum_cr="$(grep '"type":"assistant"' "$tmp_region" | grep -oE '"cache_read_input_tokens":[0-9]+' | grep -oE '[0-9]+$' | awk '{s+=$1} END{print s+0}')"
  rm -f "$tmp_region"
  sum_in="${sum_in:-0}"; sum_out="${sum_out:-0}"; sum_cc="${sum_cc:-0}"; sum_cr="${sum_cr:-0}"

  # 推进 offset 到当前文件大小（temp+mv 原子写）
  now="$(date +%s)"
  printf '{"offset":%s,"last_ts":%s}\n' "$fsize" "$now" > "$sid_file.tmp" && mv -f "$sid_file.tmp" "$sid_file"

  total=$(( sum_in + sum_out + sum_cc + sum_cr ))
  [ "$total" -le 0 ] && exit 0

  ZZ_SESSION_ID="$session_id"
  zz_append_entry "$tid" "turn" 0 "$sum_in" "$sum_out" "$sum_cc" "$sum_cr" 0 0 0 ""
} 2>/dev/null

exit 0
