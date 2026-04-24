#!/bin/bash
# Unified tab title helper for Ghostty tabs.
# Usage: tab-title.sh <status> [session_id]
#   status: idle, working, input, query
#
# If session_id is omitted, it is read from stdin JSON (.session_id field).
#
# Sets the terminal tab title with the appropriate icon and maintains the
# per-session bell-state file used by the SwiftBar menubar plugin.
# Outputs two lines to stdout:
#   Line 1: base title (without icon)
#   Line 2: session summary (empty if none)
# Use status "query" to get the output without changing the terminal tab title.
#
# Debug: set BELL_TRACE=1 to append diagnostics to $BELL_TRACE_LOG
# (defaults to /tmp/bell-trace.log). See README for details.

__N=tab-title.sh
__trace() {
  [ -n "$BELL_TRACE" ] || return 0
  printf '%s [%s pid=%s ppid=%s] %s\n' \
    "$(gdate +%s.%3N 2>/dev/null || date +%s)" "$__N" "$$" "$PPID" "$*" \
    >> "${BELL_TRACE_LOG:-/tmp/bell-trace.log}"
}
__trace "entry argc=$# args=[$*]"

status="$1"
session_id="$2"
if [ -z "$session_id" ]; then
  session_id=$(jq -r '.session_id // "unknown"' 2>/dev/null)
  __trace "session_id from stdin=$session_id"
fi
short_id=$(echo "$session_id" | cut -c1-8)
__trace "resolved status=$status session_id=$session_id short_id=$short_id pwd=$PWD"

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
  base_title="Claude Code | $summary"
else
  dir_name=$(basename "$PWD")
  base_title="Claude Code | $dir_name ($short_id)"
fi

if [ "$status" != "query" ]; then
  case "$status" in
    working) title="⏳ $base_title" ;;
    input)   title="🔔 $base_title" ;;
    *)       title="$base_title" ;;
  esac
  printf '\033]2;%s\007' "$title" > /dev/tty 2>/dev/null
  __trace "title-set title=\"$title\""
fi

# Maintain the bell-state directory. The SwiftBar plugin reads this instead of
# querying the macOS Accessibility API, which has multi-second lag reflecting
# ANSI-set tab titles while Ghostty is backgrounded.
STATE_DIR="${BELL_STATE_DIR:-$HOME/.claude/bell-state}"
state_file="$STATE_DIR/$session_id"
state_changed=0
case "$status" in
  input)
    mkdir -p "$STATE_DIR"
    desired="🔔 $base_title"
    if [ ! -f "$state_file" ] || [ "$(cat "$state_file" 2>/dev/null)" != "$desired" ]; then
      printf '%s\n' "$desired" > "$state_file"
      state_changed=1
      __trace "state-file write: $state_file"
    else
      __trace "state-file unchanged (already set)"
    fi
    ;;
  idle|working)
    if [ -f "$state_file" ]; then
      rm -f "$state_file"
      state_changed=1
      __trace "state-file remove: $state_file"
    else
      __trace "state-file absent (nothing to remove)"
    fi
    ;;
  *)
    __trace "state-file unchanged (status=$status)"
    ;;
esac

# Nudge the optional SwiftBar menubar plugin only on actual state transitions.
if [ "$state_changed" = "1" ]; then
  __trace "fire-refresh"
  "$(dirname "$0")/refresh-menubar.sh"
  __trace "refresh-menubar.sh returned rc=$?"
else
  __trace "skip-refresh (no state change)"
fi

__trace "exit"
echo "$base_title"
echo "$summary"
