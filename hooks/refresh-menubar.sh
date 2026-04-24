#!/bin/bash
# Nudge the optional SwiftBar menubar plugin (ghostty-bells) to refresh.
# No-op when SwiftBar isn't installed, so hooks stay safe for users who
# haven't opted into the menubar indicator.
#
# Debug: set BELL_TRACE=1 to append diagnostics to $BELL_TRACE_LOG
# (defaults to /tmp/bell-trace.log).

__N=refresh-menubar.sh
__trace() {
  [ -n "$BELL_TRACE" ] || return 0
  printf '%s [%s pid=%s ppid=%s] %s\n' \
    "$(gdate +%s.%3N 2>/dev/null || date +%s)" "$__N" "$$" "$PPID" "$*" \
    >> "${BELL_TRACE_LOG:-/tmp/bell-trace.log}"
}
__trace "entry"

if [ -d "/Applications/SwiftBar.app" ] || [ -d "$HOME/Applications/SwiftBar.app" ]; then
  __trace "gate=opted-in swiftbar_running_pid=$(pgrep -x SwiftBar 2>/dev/null | head -1)"
  open -g "swiftbar://refreshallplugins" >/dev/null 2>&1
  __trace "open-exit=$?"
else
  __trace "gate=not-installed skip"
fi
__trace "exit"
exit 0
