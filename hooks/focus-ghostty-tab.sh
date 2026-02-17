#!/bin/bash
# Activate Ghostty and focus a tab whose title contains the given string.
# Usage: focus-ghostty-tab.sh <tab_title>
tab_title="$1"
osascript <<EOF
tell application "Ghostty" to activate
delay 0.3
tell application "System Events"
    tell process "Ghostty"
        set allWindows to every window
        -- First pass: search windows with tab bars (multi-tab windows)
        repeat with w in allWindows
            try
                set tabButtons to every radio button of tab group "tab bar" of w
                repeat with btn in tabButtons
                    if name of btn contains "$tab_title" then
                        perform action "AXRaise" of w
                        delay 0.1
                        click btn
                        return
                    end if
                end repeat
            end try
        end repeat
        -- Second pass: match by window title (single-tab windows)
        repeat with w in allWindows
            if name of w contains "$tab_title" then
                perform action "AXRaise" of w
                return
            end if
        end repeat
    end tell
end tell
EOF
