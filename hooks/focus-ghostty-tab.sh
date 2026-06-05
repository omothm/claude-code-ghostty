#!/bin/bash
# Activate Ghostty and focus a tab whose title contains the given string.
# Usage: focus-ghostty-tab.sh <tab_title>
#
# Runs ON NOTIFICATION CLICK (via terminal-notifier -execute, which invokes
# it through /bin/sh -c). Always-on logging to ~/.claude/.ccg/focus-debug.log
# records the match key, every tab/window title the Accessibility API reports,
# and the outcome — this is the only window into why a click fails to
# navigate, since the click happens outside any traced hook invocation.
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

# The AppleScript both performs the navigation and emits a diagnostic dump of
# what the Accessibility API actually sees (window names + tab-button names),
# plus a final RESULT line. We capture stdout so the shell side can log it.
ascript_out=$(osascript <<EOF 2>&1
on logLine(s)
    return s & linefeed
end logLine

set diag to ""
tell application "Ghostty" to activate
delay 0.3
tell application "System Events"
    tell process "Ghostty"
        set allWindows to every window
        set diag to diag & my logLine("windows=" & (count of allWindows))
        -- First pass: search windows with tab bars (multi-tab windows)
        repeat with w in allWindows
            try
                set wname to name of w
            on error
                set wname to "<no-name>"
            end try
            try
                set tabButtons to every radio button of tab group "tab bar" of w
                set diag to diag & my logLine("window [" & wname & "] tabs=" & (count of tabButtons))
                repeat with btn in tabButtons
                    set bname to name of btn
                    set diag to diag & my logLine("  tab=[" & bname & "]")
                    if bname contains "$tab_title" then
                        perform action "AXRaise" of w
                        delay 0.1
                        click btn
                        set diag to diag & my logLine("RESULT: matched-tab [" & bname & "]")
                        return diag
                    end if
                end repeat
            on error errMsg
                set diag to diag & my logLine("window [" & wname & "] no-tab-bar (" & errMsg & ")")
            end try
        end repeat
        -- Second pass: match by window title (single-tab windows)
        repeat with w in allWindows
            try
                set wname to name of w
            on error
                set wname to "<no-name>"
            end try
            set diag to diag & my logLine("window-title-check [" & wname & "]")
            if wname contains "$tab_title" then
                perform action "AXRaise" of w
                set diag to diag & my logLine("RESULT: matched-window [" & wname & "]")
                return diag
            end if
        end repeat
    end tell
end tell
set diag to diag & my logLine("RESULT: NO MATCH for [$tab_title]")
return diag
EOF
)

rc=$?
# Log each line of the AppleScript diagnostic dump.
while IFS= read -r _line; do
  [ -n "$_line" ] && __dbg "$_line"
done <<< "$ascript_out"
__dbg "osascript rc=$rc"
