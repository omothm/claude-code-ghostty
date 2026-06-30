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
SESSION_STATE_DIR="${CCG_SESSION_STATE_DIR:-$HOME/.claude/.ccg/sessions}"
EVENT_LOG="${CCG_EVENT_LOG:-$HOME/.claude/.ccg/events.jsonl}"

# Staleness cap (minutes) for state files that carry NO claude PID. Under the
# current hooks every live session writes its ancestor claude PID (bell-state
# line 3, logical-state line 2), so a file WITHOUT one is either a pre-PID
# legacy file or a rare _find_claude_pid failure (e.g. the claude ancestor had
# already exited when the hook fired). We can't kill -0 it, so we can't reap it
# the instant the process dies the way we do for PID-bearing files — but a live
# session re-writes its file (with a PID) on its next state change, so a no-PID
# file untouched this long is stale. Far shorter than the 12h hard-age cap so
# these phantoms (e.g. a stuck "working" tile) clear from the menubar promptly.
# Overridable for the validator.
NO_PID_STALE_MIN="${CCG_NO_PID_STALE_MIN:-30}"

# Exit only if there's nothing to sweep in EITHER layer. The logical-state
# reconciliation pass below runs even in notifs mode, where no bell-state file
# is written for working/idle (so STATE_DIR may be empty) but logical-state
# files still exist.
[ -d "$STATE_DIR" ] || [ -d "$SESSION_STATE_DIR" ] || exit 0

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
  if [ -z "$cpid" ]; then
    # No PID to kill -0. Reap only if stale (see NO_PID_STALE_MIN); a freshly
    # written no-PID file might belong to a session that will rewrite it with a
    # PID on its next transition, so don't evict it immediately.
    if [ -n "$(find "$f" -mmin +"$NO_PID_STALE_MIN" 2>/dev/null)" ]; then
      rm -f "$f" && pruned=$((pruned + 1))
      __trace "no-pid-stale-expire: $f"
    fi
    continue
  fi
  kill -0 "$cpid" 2>/dev/null && continue           # process still alive; leave it
  rm -f "$f" && pruned=$((pruned + 1))
  __trace "pid-expire: $f (pid=$cpid dead)"
done < <(find "$STATE_DIR" -type f 2>/dev/null)

# Logical-state reconciliation pass: emit a synthetic `end` to events.jsonl for
# any session whose owning claude process is gone but that never fired the
# SessionEnd hook. Without this the dashboard's "right now" count diverges from
# the menubar: the menubar reads bell-state FILES (reaped above on PID death),
# but the dashboard reads the append-only events.jsonl, which only learns a
# session ended when an `end` line is appended. A crash/kill/closed-tab/reboot
# skips the SessionEnd hook, so the session's last logged state lingers as
# working/idle for the full 12h dashboard window. The dashboard is browser JS
# over HTTP and cannot probe a PID itself, so this is the only place liveness
# can be reconciled back into the log.
#
# Source of truth is the per-session logical-state file (~/.claude/.ccg/
# sessions/<sid>): line 1 = state, line 2 = ancestor claude PID (written by
# tab-title.sh). Liveness is the SAME signal the bell-state pass uses, so both
# layers converge by construction. The synthetic `end` ts is capped at
# mtime + 30 min (the file's mtime == the last logged transition, since dedup
# only rewrites it on real changes) to MATCH the dashboard's existing
# trailing-span cap (TRAILING_CAP_SEC in spanFor) — emitting at `now` would
# retroactively inflate the dead session's working-time, so it must not be used.
_now=$(date +%s)
if [ -d "$SESSION_STATE_DIR" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    state=$(sed -n '1p' "$f" 2>/dev/null | tr -d ' ')
    spid=$(sed -n '2p' "$f" 2>/dev/null | tr -d ' ')
    [ -n "$state" ] || continue                       # empty/partial; skip
    [ "$state" = "end" ] && continue                  # already ended (defensive)

    dead=0
    if [ -n "$spid" ]; then
      kill -0 "$spid" 2>/dev/null || dead=1            # PID stored: alive→keep, dead→reap
    else
      # No PID (legacy 1-line file or _find_claude_pid failure): can't prove
      # death, so fall back to the no-PID staleness cap — same threshold the
      # bell-state pass uses, so menubar and dashboard reap these in lockstep.
      [ -n "$(find "$f" -mmin +"$NO_PID_STALE_MIN" 2>/dev/null)" ] && dead=1
    fi
    [ "$dead" = "1" ] || continue

    # Synthetic `end` at last-transition + cap (not now). mtime == last logged ts.
    mtime=$(stat -f %m "$f" 2>/dev/null || echo "$_now")
    ts=$((mtime + 1800))
    [ "$ts" -gt "$_now" ] && ts="$_now"

    # Title/cwd carry no span for an `end` event and aren't displayed for ended
    # sessions; a placeholder is sufficient. Use the bell-state title if one
    # somehow survives, else a marker.
    sid=$(basename "$f")
    title="(reaped session)"
    [ -f "$STATE_DIR/$sid" ] && title=$(sed -n '1p' "$STATE_DIR/$sid" 2>/dev/null)
    mkdir -p "$(dirname "$EVENT_LOG")"
    jq -nc --arg ts "$ts" --arg sid "$sid" --arg title "$title" \
      '{ts: ($ts|tonumber), session_id: $sid, state: "end", title: $title, cwd: ""}' \
      >> "$EVENT_LOG" 2>/dev/null
    rm -f "$f" && pruned=$((pruned + 1))
    __trace "logical-reconcile: emitted end for $sid (pid=${spid:-<none>} ts=$ts)"
  done < <(find "$SESSION_STATE_DIR" -type f 2>/dev/null)
fi

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

# Notification expiry pass: clear any ccg-* notification older than the
# configured threshold (default 24h). terminal-notifier -list ALL returns
# tab-separated columns (GroupID, Title, Subtitle, Message, Delivered At),
# but Message may contain literal newlines — causing a single entry to span
# multiple lines with the "Delivered At" timestamp appearing as the last
# tab-separated field of the LAST line of the entry (not necessarily the
# first). We use awk to track the ccg-* GroupID from the first line of each
# entry and capture the date from whichever line it lands on.
# Only manages our own ccg- groups; other apps' notifications are untouched.
# Overridable for testing; set to 0 to disable.
NOTIF_EXPIRY_HOURS="${CCG_NOTIF_EXPIRY_HOURS:-12}"
if [ "${NOTIF_EXPIRY_HOURS}" -gt 0 ] 2>/dev/null; then
  _notif_cutoff=$((_now - NOTIF_EXPIRY_HOURS * 3600))
  while IFS=$'\t' read -r grp delivered_at; do
    epoch=$(date -j -f "%Y-%m-%d %H:%M:%S %z" "$delivered_at" "+%s" 2>/dev/null) || continue
    [ "$epoch" -gt "$_notif_cutoff" ] && continue
    terminal-notifier -remove "$grp" 2>/dev/null
    __trace "notif-expire: group=$grp delivered=$delivered_at epoch=$epoch cutoff=$_notif_cutoff"
  done < <(terminal-notifier -list ALL 2>/dev/null | awk -F'\t' '
    /^ccg-/ { grp = $1 }
    grp != "" && $NF ~ /^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] [+-][0-9]/ {
      print grp "\t" $NF; grp = ""
    }
  ')
fi

# If anything was removed, nudge SwiftBar so the dropdown reflects reality
# on the next plugin run.
if [ "$pruned" -gt 0 ]; then
  "$HOOKS_DIR/refresh-menubar.sh"
fi
