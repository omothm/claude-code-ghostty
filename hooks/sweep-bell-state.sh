#!/bin/bash
# Sweep stale entries from ~/.claude/bell-state/.
#
# A state file becomes stale when the Claude session that wrote it ended
# without firing the `end` hook (process killed, Ghostty tab closed
# mid-prompt, macOS reboot while awaiting input, etc.). Without cleanup it
# lingers as a phantom dropdown entry.
#
# Cleanup is a single hard-age pass: any file older than 12h is deleted
# unconditionally. The normal cleanup path is `tab-title.sh end` invoked
# from the SessionEnd hook, which removes the state file the moment a
# session exits cleanly — so this pass only matters for crashes and
# similar irregular exits.
#
# History: a previous version of this script also ran an "AX-verified"
# pass that queried Ghostty's tab tree via AppleScript and pruned any
# state file whose title wasn't present in the result. The AppleScript
# query intermittently returns partial tab lists (radio-button
# enumeration races with Ghostty's own tab-bar redraws), and ~1% of
# queries dropped multiple tabs. That made the pass spuriously delete
# state files for sessions that were still alive, so the menubar would
# silently lose idle sessions over time. The pass has been removed.
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

# Hard age cap (12h): delete any state file older than this unconditionally.
# Anything still in the dir after 12h is almost certainly a phantom from a
# session that didn't fire `end` — and even on the off chance it's a real
# long-lived idle session, the next user interaction (UserPromptSubmit /
# PostToolUse / Stop) re-creates the state file with the current state.
while IFS= read -r f; do
  [ -z "$f" ] && continue
  rm -f "$f" && pruned=$((pruned + 1))
  __trace "hard-expire: $f"
done < <(find "$STATE_DIR" -type f -mmin +720 2>/dev/null)

# PID-liveness pass: delete state files whose owning claude process has exited.
# Line 3 holds the ancestor claude PID (written by tab-title.sh for all write
# states). This catches orphaned sessions within one sweep cycle (~30s) rather
# than waiting the full 12h hard-age cap.
while IFS= read -r f; do
  [ -z "$f" ] && continue
  cpid=$(sed -n '3p' "$f" 2>/dev/null | tr -d ' ')
  [ -n "$cpid" ] || continue                       # no PID stored — legacy or partial write; skip
  kill -0 "$cpid" 2>/dev/null && continue           # process still alive; leave it
  rm -f "$f" && pruned=$((pruned + 1))
  __trace "pid-expire: $f (pid=$cpid dead)"
done < <(find "$STATE_DIR" -type f 2>/dev/null)

__trace "exit pruned=$pruned"

# Pending-input set cleanup. tab-title.sh keeps a per-session dir of unanswered
# permission requests at ~/.claude/.ccg/pending/<sid>/ to hold the bell up while
# parallel subagents work. It's cleared on idle/end, but a crashed session (no
# `end` hook) leaks its dir. Hard-age prune mirrors the state-file cap: any
# pending dir untouched for 12h belongs to a session that's long gone. This is
# tidy-up only — a dead session's pending dir is never read again — so it
# doesn't trigger a menubar refresh.
PENDING_DIR="${CCG_PENDING_DIR:-$HOME/.claude/.ccg/pending}"
if [ -d "$PENDING_DIR" ]; then
  while IFS= read -r d; do
    [ -z "$d" ] && continue
    rm -rf "$d"
    __trace "pending hard-expire: $d"
  done < <(find "$PENDING_DIR" -mindepth 1 -maxdepth 1 -type d -mmin +720 2>/dev/null)
fi

# If anything was removed, nudge SwiftBar so the dropdown reflects reality
# on the next plugin run.
if [ "$pruned" -gt 0 ]; then
  "$HOOKS_DIR/refresh-menubar.sh"
fi
