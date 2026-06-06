#!/bin/bash
# Base notification script for Ghostty tab-targeted notifications.
# Usage: notify.sh <icon> <default_message> [tab_status] [mode]
#
# Reads hook JSON from stdin. Sends a macOS notification via terminal-notifier.
#
# Arguments:
#   icon             Emoji for the notification title (e.g., 🔔 ✅ ❌)
#   default_message  Fallback message if none in the hook JSON
#   tab_status       If set, updates the tab title to this status
#   mode             If "error": extract the latest API error from the
#                    session transcript into a readable log file, surface it
#                    as the notification message, and make clicking focus the
#                    tab AND open that log. Used by the StopFailure hook.
#
# Debug: set BELL_TRACE=1 to append diagnostics to $BELL_TRACE_LOG
# (defaults to /tmp/bell-trace.log).

__N=notify.sh
__trace() {
  [ -n "$BELL_TRACE" ] || return 0
  printf '%s [%s pid=%s ppid=%s] %s\n' \
    "$(gdate +%s.%3N 2>/dev/null || date +%s)" "$__N" "$$" "$PPID" "$*" \
    >> "${BELL_TRACE_LOG:-/tmp/bell-trace.log}"
}

# Always-on diagnostic log (independent of BELL_TRACE). Records every
# notification the hook builds so click-navigation failures can be diagnosed
# after the fact without having to reproduce with tracing enabled. Cheap:
# a handful of lines per notification. Path overridable via CCG_DIR.
__dbg() {
  local _d="${CCG_DIR:-$HOME/.claude/.ccg}"
  [ -d "$_d" ] || mkdir -p "$_d" 2>/dev/null
  printf '%s [%s pid=%s] %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$__N" "$$" "$*" \
    >> "$_d/notify-debug.log" 2>/dev/null
}
__trace "entry argc=$# args=[$*]"
__dbg "entry argc=$# args=[$*]"

icon="$1"
default_message="$2"
tab_status="${3-}"
mode="${4-}"

# Read JSON data from stdin
input=$(cat)

# Exit if no input
if [ -z "$input" ]; then
  __trace "early-exit reason=empty-stdin"
  exit 0
fi

# Check if this is from Cursor (has cursor_version field) - exit if so
cursor_version=$(echo "$input" | jq -r '.cursor_version // empty' 2>/dev/null)
if [ -n "$cursor_version" ]; then
  __trace "early-exit reason=cursor cursor_version=$cursor_version"
  exit 0
fi

__trace "notification_type=$(echo "$input" | jq -r '.notification_type // empty' 2>/dev/null)"

# Extract fields
title=$(echo "$input" | jq -r '.title // "Claude Code"' 2>/dev/null)
session_id=$(echo "$input" | jq -r '.session_id // "unknown"' 2>/dev/null)
# Subagent-issued permission prompts carry an agent_id; the main agent's don't.
# Forwarded to tab-title.sh so the pending-input set is keyed per-actor (a
# parallel subagent's PostToolUse must not clear a different actor's bell).
agent_id=$(echo "$input" | jq -r '.agent_id // empty' 2>/dev/null)
cwd=$(echo "$input" | jq -r '.cwd // "unknown"' 2>/dev/null)
message=$(echo "$input" | jq -r --arg def "$default_message" '.message // $def' 2>/dev/null)

# In error mode, pull the latest API error out of the session transcript and
# write it to a readable log we can open on click. The transcript is the only
# place the actual error text (rate limit, auth failure, etc.) lives; the hook
# JSON only carries the generic "stopped" signal.
error_log=""
if [ "$mode" = "error" ]; then
  transcript_path=$(echo "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
  __trace "error mode transcript_path=$transcript_path"
  __dbg "error mode: transcript_path from payload=[$transcript_path] session_id=$session_id cwd=$cwd"

  # Fallback: StopFailure may not always carry transcript_path. The transcript
  # path is deterministic — ~/.claude/projects/<cwd-with-/-as-->/<sid>.jsonl —
  # so derive it from cwd + session_id when the field is missing or stale.
  if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    if [ "$cwd" != "unknown" ] && [ "$session_id" != "unknown" ]; then
      mangled=$(printf '%s' "$cwd" | sed 's#/#-#g')
      derived="$HOME/.claude/projects/$mangled/$session_id.jsonl"
      __dbg "error mode: deriving transcript path -> $derived (exists=$([ -f "$derived" ] && echo yes || echo no))"
      [ -f "$derived" ] && transcript_path="$derived"
    fi
  fi

  if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    # Race: StopFailure fires and runs this hook concurrently with Claude Code
    # writing the API-error entry to the transcript. Empirically the entry's
    # timestamp lands in the same ~100 ms as the hook invocation, so a single
    # read often misses it (the file is flushed a beat later). Poll for up to
    # ~3 s (30 × 100 ms) for the error text to appear before giving up.
    error_text=""
    attempt=0
    while [ "$attempt" -lt 30 ]; do
      error_text=$(jq -rs '
        [ .[]
          | select(.isApiErrorMessage == true)
          | (.message.content // [])
          | map(select(.type == "text") | .text)
          | join("\n") ]
        | last // empty' "$transcript_path" 2>/dev/null)
      [ -n "$error_text" ] && break
      attempt=$((attempt + 1))
      sleep 0.1
    done
    if [ -n "$error_text" ]; then
      message="$error_text"
      error_log="${CCG_DIR:-$HOME/.claude/.ccg}/last-error-${session_id}.log"
      mkdir -p "$(dirname "$error_log")" 2>/dev/null
      {
        printf 'Session: %s\n' "$session_id"
        printf 'Directory: %s\n' "$cwd"
        printf 'Transcript: %s\n' "$transcript_path"
        printf '%s\n\n' "----------------------------------------"
        printf '%s\n' "$error_text"
      } > "$error_log" 2>/dev/null
      __trace "wrote error_log=$error_log"
      __dbg "error mode: wrote error_log=$error_log after ${attempt} retries (error_text len=${#error_text})"
    else
      __trace "error mode: no API error text found in transcript"
      __dbg "error mode: NO API-error text found in $transcript_path after ${attempt} retries"
    fi
  else
    __dbg "error mode: no usable transcript -> falling back to generic message, no log"
  fi
fi

dir_name=$(basename "$cwd")
short_id=$(echo "$session_id" | cut -c1-8)
tab_output=$("$(dirname "$0")/tab-title.sh" query "$session_id")
session_summary=$(echo "$tab_output" | sed -n '2p')
if [ -n "$session_summary" ]; then
  subtitle="$session_summary ($dir_name)"
  match_key="$session_summary"
else
  subtitle="$short_id ($dir_name)"
  match_key="$short_id"
fi
__dbg "match_key=[$match_key] (session_summary=[$session_summary] short_id=$short_id dir=$dir_name)"

# Update tab title if requested
if [ -n "$tab_status" ]; then
  __trace "calling tab-title.sh $tab_status (agent_id=${agent_id:-<none>})"
  "$(dirname "$0")/tab-title.sh" "$tab_status" "$session_id" "$agent_id" > /dev/null
  __trace "tab-title.sh returned rc=$?"
fi

# Clicking the notification focuses the correct tab. In error mode, also open
# the extracted error log (single-quoted to survive terminal-notifier's shell).
execute_cmd="$HOME/.claude/hooks/focus-ghostty-tab.sh '$match_key'"
if [ -n "$error_log" ]; then
  execute_cmd="$execute_cmd; open -t '$error_log'"
fi

# Send notification - clicking will activate Ghostty and focus the correct tab
__trace "sending terminal-notifier title=\"$icon $title\" match_key=$match_key"
__dbg "execute_cmd=[$execute_cmd]"
terminal-notifier \
  -title "$icon $title" \
  -message "$message" \
  -subtitle "$subtitle" \
  -group "ccg-$session_id" \
  -appIcon /Applications/Ghostty.app/Contents/Resources/AppIcon.icns \
  -execute "$execute_cmd"
tn_rc=$?
__trace "terminal-notifier rc=$tn_rc"
__dbg "terminal-notifier rc=$tn_rc"

__trace "exit"
exit 0
