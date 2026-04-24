#!/bin/bash
# SwiftBar plugin: menubar dropdown of Ghostty Claude Code sessions awaiting input.
# Reads per-session state files written by ~/.claude/hooks/tab-title.sh and
# emits one dropdown entry per session currently in bell state. Hidden when
# the state directory is empty.
#
# This bypasses the macOS Accessibility API (AppleScript tab enumeration) to
# avoid multi-second lag reflecting ANSI tab-title changes while Ghostty is
# backgrounded. Clicking an entry invokes focus-ghostty-tab.sh, which still
# uses AX — that's fine because bringing Ghostty forward refreshes AX.
#
# Install: copy to SwiftBar's plugins directory and make executable.
# The filename suffix (.30s.sh) sets the background refresh interval — a
# safety net in case hook-driven refreshes miss (e.g. crashed session).
#
# Debug: set BELL_TRACE=1 to append diagnostics to $BELL_TRACE_LOG
# (defaults to /tmp/bell-trace.log).

__N=ghostty-bells.30s.sh
__trace() {
  [ -n "$BELL_TRACE" ] || return 0
  printf '%s [%s pid=%s ppid=%s] %s\n' \
    "$(gdate +%s.%3N 2>/dev/null || date +%s)" "$__N" "$$" "$PPID" "$*" \
    >> "${BELL_TRACE_LOG:-/tmp/bell-trace.log}"
}
__trace "entry swiftbar_ppid=$PPID"

HOOKS_DIR="${GHOSTTY_HOOKS_DIR:-$HOME/.claude/hooks}"
FOCUS="$HOOKS_DIR/focus-ghostty-tab.sh"
STATE_DIR="${BELL_STATE_DIR:-$HOME/.claude/bell-state}"

titles=""
if [ -d "$STATE_DIR" ]; then
    for f in "$STATE_DIR"/*; do
        [ -f "$f" ] || continue
        line=$(head -n1 "$f" 2>/dev/null)
        [ -n "$line" ] && titles="${titles}${line}"$'\n'
    done
    titles="${titles%$'\n'}"
fi
__trace "state-read bytes=${#titles}"

if [ -z "$titles" ]; then
    __trace "result=hidden (zero bells)"
    exit 0
fi

count=$(printf '%s\n' "$titles" | grep -c '🔔')
__trace "result=visible count=$count"
echo ":bell.fill: ${count}"
echo "---"

while IFS= read -r title; do
    [ -z "$title" ] && continue
    # Strip leading 🔔 and swap " | " so it doesn't collide with SwiftBar's
    # param separator.
    display="${title#🔔 }"
    display="${display// | / — }"
    printf '%s | shell="%s" param1="%s" terminal=false\n' "$display" "$FOCUS" "$title"
done <<< "$titles"

# Fire stale-state cleanup in the background so menubar rendering isn't
# delayed by the ~300 ms AX enumeration. If anything is pruned, the sweep
# itself nudges SwiftBar to re-read.
"$HOOKS_DIR/sweep-bell-state.sh" </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true
__trace "sweep-dispatched (background)"
__trace "exit"
