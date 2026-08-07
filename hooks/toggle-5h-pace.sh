#!/bin/bash
# Toggles the show5hPace boolean in ~/.claude/.ccg/config.json, then triggers
# an immediate SwiftBar refresh so the checkbox state updates in the dropdown.
#
# Called from the SwiftBar plugin dropdown entry:
#   shell="~/.claude/hooks/toggle-5h-pace.sh" terminal=false refresh=true
#
# Environment:
#   BELL_CONFIG — config file path (default ~/.claude/.ccg/config.json)

set -u

BELL_CONFIG="${BELL_CONFIG:-$HOME/.claude/.ccg/config.json}"
HOOKS_DIR="${GHOSTTY_HOOKS_DIR:-$HOME/.claude/hooks}"

# Read current state; default to false when the key is absent.
current=$(jq -r '.show5hPace // false' "$BELL_CONFIG" 2>/dev/null)

# Flip it.
if [ "$current" = "true" ]; then
  next=false
else
  next=true
fi

# Write back atomically (write to tmp, then mv).
tmp=$(mktemp "${BELL_CONFIG}.XXXXXX")
jq --argjson v "$next" '.show5hPace = $v' "$BELL_CONFIG" > "$tmp" 2>/dev/null && \
  mv "$tmp" "$BELL_CONFIG" || rm -f "$tmp"

# Push-refresh SwiftBar so the checkbox label reflects the new state immediately.
"$HOOKS_DIR/refresh-menubar.sh" 2>/dev/null
