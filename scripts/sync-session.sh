#!/usr/bin/env bash
# Copy one Claude Code session (transcript + optional side directory) to a
# remote machine, with a divergence guard and end-to-end verification.
#
# Usage: sync-session.sh <project-path> <session-id> <user@host> [--force]
# Output on success:
#   VERIFIED <session-id>     已传输并校验通过
#   IN_SYNC <session-id>      两边内容已一致，无需传输
#   RESUME_AT <project-path>
# Exit codes: 0 verified or already in sync / 1 usage or missing session /
#             2 verification mismatch / 3 remote copy is larger (resumed there) /
#             4 same size but different content (genuinely diverged — e.g. forked)
#             — 3 and 4 both refuse to overwrite unless --force is given.
set -euo pipefail

PROJECT_PATH="${1:?usage: sync-session.sh <project-path> <session-id> <user@host> [--force]}"
SID="${2:?missing session-id}"
REMOTE="${3:?missing user@host}"
FORCE="${4:-}"

SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5)
# 同 list-sessions.sh：按「字符」而非「字节」计算槽位名，否则中文项目路径
# 在 C locale 下会被逐字节替换（"个人助手" -> 12 个 "-"），与本机实际目录不符。
slug=$(python3 -c 'import sys,re; sys.stdout.write(re.sub(r"[^A-Za-z0-9]", "-", sys.argv[1]))' "$PROJECT_PATH")
LOCAL_DIR="$HOME/.claude/projects/$slug"
REMOTE_DIR=".claude/projects/$slug"   # relative to the remote $HOME
JSONL="$LOCAL_DIR/$SID.jsonl"

[ -f "$JSONL" ] || { echo "ERROR no such session: $JSONL" >&2; exit 1; }

fsize() { stat -f %z "$1" 2>/dev/null || stat -c %s "$1"; }
local_size=$(fsize "$JSONL")
local_sum=$(shasum -a 256 "$JSONL" | cut -d' ' -f1)

# 分流保护。转录是只追加的，所以"对面更大"意味着该会话已在对面续写，绝不能覆盖。
# 但只比大小不够：fork 过的会话会把大记录重写成多条小记录，字节数可能刚好相等，
# 此时大小给不出任何信号，只比大小会静默覆盖掉一方（实测有 6 个会话正是如此）。
# 所以同时取对面的内容哈希，据此区分三种情形：
#   哈希相同       → 两边已一致，无需传输
#   对面更大       → 对面更新，拒绝覆盖（exit 3）
#   等大但哈希不同 → 两份历史已真分歧，无法判断谁该赢，同样拒绝（exit 4）
remote_info=$(ssh "${SSH_OPTS[@]}" "$REMOTE" \
  "f='$REMOTE_DIR/$SID.jsonl'; if [ -f \"\$f\" ]; then stat -f %z \"\$f\" 2>/dev/null || stat -c %s \"\$f\" 2>/dev/null; shasum -a 256 \"\$f\" 2>/dev/null | cut -d' ' -f1; fi" || true)
remote_size=$(printf '%s\n' "$remote_info" | sed -n 1p | tr -d ' \t')
remote_sum=$(printf '%s\n' "$remote_info" | sed -n 2p | tr -d ' \t')
remote_size="${remote_size:-0}"

if [ -n "$remote_sum" ] && [ "$remote_sum" = "$local_sum" ]; then
  echo "IN_SYNC $SID"
  echo "RESUME_AT $PROJECT_PATH"
  exit 0
fi

if [ "$FORCE" != "--force" ]; then
  if [ "$remote_size" -gt "$local_size" ]; then
    echo "DIVERGED local=$local_size remote=$remote_size"
    echo "Remote copy is larger — it was resumed on the target. Refusing to overwrite (--force to override)." >&2
    exit 3
  fi
  if [ "$remote_size" -eq "$local_size" ] && [ "$remote_size" -gt 0 ]; then
    echo "DIVERGED_SAME_SIZE local=$local_size remote=$remote_size"
    echo "Same size but different content — the copies have genuinely diverged (one was forked or rewritten). Refusing to overwrite (--force to override)." >&2
    exit 4
  fi
fi

ssh "${SSH_OPTS[@]}" "$REMOTE" "mkdir -p '$REMOTE_DIR'"
rsync -a "$JSONL" "$REMOTE:$REMOTE_DIR/"
if [ -d "$LOCAL_DIR/$SID" ]; then
  rsync -a "$LOCAL_DIR/$SID" "$REMOTE:$REMOTE_DIR/"
fi

# 校验：转录校验和必须一致；side 目录文件数必须一致。
# local_sum 已在上面算过，此处只重取对面的。
remote_sum=$(ssh "${SSH_OPTS[@]}" "$REMOTE" "shasum -a 256 '$REMOTE_DIR/$SID.jsonl'" | cut -d' ' -f1)
if [ "$local_sum" != "$remote_sum" ]; then
  echo "MISMATCH jsonl checksum local=$local_sum remote=$remote_sum" >&2
  exit 2
fi
if [ -d "$LOCAL_DIR/$SID" ]; then
  local_n=$(find "$LOCAL_DIR/$SID" -type f | wc -l | tr -d ' ')
  remote_n=$(ssh "${SSH_OPTS[@]}" "$REMOTE" "find '$REMOTE_DIR/$SID' -type f | wc -l" | tr -d ' ')
  if [ "$local_n" != "$remote_n" ]; then
    echo "MISMATCH sidedir file count local=$local_n remote=$remote_n" >&2
    exit 2
  fi
fi

echo "VERIFIED $SID"
echo "RESUME_AT $PROJECT_PATH"
