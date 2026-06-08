#!/bin/bash
# Unified tab title helper for Ghostty tabs.
# Usage: tab-title.sh <status> [session_id]
#   status: idle, working, input, query, end
#
# If session_id is omitted, it is read from stdin JSON (.session_id field).
#
# Sets the terminal tab title with the appropriate icon and maintains the
# per-session bell-state file used by the SwiftBar menubar plugin.
#
# Stdout behaviour:
#   status="query"  → two plain lines: base_title on line 1, summary on line 2.
#                     Used by notify.sh subprocess calls; format must stay stable.
#   other statuses  → JSON {"terminalSequence":"<OSC2 escape>"} so Claude Code
#                     2.1.141+ can emit the sequence on our behalf (no TTY needed).
#                     The direct /dev/tty write below remains as fallback for older
#                     versions and for subprocess calls where stdout is discarded.
# Use status "query" to read titles without changing terminal state.
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
agent_id="${3-}"
# Capture stdin once when we need to read fields from it (session_id arg
# omitted — the direct-hook path). Both session_id and the subagent agent_id
# come from the same hook JSON. When session_id is passed as an arg (the
# notify.sh path and arg-based validator calls), stdin is NOT consumed and
# agent_id arrives as arg 3 instead.
if [ -z "$session_id" ]; then
  _stdin_json=$(cat)
  session_id=$(printf '%s' "$_stdin_json" | jq -r '.session_id // "unknown"' 2>/dev/null)
  [ -z "$agent_id" ] && agent_id=$(printf '%s' "$_stdin_json" | jq -r '.agent_id // empty' 2>/dev/null)
  unset _stdin_json
  __trace "session_id from stdin=$session_id agent_id=${agent_id:-<none>}"
fi
# Actor key for the pending-input set. The main agent has no agent_id in its
# payload, so it maps to the __main__ sentinel; subagent agent_ids are hex and
# can never collide with it. Sanitize to a safe filename charset defensively.
actor="${agent_id:-__main__}"
actor=$(printf '%s' "$actor" | tr -cd '0-9a-zA-Z_-')
[ -z "$actor" ] && actor="__main__"
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
# Resolve the ancestor claude PID for all write states (input/working/idle).
# The PID is stored on line 3 of state files so sweep-bell-state.sh can prune
# orphaned files the moment the process exits, rather than waiting 12h.
case "$status" in
  working|input|idle)
    claude_pid=$(_find_claude_pid 2>/dev/null || true)
    ;;
esac
if [ "$status" = "idle" ] && [ -n "$claude_pid" ]; then
  if [ "$(_count_live_monitors "$claude_pid")" -gt 0 ]; then
    effective_status="watching"
    __trace "idle upgraded to watching (claude_pid=$claude_pid)"
  fi
fi

# Pending-input set: keep the bell up while ANY actor (main agent or a
# subagent) still has an unanswered permission request, even as a *different*
# actor's tool calls keep firing PostToolUse(working). Without this, parallel
# subagents clobber each other's bells: subagent A raises a permission prompt
# (input) and subagent B's next PostToolUse (working) immediately clears it,
# so the bell flaps every few seconds and can never be answered.
#
# Keyed per-actor (agent_id, or __main__ for the main agent) so the clear is
# match-by-id, not "clear any one bell" — a busy sibling must not clear a
# different actor's pending bell. Each actor only ever touches its OWN file in
# the set directory, so concurrent subagent processes never race on shared
# state and no lock is needed.
#   input            -> add this actor
#   working          -> remove this actor; if others remain, hold as input.
#                       SubagentStop is wired to `working`, so it doubles as
#                       the reaper for actors that never fire PostToolUse
#                       (denied permission -> no tool run -> no PostToolUse).
#   idle | end       -> clear the whole set (turn genuinely ended; the main
#                       Stop can't fire while a subagent is still pending).
PENDING_BASE="${CCG_PENDING_DIR:-$HOME/.claude/.ccg/pending}"
pending_dir="$PENDING_BASE/$session_id"
_pending_nonempty() { [ -n "$(ls -A "$pending_dir" 2>/dev/null)" ]; }
# Per-session logical-state file (also used for event-log dedup further down).
# Hoisted here so the `working` branch can tell an active turn from a settled
# one — see the stray-late-SubagentStop guard below.
SESSION_STATE_DIR="${CCG_SESSION_STATE_DIR:-$HOME/.claude/.ccg/sessions}"
session_state_file="$SESSION_STATE_DIR/$session_id"
case "$status" in
  input)
    mkdir -p "$pending_dir" 2>/dev/null
    : > "$pending_dir/$actor" 2>/dev/null
    __trace "pending add actor=$actor"
    ;;
  working)
    [ -d "$pending_dir" ] && rm -f "$pending_dir/$actor" 2>/dev/null
    if _pending_nonempty; then
      effective_status="input"
      __trace "working held as input (pending actors remain: $(ls -A "$pending_dir" 2>/dev/null | tr '\n' ',' ))"
    elif [ "$actor" != "__main__" ]; then
      # Stray-late-SubagentStop guard. SubagentStop is wired to `working` so it
      # can reap a denied subagent's pending bell (no PostToolUse ever fires for
      # a denied permission). But a subagent's terminal event can also land a
      # second or two AFTER the main agent's Stop already settled the session to
      # idle — with no pending bell to clear. Left unguarded, that lone
      # `working` overwrites idle and sticks forever: the main Stop won't fire
      # again and no further subagents remain to correct it (observed live:
      # idle at T, then a subagent `working` at T+2s, frozen ⏳ for 28 min).
      #
      # The distinguisher is the actor. The main agent's legitimate
      # start-of-turn `working` (UserPromptSubmit, fired right after the
      # SessionStart `idle`) is always actor=__main__, so it must pass through.
      # Only a *subagent* working (actor=<hex>) arriving while the session's
      # logical state is already settled (idle/watching) is a stray — during an
      # active turn the main agent is `working`, so a real subagent working sees
      # logical=working and is not suppressed. Mirror the settled state so the
      # title/state-file stay correct; event-log dedup drops the duplicate.
      _logical=""
      [ -f "$session_state_file" ] && _logical=$(head -n1 "$session_state_file" 2>/dev/null)
      case "$_logical" in
        idle|watching)
          effective_status="$_logical"
          __trace "stray subagent working suppressed (actor=$actor, logical=$_logical)"
          ;;
      esac
      unset _logical
    fi
    ;;
  idle|end)
    rm -rf "$pending_dir" 2>/dev/null
    __trace "pending cleared (status=$status)"
    ;;
esac

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
#   Line 3: the claude ancestor PID (stored for all write states).
#           sweep-bell-state.sh uses it to prune orphaned files when the
#           process has exited. The plugin also uses it for watching files
#           to detect when the monitored process has exited.
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
      input)    _write_state "🔔 $base_title" "input"   "$claude_pid" ;;
      working)  _write_state "⏳ $base_title" "working" "$claude_pid" ;;
      watching) _write_state "👀 $base_title" "watching" "$claude_pid" ;;
      idle)     _write_state "$base_title"    "idle"    "$claude_pid" ;;
      end)      _remove_state ;;
      *)        __trace "state-file unchanged (status=$effective_status)" ;;
    esac
    ;;
  *)
    # notifs mode (default): only "needs attention" writes a state file.
    # watching is a refinement of idle and is not surfaced in notifs mode.
    case "$effective_status" in
      input)
        _write_state "🔔 $base_title" "input" "$claude_pid"
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
    # SESSION_STATE_DIR / session_state_file hoisted above (near the pending set).
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
if [ "$status" = "query" ]; then
  echo "$base_title"
  echo "$summary"
else
  # Emit terminalSequence JSON for Claude Code 2.1.141+ direct hook calls.
  # Claude Code writes the sequence to the terminal on our behalf, which is
  # race-free and works without a controlling TTY. The /dev/tty write above
  # stays as the fallback for older versions and subprocess invocations.
  _seq=$(printf '\033]2;%s\007' "$title")
  __trace "terminalSequence title=\"$title\""
  jq -nc --arg seq "$_seq" '{terminalSequence: $seq}'
  printf '%s title="%s" session=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$title" "$short_id" \
    >> "${CCG_DIR:-$HOME/.claude/.ccg}/termseq.log" 2>/dev/null
  unset _seq
fi
