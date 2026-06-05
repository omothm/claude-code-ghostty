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
__trace "entry argc=$# args=[$*]"

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
  if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    # Last assistant entry flagged as an API error → its text content.
    error_text=$(jq -rs '
      [ .[]
        | select(.isApiErrorMessage == true)
        | (.message.content // [])
        | map(select(.type == "text") | .text)
        | join("\n") ]
      | last // empty' "$transcript_path" 2>/dev/null)
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
    else
      __trace "error mode: no API error text found in transcript"
    fi
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

# Update tab title if requested
if [ -n "$tab_status" ]; then
  __trace "calling tab-title.sh $tab_status"
  "$(dirname "$0")/tab-title.sh" "$tab_status" "$session_id" > /dev/null
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
terminal-notifier \
  -title "$icon $title" \
  -message "$message" \
  -subtitle "$subtitle" \
  -group "ccg-$session_id" \
  -appIcon /Applications/Ghostty.app/Contents/Resources/AppIcon.icns \
  -execute "$execute_cmd"
__trace "terminal-notifier rc=$?"

__trace "exit"
exit 0
