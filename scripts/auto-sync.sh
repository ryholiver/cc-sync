#!/usr/bin/env bash
# cc-sync auto-sync — SessionEnd hook target.
#
# When a Claude Code session ends, push its transcript (+ side directory) to
# DEFAULT_PEER, silently. Installed as an optional SessionEnd hook by
# install.sh; configured via ~/.claude/cc-sync.conf:
#
#   DEFAULT_PEER=user@host        # required for auto-sync; tailnet names work
#
# Safety: same divergence guard as sync-session.sh — if the peer's copy is
# larger (session was resumed there), we skip instead of overwriting.
# Every failure path exits 0 quietly: a hook must never break the session.
set -uo pipefail

CONF="$HOME/.claude/cc-sync.conf"
[ -f "$CONF" ] && . "$CONF"
[ -n "${DEFAULT_PEER:-}" ] || exit 0

# Hook stdin is a JSON payload; transcript_path points at the session jsonl.
payload=$(cat 2>/dev/null) || exit 0
tp=$(printf '%s' "$payload" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("transcript_path",""))' 2>/dev/null) || exit 0
[ -n "$tp" ] && [ -f "$tp" ] || exit 0

slot_dir=$(dirname "$tp")
sid=$(basename "$tp" .jsonl)
slot=$(basename "$slot_dir")
rel=".claude/projects/$slot"

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
fsize() { stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null; }

local_size=$(fsize "$tp") || exit 0
local_sum=$(shasum -a 256 "$tp" 2>/dev/null | cut -d' ' -f1)
remote_info=$(ssh "${SSH_OPTS[@]}" "$DEFAULT_PEER" \
  "f='$rel/$sid.jsonl'; if [ -f \"\$f\" ]; then stat -f %z \"\$f\" 2>/dev/null || stat -c %s \"\$f\" 2>/dev/null; shasum -a 256 \"\$f\" 2>/dev/null | cut -d' ' -f1; fi" 2>/dev/null) || remote_info=""
remote_size=$(printf '%s\n' "$remote_info" | sed -n 1p | tr -d ' \t')
remote_sum=$(printf '%s\n' "$remote_info" | sed -n 2p | tr -d ' \t')
remote_size="${remote_size:-0}"

# 分流保护，两种情形都直接退场（钩子必须安静，一律 exit 0）：
#   对面更大       → 会话已在对面续写，那份历史更全
#   等大但哈希不同 → 两份历史已真分歧（如 fork 过），无法判断谁该赢
# 只比大小会漏掉后一种，从而静默覆盖掉一方。这里宁可不同步，也不猜。
[ "$remote_size" -gt "$local_size" ] && exit 0
if [ "$remote_size" -eq "$local_size" ] && [ "$remote_size" -gt 0 ] \
   && [ -n "$remote_sum" ] && [ "$remote_sum" != "$local_sum" ]; then
  exit 0
fi

ssh "${SSH_OPTS[@]}" "$DEFAULT_PEER" "mkdir -p '$rel'" 2>/dev/null || exit 0
rsync -a --timeout=30 "$tp" "$DEFAULT_PEER:$rel/" 2>/dev/null || exit 0
[ -d "$slot_dir/$sid" ] && rsync -a --timeout=30 "$slot_dir/$sid" "$DEFAULT_PEER:$rel/" 2>/dev/null
exit 0
