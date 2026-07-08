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

# Idle-refinement correction pass: for bell-state files whose owning claude
# process is still alive, re-derive the live agents/watching/idle state and
# correct the file + tab title if it has drifted. This closes the gap where a
# session settles to `agents` after a background Agent/Task/Workflow finishes
# and then goes fully quiet (no further hooks fire), leaving the ☕️ stuck
# indefinitely. The same pass also catches the reverse: a session sitting at
# plain `idle` that missed an agents-upgrade because the SubagentStop race
# (stray-working guard) over-cleared it.
#
# We only touch sessions the main claude process is still alive for: dead-PID
# files were pruned by the PID-liveness pass above, so everything left with a
# PID is a live session. Input and working states are driven by hook events and
# are not second-guessed here — they're legitimately transient and the hook
# is authoritative.
#
# Correction steps for an idle/watching/agents file:
#   1. _count_live_agents — re-check subagent transcript freshness.
#   2. _count_live_monitors — re-check claude marker-child liveness.
#   3. Derive effective state (agents > watching > idle).
#   4. If it differs from the stored line-2 state, rewrite the bell-state file
#      and push the new ANSI title to the session's TTY.
#
# BELL_MODE/CCG_PROJECTS_DIR/CCG_AGENTS_FRESH_SEC are inherited from the
# environment (set at top of script or via callers); we read BELL_CONFIG here
# to stay in sync with the current mode.

_sweep_count_live_agents() {
  local sid="$1" fresh="${CCG_AGENTS_FRESH_SEC:-60}" n=0 f age
  local now projects_dir
  now=$(date +%s)
  projects_dir="${CCG_PROJECTS_DIR:-$HOME/.claude/projects}"
  for f in "$projects_dir"/*/"$sid"/subagents/*.jsonl; do
    [ -f "$f" ] || continue
    age=$(( now - $(stat -f %m "$f" 2>/dev/null || echo 0) ))
    [ "$age" -le "$fresh" ] && n=$((n + 1))
  done
  echo "$n"
}

_sweep_count_live_monitors() {
  local cpid="$1"
  [ -n "$cpid" ] || { echo 0; return; }
  ps -axo ppid=,command= 2>/dev/null \
    | awk -v p="$cpid" '$1 == p && /\/tmp\/claude-[0-9a-f]+-cwd/ { n++ } END { print n+0 }'
}

# Load current bell mode so we write (or skip) state files consistently.
# Default "notifs" mirrors tab-title.sh's own default (an empty/missing/
# unparseable config file must resolve the same way in both places).
_sweep_bell_mode="notifs"
BELL_CONFIG="${BELL_CONFIG:-$HOME/.claude/.ccg/config.json}"
if [ -f "$BELL_CONFIG" ]; then
  _m=""
  IFS= read -r _m < <(jq -r '.mode // "notifs"' "$BELL_CONFIG" 2>/dev/null)
  [ -n "$_m" ] && _sweep_bell_mode="$_m"
  unset _m
fi

if [ -d "$STATE_DIR" ] && [ "$_sweep_bell_mode" = "always-on" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    stored_st=$(sed -n '2p' "$f" 2>/dev/null | tr -d ' ')
    # Only re-check states that are idle-family (idle/watching/agents).
    # input and working are hook-authoritative; don't touch them.
    case "$stored_st" in
      idle|watching|agents) ;;
      *) continue ;;
    esac
    cpid=$(sed -n '3p' "$f" 2>/dev/null | tr -d ' ')
    [ -z "$cpid" ] && continue                          # already pruned above or no PID; skip
    kill -0 "$cpid" 2>/dev/null || continue             # PID dead; let PID-liveness pass handle it

    sid=$(basename "$f")
    # Re-derive effective state.
    if [ "$(_sweep_count_live_agents "$sid")" -gt 0 ]; then
      new_st="agents"
    elif [ "$(_sweep_count_live_monitors "$cpid")" -gt 0 ]; then
      new_st="watching"
    else
      new_st="idle"
    fi

    [ "$new_st" = "$stored_st" ] && continue            # already correct; nothing to do

    # Rewrite the bell-state file.
    stored_title=$(sed -n '1p' "$f" 2>/dev/null)
    # Strip any existing icon prefix to get the base title.
    case "$stored_title" in
      "☕️ "*) base="${stored_title#"☕️ "}" ;;
      "👀 "*) base="${stored_title#"👀 "}" ;;
      "⏳ "*) base="${stored_title#"⏳ "}" ;;
      "🔔 "*) base="${stored_title#"🔔 "}" ;;
      *)      base="$stored_title" ;;
    esac
    case "$new_st" in
      agents)   new_title="☕️ $base" ;;
      watching) new_title="👀 $base" ;;
      *)        new_title="$base" ;;
    esac
    printf '%s\n%s\n%s\n' "$new_title" "$new_st" "$cpid" > "$f"
    pruned=$((pruned + 1))
    __trace "idle-refinement-correct: sid=$sid $stored_st->$new_st (pid=$cpid)"

    # Push the corrected ANSI title to the session's TTY.
    tty_dev=$(ps -p "$cpid" -o tty= 2>/dev/null | tr -d ' ')
    if [ -n "$tty_dev" ] && [ "$tty_dev" != "?" ] && [ "$tty_dev" != "??" ]; then
      printf '\033]2;%s\007' "$new_title" > "/dev/$tty_dev" 2>/dev/null
      __trace "idle-refinement-tty: wrote title to /dev/$tty_dev"
    fi
  done < <(find "$STATE_DIR" -type f 2>/dev/null)
fi
# Logical-state correction pass: the dashboard reads events.jsonl, which is
# independent of BELL_MODE (notifs mode still logs agents/watching transitions
# even though it writes no bell-state file for them — see the bell-state
# pass's mode gate above). Without this, a session's `agents`/`watching`
# event.jsonl entry would drift stale the same way the bell-state file would,
# skewing the dashboard's "right now" counts and fleet-stall metric even after
# the tab title/menubar have self-corrected. Mirrors the bell-state pass:
# only touches live-PID idle-family sessions, appends a new events.jsonl line
# when the re-derived state differs from the logged one, and rewrites the
# 2-line logical-state file so subsequent dedup keys off the corrected value.
if [ -d "$SESSION_STATE_DIR" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    stored_st=$(sed -n '1p' "$f" 2>/dev/null | tr -d ' ')
    case "$stored_st" in
      idle|watching|agents) ;;
      *) continue ;;
    esac
    spid=$(sed -n '2p' "$f" 2>/dev/null | tr -d ' ')
    [ -z "$spid" ] && continue
    kill -0 "$spid" 2>/dev/null || continue             # dead; the end-reconcile pass above handles it

    sid=$(basename "$f")
    if [ "$(_sweep_count_live_agents "$sid")" -gt 0 ]; then
      new_st="agents"
    elif [ "$(_sweep_count_live_monitors "$spid")" -gt 0 ]; then
      new_st="watching"
    else
      new_st="idle"
    fi

    [ "$new_st" = "$stored_st" ] && continue

    title="(reconciled)"
    [ -f "$STATE_DIR/$sid" ] && title=$(sed -n '1p' "$STATE_DIR/$sid" 2>/dev/null)
    jq -nc --arg ts "$_now" --arg sid "$sid" --arg state "$new_st" --arg title "$title" \
      '{ts: ($ts|tonumber), session_id: $sid, state: $state, title: $title, cwd: ""}' \
      >> "$EVENT_LOG" 2>/dev/null
    printf '%s\n%s\n' "$new_st" "$spid" > "$f"
    pruned=$((pruned + 1))
    __trace "logical-refinement-correct: sid=$sid $stored_st->$new_st (pid=$spid)"

    # agents -> idle specifically means a backgrounded Agent/Task/Workflow that
    # was still live when the main turn's Stop hook fired (and suppressed its
    # own "Task completed" notification via notify.sh's agents gate — see
    # notify.sh) has now actually finished. This is the only place that fires
    # the deferred completion notification: nothing else re-checks a quiet
    # `agents` session, so without this the user would never be told the
    # background work wrapped up. Fires unconditionally of BELL_MODE, since
    # this pass (unlike the bell-state pass above) already runs mode-independent.
    if [ "$stored_st" = "agents" ] && [ "$new_st" = "idle" ]; then
      last_cwd=$(jq -rs --arg sid "$sid" \
        '[.[] | select(.session_id==$sid) | select(.cwd != "")] | last | .cwd // empty' "$EVENT_LOG" 2>/dev/null)
      jq -nc --arg sid "$sid" --arg cwd "$last_cwd" '{session_id: $sid, cwd: $cwd}' \
        | "$HOOKS_DIR/notify.sh" '✅' 'Background task completed' > /dev/null 2>&1
      __trace "agents-finished-notify: sid=$sid cwd=$last_cwd"
      unset last_cwd
    fi
  done < <(find "$SESSION_STATE_DIR" -type f 2>/dev/null)
fi

unset -f _sweep_count_live_agents _sweep_count_live_monitors

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
  # tab-title.sh also drops a flat "<sid>.prebell" file directly under this
  # dir (the pre-bell state snapshot) — not caught by the -type d glob above.
  # A crashed session that never fires idle/end leaks this file forever
  # otherwise.
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    rm -f "$f"
    __trace "pending hard-expire (prebell): $f"
  done < <(find "$PENDING_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.prebell' -mmin +720 2>/dev/null)
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
