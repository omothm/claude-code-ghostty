#!/bin/bash
# Activate Ghostty and focus a tab whose title contains the given string.
# Usage: focus-ghostty-tab.sh <tab_title>
tab_title="$1"
osascript <<EOF
tell application "Ghostty" to activate
delay 0.3
tell application "System Events"
    tell process "Ghostty"
        set tabButtons to every radio button of tab group "tab bar" of front window
        repeat with btn in tabButtons
            if name of btn contains "$tab_title" then
                click btn
                exit repeat
            end if
        end repeat
    end tell
end tell
EOF
