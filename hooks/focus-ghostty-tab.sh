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

# Finds and selects the tab via Ghostty's AppleScript dictionary (Ghostty 1.4+), so
# titles come straight from Ghostty with no AX lag. System Events is only used to
# detect that the Space switch has finished.
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
                    set t to tab i of w
                    set alreadyFront to (get selected of t) and ((get id of w) is (get id of front window))
                    -- open -a goes through LaunchServices like a Dock click, which switches to
                    -- the Space of the window. frontmost flips before that switch finishes, so
                    -- ordering a window too early drags it onto the current Space instead.
                    tell me to do shell script "/usr/bin/open -a Ghostty"
                    if alreadyFront then
                        set diag to diag & "already front, no reorder" & linefeed
                    else
                        -- AX lists only windows on the current Space, so a visible
                        -- Ghostty window means the switch is done. Wait max ~1 s.
                        set waited to 0
                        tell application "System Events"
                            repeat 50 times
                                if exists window 1 of process "Ghostty" then exit repeat
                                delay 0.02
                                set waited to waited + 1
                            end repeat
                        end tell
                        set diag to diag & "space ready after " & (waited * 20) & " ms" & linefeed
                        select tab t
                        activate window w
                    end if
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
