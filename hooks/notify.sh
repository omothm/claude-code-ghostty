#!/bin/bash
# Base notification script for Ghostty tab-targeted notifications.
# Usage: notify.sh <icon> <default_message> [tab_status] [required_notification_type]
#
# Reads hook JSON from stdin. Sends a macOS notification via terminal-notifier
# and skips if the user is already looking at the tab.
#
# Arguments:
#   icon                        Emoji for the notification title (e.g., 🔔 ✅)
#   default_message             Fallback message if none in the hook JSON
#   tab_status (optional)       If set, updates the tab title to this status
#   required_notification_type  If set, exit unless notification_type matches

icon="$1"
default_message="$2"
tab_status="$3"
required_type="$4"

# Read JSON data from stdin
input=$(cat)

# Exit if no input
if [ -z "$input" ]; then
  exit 0
fi

# Check if this is from Cursor (has cursor_version field) - exit if so
cursor_version=$(echo "$input" | jq -r '.cursor_version // empty' 2>/dev/null)
if [ -n "$cursor_version" ]; then
  exit 0
fi

# Filter by notification type if required
if [ -n "$required_type" ]; then
  notification_type=$(echo "$input" | jq -r '.notification_type // empty' 2>/dev/null)
  if [ "$notification_type" != "$required_type" ]; then
    exit 0
  fi
fi

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

# Skip if user is looking at this exact tab
active_app=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null)
if [ "$active_app" = "ghostty" ]; then
  this_tab_active=$(osascript -e '
    tell application "System Events"
      tell process "Ghostty"
        set tabButtons to every radio button of tab group "tab bar" of front window
        repeat with btn in tabButtons
          if name of btn contains "'"$match_key"'" and value of btn is true then
            return 1
          end if
        end repeat
      end tell
    end tell
    return 0' 2>/dev/null)

  if [ "$this_tab_active" = "1" ]; then
    exit 0
  fi
fi

# Update tab title if requested
if [ -n "$tab_status" ]; then
  "$(dirname "$0")/tab-title.sh" "$tab_status" "$session_id" > /dev/null
fi

# Send notification - clicking will activate Ghostty and focus the correct tab
terminal-notifier \
  -title "$icon $title" \
  -message "$message" \
  -subtitle "$subtitle" \
  -appIcon /Applications/Ghostty.app/Contents/Resources/AppIcon.icns \
  -execute "$HOME/.claude/hooks/focus-ghostty-tab.sh '$match_key'"

exit 0
