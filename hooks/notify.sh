#!/bin/bash
# Base notification script for Ghostty tab-targeted notifications.
# Usage: notify.sh <icon> <default_message> [tab_status]
#
# Reads hook JSON from stdin. Sends a macOS notification via terminal-notifier.
#
# Arguments:
#   icon             Emoji for the notification title (e.g., 🔔 ✅)
#   default_message  Fallback message if none in the hook JSON
#   tab_status       If set, updates the tab title to this status
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
tab_status="$3"

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

# Send notification - clicking will activate Ghostty and focus the correct tab
__trace "sending terminal-notifier title=\"$icon $title\" match_key=$match_key"
terminal-notifier \
  -title "$icon $title" \
  -message "$message" \
  -subtitle "$subtitle" \
  -group "ccg-$session_id" \
  -appIcon /Applications/Ghostty.app/Contents/Resources/AppIcon.icns \
  -execute "$HOME/.claude/hooks/focus-ghostty-tab.sh '$match_key'"
__trace "terminal-notifier rc=$?"

__trace "exit"
exit 0
