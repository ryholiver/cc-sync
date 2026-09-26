#!/usr/bin/env bash
# List Claude Code sessions for a project path and its subdirectory slots.
#
# Usage: list-sessions.sh <project-path> [days=20] [--remote user@host]
# Output TSV, newest first:
#   mtime <TAB> slot-suffix <TAB> title <TAB> size <TAB> session-id <TAB> sidedir(yes/no)
# slot-suffix is "/" for the workspace root slot, "-crm" etc. for subdirectory slots.
#
# --remote ships this script to the target over ssh (bash -s), zero deployment —
# use it to inspect what already exists on the other machine.
set -euo pipefail

PROJECT_PATH="${1:?usage: list-sessions.sh <project-path> [days] [--remote user@host]}"
DAYS="${2:-20}"

if [ "${3:-}" = "--remote" ]; then
  REMOTE="${4:?--remote needs user@host}"
  exec ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
    "$REMOTE" bash -s -- "$PROJECT_PATH" "$DAYS" < "$0"
fi

PROJECTS_DIR="$HOME/.claude/projects"
[ -d "$PROJECTS_DIR" ] || { echo "ERROR no $PROJECTS_DIR on this machine" >&2; exit 1; }

# 槽位名 = 项目绝对路径中每个非字母数字"字符"替换为 "-"。
# 必须按字符而非字节处理：中文路径在 UTF-8 下每字占 3 字节，若在 C/POSIX locale
# 下用 sed，它会逐字节替换，把 "个人助手" 变成 12 个 "-" 而不是 4 个，于是永远
# 匹配不到 Claude Code 实际创建的目录，一个会话都列不出来。
# python3 解析 argv 时按 UTF-8 解码，与系统 locale 无关，故用它。
slug=$(python3 -c 'import sys,re; sys.stdout.write(re.sub(r"[^A-Za-z0-9]", "-", sys.argv[1]))' "$PROJECT_PATH")

# BSD stat (macOS) first, GNU stat (Linux) as fallback.
fmtime() { stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$1" 2>/dev/null || stat -c '%y' "$1" | cut -c1-16; }

cd "$PROJECTS_DIR"
# Exact slot + subdirectory slots. Slot dirs start with "-", so find needs the ./ prefix.
for dir in "$slug" "$slug"-*; do
  [ -d "./$dir" ] || continue
  suffix="${dir#"$slug"}"
  suffix="${suffix:-/}"
  find ./"$dir" -maxdepth 1 -name '*.jsonl' -mtime -"$DAYS" 2>/dev/null | while IFS= read -r f; do
    # Title chain: last aiTitle record -> last summary record -> (untitled).
    title=$({ grep -o '"aiTitle":"[^"]*"' "$f" || true; } | tail -1 | sed 's/^"aiTitle":"//;s/"$//')
    if [ -z "$title" ]; then
      title=$({ grep -o '"summary":"[^"]*"' "$f" || true; } | tail -1 | sed 's/^"summary":"//;s/"$//' | cut -c1-80)
    fi
    [ -z "$title" ] && title="(untitled)"
    sid=$(basename "$f" .jsonl)
    side=no
    [ -d "./$dir/$sid" ] && side=yes
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(fmtime "$f")" "$suffix" "$title" "$(du -h "$f" | cut -f1 | tr -d ' \t')" "$sid" "$side"
  done
done | sort -r
