#!/bin/bash
# Unified tab title helper for Ghostty tabs.
# Usage: tab-title.sh <status> <session_id>
#   status: idle, working, input, query
#
# Sets the terminal tab title with the appropriate icon and outputs the base
# title (without icon) to stdout. Use status "query" to get the base title
# without changing the terminal tab title.

status="$1"
session_id="$2"
short_id=$(echo "$session_id" | cut -c1-8)
base_title="Claude Code [$short_id]"

# Look up session custom title from the session's jsonl file
summary=""
for session_file in ~/.claude/projects/*/"$session_id".jsonl; do
  [ -f "$session_file" ] || continue
  summary=$(grep '"type":"custom-title"' "$session_file" \
    | jq -r --arg sid "$session_id" \
      'select(.sessionId == $sid) | .customTitle // empty' 2>/dev/null \
    | tail -1)
  [ -n "$summary" ] && break
done
if [ -n "$summary" ]; then
  base_title="$base_title $summary"
fi

if [ "$status" != "query" ]; then
  case "$status" in
    working) title="⏳ $base_title" ;;
    input)   title="🔔 $base_title" ;;
    *)       title="$base_title" ;;
  esac
  printf '\033]2;%s\007' "$title" > /dev/tty 2>/dev/null
fi

echo "$base_title"
