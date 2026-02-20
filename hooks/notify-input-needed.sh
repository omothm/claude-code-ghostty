#!/bin/bash
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

# Get notification type
notification_type=$(echo "$input" | jq -r '.notification_type // empty' 2>/dev/null)

# Only notify for permission prompts, not idle prompts
if [ "$notification_type" != "permission_prompt" ]; then
  exit 0
fi

# Extract fields
title=$(echo "$input" | jq -r '.title // "Claude Code"')
session_id=$(echo "$input" | jq -r '.session_id // "unknown"')
cwd=$(echo "$input" | jq -r '.cwd // "unknown"')
message=$(echo "$input" | jq -r '.message // "Needs your input"')

dir_name=$(basename "$cwd")
short_id=$(echo "$session_id" | cut -c1-8)
tab_title=$("$(dirname "$0")/tab-title.sh" query "$session_id")

# Skip if user is looking at this exact tab
active_app=$(osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null)
if [ "$active_app" = "ghostty" ]; then
  this_tab_active=$(osascript -e '
    tell application "System Events"
      tell process "Ghostty"
        set tabButtons to every radio button of tab group "tab bar" of front window
        repeat with btn in tabButtons
          if name of btn contains "'"$tab_title"'" and value of btn is true then
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

# Mark tab as waiting for input
"$(dirname "$0")/tab-title.sh" input "$session_id" > /dev/null

# Send notification - clicking will activate Ghostty and focus the correct tab
terminal-notifier \
  -title "🔔 $title" \
  -message "$message" \
  -subtitle "$dir_name [$short_id]" \
  -appIcon /Applications/Ghostty.app/Contents/Resources/AppIcon.icns \
  -execute "$HOME/.claude/hooks/focus-ghostty-tab.sh '$tab_title'"

exit 0
