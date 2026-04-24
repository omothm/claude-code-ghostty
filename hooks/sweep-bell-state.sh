#!/bin/bash
# Sweep stale entries from ~/.claude/bell-state/.
#
# A state file becomes stale when the Claude session that wrote it ended
# without firing the `idle` / `working` hook (process killed, Ghostty tab
# closed mid-prompt, macOS reboot while awaiting input, etc.). Without
# cleanup it lingers as a phantom dropdown entry.
#
# Two cleanup passes:
#   1. Hard age cap (24h): deletes any file this old regardless of AX,
#      so leftover state from a prior uptime gets cleared on next plugin run.
#   2. AX verification (5 min grace period): deletes files whose title is
#      not present in Ghostty's current tab tree. The grace period tolerates
#      the macOS Accessibility API lag we observed (up to ~60s after an ANSI
#      title write while Ghostty is backgrounded).
#
# Invoked by the SwiftBar plugin as a background process. Safe to run
# standalone. No-op when the state dir is empty.
#
# Debug: set BELL_TRACE=1 to append diagnostics to $BELL_TRACE_LOG
# (defaults to /tmp/bell-trace.log).

__N=sweep-bell-state.sh
__trace() {
  [ -n "$BELL_TRACE" ] || return 0
  printf '%s [%s pid=%s ppid=%s] %s\n' \
    "$(gdate +%s.%3N 2>/dev/null || date +%s)" "$__N" "$$" "$PPID" "$*" \
    >> "${BELL_TRACE_LOG:-/tmp/bell-trace.log}"
}

STATE_DIR="${BELL_STATE_DIR:-$HOME/.claude/bell-state}"
HOOKS_DIR="$(dirname "$0")"

[ -d "$STATE_DIR" ] || exit 0

__trace "entry"
pruned=0

# Pass 1: hard age cap (24h).
while IFS= read -r f; do
  [ -z "$f" ] && continue
  rm -f "$f" && pruned=$((pruned + 1))
  __trace "hard-expire: $f"
done < <(find "$STATE_DIR" -type f -mmin +1440 2>/dev/null)

# Pass 2: AX verification for files past the 5-min grace period. Skip
# (conservatively) if AX returns empty — Ghostty isn't running, accessibility
# permissions aren't granted, or a transient error. Better to leave a phantom
# for one more cycle than wrongly nuke a live bell.
ax_titles=$(osascript <<'AXEOF' 2>/dev/null
set found to {}
tell application "System Events"
    if not (exists process "Ghostty") then return ""
    tell process "Ghostty"
        repeat with w in (every window)
            try
                set tabButtons to every radio button of tab group "tab bar" of w
                repeat with btn in tabButtons
                    set end of found to (name of btn)
                end repeat
            on error
                try
                    set end of found to (name of w)
                end try
            end try
        end repeat
    end tell
end tell
set text item delimiters of AppleScript to linefeed
return found as text
AXEOF
)
if [ -n "$ax_titles" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] || [ ! -f "$f" ] && continue
    title=$(head -n1 "$f" 2>/dev/null)
    [ -z "$title" ] && continue
    if ! printf '%s\n' "$ax_titles" | grep -qF -- "$title"; then
      rm -f "$f" && pruned=$((pruned + 1))
      __trace "ax-prune: $f (title=\"$title\" not present in Ghostty AX)"
    fi
  done < <(find "$STATE_DIR" -type f -mmin +5 2>/dev/null)
else
  __trace "ax empty — skipping AX pass (Ghostty not running, no permissions, or transient error)"
fi

__trace "exit pruned=$pruned"

# If anything was removed, nudge SwiftBar so the dropdown reflects reality
# on the next plugin run.
if [ "$pruned" -gt 0 ]; then
  "$HOOKS_DIR/refresh-menubar.sh"
fi
