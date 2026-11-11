#!/bin/bash
# Activate Ghostty and focus a tab whose title contains the given string.
# Usage: focus-ghostty-tab.sh <tab_title>
#
# Runs ON NOTIFICATION CLICK (via terminal-notifier -execute, which invokes
# it through /bin/sh -c). Always-on logging to ~/.claude/.ccg/focus-debug.log
# records the match key, every tab/window title Ghostty reports, and the
# outcome — this is the only window into why a click fails to navigate, since
# the click happens outside any traced hook invocation.
# Path overridable via CCG_DIR.

tab_title="$1"

__dbg() {
  local _d="${CCG_DIR:-$HOME/.claude/.ccg}"
  [ -d "$_d" ] || mkdir -p "$_d" 2>/dev/null
  printf '%s [focus pid=%s] %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$*" \
    >> "$_d/focus-debug.log" 2>/dev/null
}

__dbg "=== click: searching for tab matching [$tab_title] ==="

# Uses Ghostty's own AppleScript dictionary (Ghostty 1.4+), not System Events:
# titles come straight from Ghostty (no AX lag) and no settle delay is needed.
# The title goes in argv, never into the script source.
ascript_out=$(osascript - "$tab_title" <<'EOF' 2>&1
on run argv
    set needle to item 1 of argv
    set diag to ""
    tell application "Ghostty"
        repeat with w in windows
            set ns to name of every tab of w
            set diag to diag & "window [" & (name of w) & "] tabs=" & (count of ns) & linefeed
            repeat with i from 1 to count of ns
                set diag to diag & "  tab=[" & (item i of ns) & "]" & linefeed
                if item i of ns contains needle then
                    -- Activate the app first so macOS switches to the Space of the window;
                    -- raising the window while Ghostty is inactive pulls it onto the current one.
                    activate
                    select tab (tab i of w)
                    activate window w
                    return diag & "RESULT: matched-tab [" & (item i of ns) & "]"
                end if
            end repeat
        end repeat
    end tell
    return diag & "RESULT: NO MATCH for [" & needle & "]"
end run
EOF
)
rc=$?

# Log each line of the AppleScript diagnostic dump.
while IFS= read -r _line; do
  [ -n "$_line" ] && __dbg "$_line"
done <<< "$ascript_out"
__dbg "osascript rc=$rc"
