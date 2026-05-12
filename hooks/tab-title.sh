#!/bin/bash
# Unified tab title helper for Ghostty tabs.
# Usage: tab-title.sh <status> [session_id]
#   status: idle, working, input, query, end
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

# Load config from JSON (~/.claude/.ccg/config.json).
# Only .mode is read; icon appearance is fixed and not configurable.
BELL_MODE="notifs"
BELL_CONFIG="${BELL_CONFIG:-$HOME/.claude/.ccg/config.json}"
if [ -f "$BELL_CONFIG" ]; then
  _m=""
  IFS= read -r _m < <(jq -r '.mode // "notifs"' "$BELL_CONFIG" 2>/dev/null)
  [ -n "$_m" ] && BELL_MODE="$_m"
  unset _m
fi
__trace "bell-config mode=$BELL_MODE"

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

# Find the ancestor `claude` PID. Used to detect live Claude-owned monitors
# (Monitor tool / Bash run_in_background) so an idle session with active work
# in the background can be surfaced as `watching` instead of plain `idle`.
# CCG_CLAUDE_PID is an explicit override used by the validator.
_find_claude_pid() {
  if [ -n "${CCG_CLAUDE_PID:-}" ]; then
    printf '%s' "$CCG_CLAUDE_PID"
    return 0
  fi
  local p=$PPID
  for _ in 1 2 3 4 5 6 7 8; do
    [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ] || break
    local c
    c=$(ps -p "$p" -o comm= 2>/dev/null | tr -d ' ')
    case "$c" in
      claude|*/claude) printf '%s' "$p"; return 0 ;;
    esac
    p=$(ps -p "$p" -o ppid= 2>/dev/null | tr -d ' ')
  done
  return 1
}

# Count immediate children of $1 whose command line contains the
# `/tmp/claude-<hex>-cwd` marker emitted by Claude Code's bash-tool wrapper.
# Synchronous Bash calls have the same marker but exit in seconds, so any
# match while the session is idle is a live Monitor / background bash.
_count_live_monitors() {
  local cpid="$1"
  [ -n "$cpid" ] || { echo 0; return; }
  ps -axo ppid=,command= 2>/dev/null \
    | awk -v p="$cpid" '$1 == p && /\/tmp\/claude-[0-9a-f]+-cwd/ { n++ } END { print n+0 }'
}

# Resolve an "effective status" that upgrades idle → watching when the
# claude ancestor still has live monitor descendants. Only idle is upgraded;
# input/working/end pass through unchanged.
effective_status="$status"
claude_pid=""
if [ "$status" = "idle" ]; then
  claude_pid=$(_find_claude_pid 2>/dev/null || true)
  if [ -n "$claude_pid" ]; then
    if [ "$(_count_live_monitors "$claude_pid")" -gt 0 ]; then
      effective_status="watching"
      __trace "idle upgraded to watching (claude_pid=$claude_pid)"
    fi
  fi
fi

if [ "$status" != "query" ]; then
  case "$effective_status" in
    working)  title="⏳ $base_title" ;;
    input)    title="🔔 $base_title" ;;
    watching) title="👀 $base_title" ;;
    *)        title="$base_title" ;;
  esac
  # /dev/tty isn't available to hook subprocesses in newer Claude Code builds
  # (no controlling terminal), so resolve the terminal device by walking up
  # to the first ancestor attached to a TTY (typically the claude process).
  tty_dev=""
  pid=$PPID
  for _ in 1 2 3 4 5; do
    [ -n "$pid" ] && [ "$pid" != "0" ] || break
    t=$(ps -p "$pid" -o tty= 2>/dev/null | tr -d ' ')
    if [ -n "$t" ] && [ "$t" != "?" ] && [ "$t" != "??" ] && [ -w "/dev/$t" ]; then
      tty_dev="/dev/$t"
      break
    fi
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
  done
  if [ -n "$tty_dev" ]; then
    printf '\033]2;%s\007' "$title" > "$tty_dev" 2>/dev/null
    __trace "title-set title=\"$title\" dev=$tty_dev"
  else
    __trace "title-set skipped (no parent tty found)"
  fi
fi

# Maintain the bell-state directory. The SwiftBar plugin reads this instead of
# querying the macOS Accessibility API, which has multi-second lag reflecting
# ANSI-set tab titles while Ghostty is backgrounded.
#
# State file format:
#   Line 1: full tab title with icon prefix (matches the ANSI title set above)
#   Line 2: status string (input | working | idle | watching)
#   Line 3: only present for status=watching; the claude ancestor PID. The
#           plugin uses it to detect when the monitored process has exited
#           and downgrade the file to plain idle on the fly.
STATE_DIR="${BELL_STATE_DIR:-$HOME/.claude/bell-state}"
state_file="$STATE_DIR/$session_id"
state_changed=0

_write_state() {
  mkdir -p "$STATE_DIR"
  local desired="$1" st="$2" extra="$3"
  local new
  if [ -n "$extra" ]; then
    new=$(printf '%s\n%s\n%s\n' "$desired" "$st" "$extra")
  else
    new=$(printf '%s\n%s\n' "$desired" "$st")
  fi
  local existing=""
  [ -f "$state_file" ] && existing=$(cat "$state_file" 2>/dev/null)
  if [ "$existing" != "$new" ]; then
    printf '%s\n' "$new" > "$state_file"
    state_changed=1
    __trace "state-file write ($st): $state_file"
  else
    __trace "state-file unchanged ($st)"
  fi
}

_remove_state() {
  if [ -f "$state_file" ]; then
    rm -f "$state_file"
    state_changed=1
    __trace "state-file remove: $state_file"
  else
    __trace "state-file absent (nothing to remove)"
  fi
}

case "$BELL_MODE" in
  off)
    _remove_state
    ;;
  always-on)
    case "$effective_status" in
      input)    _write_state "🔔 $base_title" "input"   "" ;;
      working)  _write_state "⏳ $base_title" "working" "" ;;
      watching) _write_state "👀 $base_title" "watching" "$claude_pid" ;;
      idle)     _write_state "$base_title"    "idle"    "" ;;
      end)      _remove_state ;;
      *)        __trace "state-file unchanged (status=$effective_status)" ;;
    esac
    ;;
  *)
    # notifs mode (default): only "needs attention" writes a state file.
    # watching is a refinement of idle and is not surfaced in notifs mode.
    case "$effective_status" in
      input)
        _write_state "🔔 $base_title" "input" ""
        ;;
      idle|watching|working|end)
        _remove_state
        ;;
      *)
        __trace "state-file unchanged (status=$effective_status)"
        ;;
    esac
    ;;
esac

unset -f _write_state _remove_state

# Log state transitions to ~/.claude/.ccg/events.jsonl for the metrics
# dashboard. Independent of BELL_MODE — the log captures every transition
# even in notifs mode (where idle/working don't write a bell-state file).
# Per-session "logical state" files at ~/.claude/.ccg/sessions/<sid> let us
# detect transitions without scanning the log on every hook invocation
# (PostToolUse can fire many times per second).
case "$effective_status" in
  idle|watching|working|input|end)
    EVENT_LOG="${CCG_EVENT_LOG:-$HOME/.claude/.ccg/events.jsonl}"
    SESSION_STATE_DIR="${CCG_SESSION_STATE_DIR:-$HOME/.claude/.ccg/sessions}"
    session_state_file="$SESSION_STATE_DIR/$session_id"
    prev_state=""
    [ -f "$session_state_file" ] && prev_state=$(head -n1 "$session_state_file" 2>/dev/null)
    if [ "$effective_status" != "$prev_state" ]; then
      # End event only meaningful if there was a prior state to end.
      if [ "$effective_status" = "end" ] && [ -z "$prev_state" ]; then
        __trace "event-log skip (end with no prior state)"
      else
        mkdir -p "$(dirname "$EVENT_LOG")" "$SESSION_STATE_DIR"
        ts=$(gdate +%s.%3N 2>/dev/null || date +%s)
        jq -nc --arg ts "$ts" --arg sid "$session_id" --arg state "$effective_status" \
              --arg title "$base_title" --arg cwd "$PWD" \
          '{ts: ($ts|tonumber), session_id: $sid, state: $state, title: $title, cwd: $cwd}' \
          >> "$EVENT_LOG" 2>/dev/null
        __trace "event-log append state=$effective_status prev=${prev_state:-<none>}"
        if [ "$effective_status" = "end" ]; then
          rm -f "$session_state_file"
        else
          printf '%s\n' "$effective_status" > "$session_state_file"
        fi
      fi
    else
      __trace "event-log skip (no transition, state=$effective_status)"
    fi
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
