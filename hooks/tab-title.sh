#!/bin/bash
# Unified tab title helper for Ghostty tabs.
# Usage: tab-title.sh <status> [session_id] [agent_id] [kind]
#   status: idle, working, input, query, end
#   kind: only meaningful for status=input. "query" marks the bell as an
#         AskUserQuestion dialog, swapping the tab-title icon to ❓ (tab
#         title only — the bell-state file/menubar are unaffected). Set by
#         notify.sh when the PermissionRequest payload's tool_name is
#         "AskUserQuestion".
#
# If session_id is omitted, it is read from stdin JSON (.session_id field).
#
# Sets the terminal tab title with the appropriate icon and maintains the
# per-session bell-state file used by the SwiftBar menubar plugin.
#
# Stdout behaviour:
#   status="query"  → two plain lines: base_title on line 1, summary on line 2.
#                     Used by notify.sh subprocess calls; format must stay stable.
#   other statuses  → JSON {"terminalSequence":"<OSC2 escape>"} so Claude Code
#                     2.1.141+ can emit the sequence on our behalf (no TTY needed).
#                     The direct /dev/tty write below remains as fallback for older
#                     versions and for subprocess calls where stdout is discarded.
# Use status "query" to read titles without changing terminal state.
#
# Debug: set BELL_TRACE=1 to append diagnostics to $BELL_TRACE_LOG
# (defaults to /tmp/bell-trace.log). See README for details.

__N=tab-title.sh
__trace() {
  [ -n "$BELL_TRACE" ] || return 0
  printf '%s [%s pid=%s ppid=%s] %s\n' \
    "$(gdate +%s.%3N 2>/dev/null || date +%s)" "$__N" "$$" "$PPID" "$*" \
    >> "${BELL_TRACE_LOG:-/tmp/bell-trace.log}"
}
__trace "entry argc=$# args=[$*]"

# Load config from JSON (~/.claude/.ccg/config.json).
# Only .mode is read; icon appearance is fixed and not configurable.
BELL_MODE="notifs"
BELL_CONFIG="${BELL_CONFIG:-$HOME/.claude/.ccg/config.json}"
if [ -f "$BELL_CONFIG" ]; then
  _m=""
  IFS= read -r _m < <(jq -r '.mode // "notifs"' "$BELL_CONFIG" 2>/dev/null)
  [ -n "$_m" ] && BELL_MODE="$_m"
  unset _m
fi
__trace "bell-config mode=$BELL_MODE"

status="$1"
session_id="$2"
agent_id="${3-}"
# "query" when notify.sh detected an AskUserQuestion permission request (see
# the pending-set `input` case and the title-icon case below) — an
# AskUserQuestion dialog needs more than a yes/no permission decision, so the
# tab title uses ❓ instead of 🔔 to flag that. Menubar/state-file writes are
# untouched: they key off effective_status, not this. Only notify.sh's
# PermissionRequest call site ever sets this; every other caller leaves it
# empty.
kind="${4-}"
# Capture stdin once when we need to read fields from it (session_id arg
# omitted — the direct-hook path). Both session_id and the subagent agent_id
# come from the same hook JSON. When session_id is passed as an arg (the
# notify.sh path and arg-based validator calls), stdin is NOT consumed and
# agent_id arrives as arg 3 instead.
if [ -z "$session_id" ]; then
  _stdin_json=$(cat)
  session_id=$(printf '%s' "$_stdin_json" | jq -r '.session_id // "unknown"' 2>/dev/null)
  [ -z "$agent_id" ] && agent_id=$(printf '%s' "$_stdin_json" | jq -r '.agent_id // empty' 2>/dev/null)
  unset _stdin_json
  __trace "session_id from stdin=$session_id agent_id=${agent_id:-<none>}"
fi
# Actor key for the pending-input set. The main agent has no agent_id in its
# payload, so it maps to the __main__ sentinel; subagent agent_ids are hex and
# can never collide with it. Sanitize to a safe filename charset defensively.
actor="${agent_id:-__main__}"
actor=$(printf '%s' "$actor" | tr -cd '0-9a-zA-Z_-')
[ -z "$actor" ] && actor="__main__"
short_id=$(echo "$session_id" | cut -c1-8)
__trace "resolved status=$status session_id=$session_id short_id=$short_id pwd=$PWD"

# Look up session custom title from the daemon sessions directory.
summary=$(jq -rs --arg sid "$session_id" \
  '.[] | select(.sessionId == $sid) | .name // empty' \
  ~/.claude/sessions/*.json 2>/dev/null | head -1)
if [ -n "$summary" ]; then
  base_title="Claude Code | $summary"
else
  # Use the original project root (fixed across cd's), not the live cwd.
  dir_name=$(basename "${CLAUDE_PROJECT_DIR:-$PWD}")
  base_title="Claude Code | $dir_name ($short_id)"
fi

# Find the ancestor `claude` PID. Used to detect live Claude-owned monitors
# (Monitor tool / Bash run_in_background) so an idle session with active work
# in the background can be surfaced as `watching` instead of plain `idle`.
# CCG_CLAUDE_PID is an explicit override used by the validator.
_find_claude_pid() {
  if [ -n "${CCG_CLAUDE_PID:-}" ]; then
    printf '%s' "$CCG_CLAUDE_PID"
    return 0
  fi
  local p=$PPID
  for _ in 1 2 3 4 5 6 7 8; do
    [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ] || break
    local c
    c=$(ps -p "$p" -o comm= 2>/dev/null | tr -d ' ')
    case "$c" in
      claude|*/claude) printf '%s' "$p"; return 0 ;;
    esac
    p=$(ps -p "$p" -o ppid= 2>/dev/null | tr -d ' ')
  done
  return 1
}

# Count immediate children of $1 whose command line contains the
# `/tmp/claude-<hex>-cwd` marker emitted by Claude Code's bash-tool wrapper.
# Synchronous Bash calls have the same marker but exit in seconds, so any
# match while the session is idle is a live Monitor / background bash.
_count_live_monitors() {
  local cpid="$1"
  [ -n "$cpid" ] || { echo 0; return; }
  ps -axo ppid=,command= 2>/dev/null \
    | awk -v p="$cpid" '$1 == p && /\/tmp\/claude-[0-9a-f]+-cwd/ { n++ } END { print n+0 }'
}

# Count background Agent/Task/Workflow invocations still running for this
# session. Unlike Monitor/run_in_background Bash, a background subagent runs
# IN-PROCESS inside the main claude binary — it spawns no child OS process, so
# there's no PID to walk to (confirmed empirically: ps shows no extra `claude`
# process for an active background Agent call). The only externally-visible
# signal is on disk: Claude Code writes a per-subagent transcript at
# ~/.claude/projects/<project>/<session_id>/subagents/agent-<hex>.jsonl, whose
# mtime advances continuously while the subagent is working and freezes the
# moment it finishes. "Fresh mtime" is therefore the liveness check, playing
# the same role the PID kill -0 check plays for `watching`.
#
# Optional $2 excludes one agent's own transcript (basename "agent-<id>",
# without .jsonl) from the count. Needed by the stray-working guard: a
# subagent's SubagentStop is authoritative proof THAT agent just ended, but
# its transcript's mtime is only a second or two old at that instant — well
# inside the freshness window — so without excluding it, re-deriving liveness
# right after its own SubagentStop would count it as still live and the
# `agents` state would never clear until the file ages past CCG_AGENTS_FRESH_SEC
# on some later, unrelated hook.
_count_live_agents() {
  local sid="$1" exclude="${2:-}" fresh="${CCG_AGENTS_FRESH_SEC:-60}" n=0 f age base
  local now projects_dir
  now=$(date +%s)
  projects_dir="${CCG_PROJECTS_DIR:-$HOME/.claude/projects}"
  for f in "$projects_dir"/*/"$sid"/subagents/*.jsonl; do
    [ -f "$f" ] || continue
    if [ -n "$exclude" ]; then
      base=$(basename "$f" .jsonl)
      [ "$base" = "agent-$exclude" ] && continue
    fi
    age=$((now - $(stat -f %m "$f" 2>/dev/null || echo 0)))
    [ "$age" -le "$fresh" ] && n=$((n + 1))
  done
  echo "$n"
}

# Resolve idle's refinement from LIVE signals: agents (background Agent/Task/
# Workflow still running) > watching (live Monitor/run_in_background marker)
# > plain idle. A background Agent/Task/Workflow is real progress, whereas
# watching is just a live monitor observing something else; if both are true,
# agents wins. Used both for the initial idle upgrade below AND by the
# stray-working guard further down, which must re-derive this live rather
# than trust the logical-state file — otherwise a background agent that
# finishes seconds after the session settles to `agents` has no hook to
# downgrade it, and the state sticks until an unrelated hook fires.
#
# Optional $3 is passed straight through to _count_live_agents as the
# transcript to exclude (see its comment) — set by the stray-working guard
# to the finishing subagent's own actor id, never by the initial idle-upgrade
# call site (which has no "this one just ended" signal to exclude).
_resolve_idle_refinement() {
  local sid="$1" cpid="$2" exclude="${3:-}"
  if [ "$(_count_live_agents "$sid" "$exclude")" -gt 0 ]; then
    printf 'agents'
  elif [ -n "$cpid" ] && [ "$(_count_live_monitors "$cpid")" -gt 0 ]; then
    printf 'watching'
  else
    printf 'idle'
  fi
}

effective_status="$status"
claude_pid=""
# Resolve the ancestor claude PID for all write states (input/working/idle).
# The PID is stored on line 3 of state files so sweep-bell-state.sh can prune
# orphaned files the moment the process exits, rather than waiting 12h.
case "$status" in
  working|input|idle)
    claude_pid=$(_find_claude_pid 2>/dev/null || true)
    ;;
esac
if [ "$status" = "idle" ]; then
  effective_status=$(_resolve_idle_refinement "$session_id" "$claude_pid")
  [ "$effective_status" != "idle" ] && __trace "idle upgraded to $effective_status (session_id=$session_id)"
fi

# Pending-input set: keep the bell up while ANY actor (main agent or a
# subagent) still has an unanswered permission request, even as a *different*
# actor's tool calls keep firing PostToolUse(working). Without this, parallel
# subagents clobber each other's bells: subagent A raises a permission prompt
# (input) and subagent B's next PostToolUse (working) immediately clears it,
# so the bell flaps every few seconds and can never be answered.
#
# Keyed per-actor (agent_id, or __main__ for the main agent) so the clear is
# match-by-id, not "clear any one bell" — a busy sibling must not clear a
# different actor's pending bell. Each actor only ever touches its OWN file in
# the set directory, so concurrent subagent processes never race on shared
# state and no lock is needed.
#   input            -> add this actor
#   working          -> remove this actor; if others remain, hold as input.
#                       SubagentStop is wired to `working`, so it doubles as
#                       the reaper for actors that never fire PostToolUse
#                       (denied permission -> no tool run -> no PostToolUse).
#   idle | end       -> clear the whole set (turn genuinely ended; the main
#                       Stop can't fire while a subagent is still pending).
PENDING_BASE="${CCG_PENDING_DIR:-$HOME/.claude/.ccg/pending}"
pending_dir="$PENDING_BASE/$session_id"
_pending_nonempty() { [ -n "$(ls -A "$pending_dir" 2>/dev/null)" ]; }
# True if ANY actor currently pending is an AskUserQuestion dialog (its
# marker file's content is "query", written by the `input` case below). Used
# to pick the ❓ vs 🔔 title icon — a plain permission prompt from one actor
# must not mask an AskUserQuestion bell from a sibling actor, so this checks
# the whole set, not just the current actor.
_pending_has_query() {
  local f
  for f in "$pending_dir"/*; do
    [ -f "$f" ] || continue
    [ "$(cat "$f" 2>/dev/null)" = "query" ] && return 0
  done
  return 1
}
# Per-session logical-state file (also used for event-log dedup further down).
# Hoisted here so the `working` branch can tell an active turn from a settled
# one — see the stray-late-SubagentStop guard below.
SESSION_STATE_DIR="${CCG_SESSION_STATE_DIR:-$HOME/.claude/.ccg/sessions}"
session_state_file="$SESSION_STATE_DIR/$session_id"
# Pre-bell snapshot: the effective_status in force the instant the FIRST bell
# of a batch fires. Answering a bell doesn't mean the main session started
# new work — e.g. a backgrounded subagent's own permission request raises the
# bell while the main session was sitting at `agents` (idle, background
# Agent/Task/Workflow still running); once that prompt is answered the
# correct tab state is `agents` again, not `working`. Without this, the
# `working` branch below had no way to tell "genuinely new work" from
# "a bell that interrupted a non-working idle-family state" apart, and always
# defaulted to `working`, so a resolved bell would show ⏳ even though the
# main session was still just idling on a live background agent.
prebell_file="$PENDING_BASE/${session_id}.prebell"
case "$status" in
  input)
    if ! _pending_nonempty; then
      # First bell in this batch — capture what was in force right before it.
      # A later, concurrent bell (second subagent asking for permission) must
      # not overwrite this: the first bell's snapshot is the one true
      # pre-interruption state for the whole batch.
      _prebell=""
      [ -f "$session_state_file" ] && _prebell=$(head -n1 "$session_state_file" 2>/dev/null)
      if [ -n "$_prebell" ]; then
        mkdir -p "$PENDING_BASE" 2>/dev/null
        printf '%s\n' "$_prebell" > "$prebell_file" 2>/dev/null
      fi
      unset _prebell
    fi
    mkdir -p "$pending_dir" 2>/dev/null
    printf '%s' "$kind" > "$pending_dir/$actor" 2>/dev/null
    __trace "pending add actor=$actor kind=${kind:-<none>}"
    ;;
  working)
    [ -d "$pending_dir" ] && rm -f "$pending_dir/$actor" 2>/dev/null
    if _pending_nonempty; then
      effective_status="input"
      __trace "working held as input (pending actors remain: $(ls -A "$pending_dir" 2>/dev/null | tr '\n' ',' ))"
    elif [ -f "$prebell_file" ]; then
      # All bells in the batch are answered — reinstate whatever was in force
      # before the FIRST one fired, rather than assuming new work started.
      # Re-derive live (don't just mirror the snapshot back) since the
      # snapshotted background agent/monitor may have finished during the
      # wait — same "re-derive not mirror" rationale as the stray-working
      # guard below. Deliberately NOT excluding this actor's own transcript
      # here (unlike the stray-working guard below): a subagent whose
      # permission request was just granted usually CONTINUES running, so its
      # transcript is genuinely fresh — excluding it would wrongly downgrade
      # `agents` to idle/watching on every granted-permission tool call. The
      # narrow case this misses (denied permission -> subagent stops
      # immediately, no other live agents) self-corrects via the sweep's
      # idle-refinement pass within ~30s.
      # Only watching/agents are worth restoring: a bell that interrupted
      # PLAIN idle (no live background agent or monitor) legitimately means
      # new work is starting once it's answered, so that case still falls
      # through to `working` as before — only the refinements of idle need
      # reinstating, since those describe something ELSE that's still live.
      _prebell=$(head -n1 "$prebell_file" 2>/dev/null)
      rm -f "$prebell_file" 2>/dev/null
      case "$_prebell" in
        watching|agents)
          _stray_cpid=$(_find_claude_pid 2>/dev/null || true)
          effective_status=$(_resolve_idle_refinement "$session_id" "$_stray_cpid")
          unset _stray_cpid
          __trace "prebell restore: was=$_prebell now=$effective_status (actor=$actor)"
          ;;
        *)
          __trace "prebell restore: was=${_prebell:-<none>} -> working (actor=$actor)"
          ;;
      esac
      unset _prebell
    else
      # Stray-working guard. Covers two cases:
      #
      # (A) Stray-late-SubagentStop: a subagent's terminal event (SubagentStop
      #     wired to `working`) can land a second or two AFTER the main agent's
      #     Stop already settled the session to idle, with no pending bell to
      #     clear. Observed live: idle at T, subagent `working` at T+2s, frozen
      #     ⏳ for 28 min.
      #
      # (B) Stray-main-after-end: a Stop/StopFailure hook fires AFTER SessionEnd
      #     already removed the logical-state file. The actor is __main__ (not a
      #     subagent), so a subagent-only guard misses it. Observed live: end at
      #     T, __main__ `working` at T+0.66s, no-PID bell-state, frozen ⏳ until
      #     the stale cap.
      #
      # Detection: read the logical-state file.
      #   Case (A): actor is subagent hex, file contains idle/watching/agents → suppress.
      #   Case (B): actor is __main__, file is absent (removed by `end` handler)
      #             → suppress.
      #   Legitimate start-of-turn: actor is __main__, file contains idle (written
      #     by the preceding SessionStart idle) → pass through. This is the key
      #     distinguisher: a real new turn always has a logical-state file saying
      #     idle; the stray fires when the file has already been removed by end.
      _logical=""
      [ -f "$session_state_file" ] && _logical=$(head -n1 "$session_state_file" 2>/dev/null)
      if [ "$actor" = "__main__" ]; then
        # Case (B): a stray Stop/StopFailure fired after SessionEnd already
        # removed the logical-state file. Identified by the file being absent:
        # in real sessions, SessionStart always fires `idle` (which creates the
        # file) before any `working`, so absent means post-end. Suppress by
        # dropping back to idle; event-log dedup discards the duplicate.
        if [ -z "$_logical" ]; then
          effective_status="idle"
          __trace "stray __main__ working suppressed post-end (logical=<absent>)"
        fi
      else
        case "$_logical" in
          idle|watching|agents)
            # Re-derive live rather than trust $_logical verbatim: THIS
            # SubagentStop may be the very agent whose transcript just froze
            # (a background agent finishing is itself what fires this hook).
            # Mirroring the stale $_logical back unconditionally would leave
            # `agents` stuck forever, since nothing else re-checks it once the
            # session has settled. _find_claude_pid needs re-resolving here —
            # claude_pid above is only set for input/working/idle status.
            #
            # Exclude THIS actor's own transcript from the re-derived count:
            # its mtime is only a second or two old at this instant (well
            # inside CCG_AGENTS_FRESH_SEC), so without excluding it the
            # re-derive would count the very agent that just finished as
            # still live and `agents` would never clear until the file aged
            # out on some later, unrelated hook.
            _stray_cpid=$(_find_claude_pid 2>/dev/null || true)
            effective_status=$(_resolve_idle_refinement "$session_id" "$_stray_cpid" "$actor")
            unset _stray_cpid
            __trace "stray subagent working re-resolved (actor=$actor, was=$_logical, now=$effective_status)"
            ;;
        esac
      fi
      unset _logical
    fi
    ;;
  idle|end)
    rm -rf "$pending_dir" 2>/dev/null
    rm -f "$prebell_file" 2>/dev/null
    __trace "pending cleared (status=$status)"
    ;;
esac

if [ "$status" != "query" ]; then
  case "$effective_status" in
    working)  title="⏳ $base_title" ;;
    input)
      # ❓ instead of 🔔 when any pending actor's bell is an AskUserQuestion
      # dialog — tab title only, so the user knows this needs more than a
      # permission decision. Checks the whole pending set (not just this
      # actor) so a sibling's plain permission prompt can't mask it.
      if _pending_has_query; then
        title="❓ $base_title"
      else
        title="🔔 $base_title"
      fi
      ;;
    watching) title="👀 $base_title" ;;
    agents)   title="☕️ $base_title" ;;
    *)        title="$base_title" ;;
  esac
  # /dev/tty isn't available to hook subprocesses in newer Claude Code builds
  # (no controlling terminal), so resolve the terminal device by walking up
  # to the first ancestor attached to a TTY (typically the claude process).
  tty_dev=""
  pid=$PPID
  for _ in 1 2 3 4 5; do
    [ -n "$pid" ] && [ "$pid" != "0" ] || break
    t=$(ps -p "$pid" -o tty= 2>/dev/null | tr -d ' ')
    if [ -n "$t" ] && [ "$t" != "?" ] && [ "$t" != "??" ] && [ -w "/dev/$t" ]; then
      tty_dev="/dev/$t"
      break
    fi
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
  done
  if [ -n "$tty_dev" ]; then
    printf '\033]2;%s\007' "$title" > "$tty_dev" 2>/dev/null
    __trace "title-set title=\"$title\" dev=$tty_dev"
  else
    __trace "title-set skipped (no parent tty found)"
  fi
fi

# Maintain the bell-state directory. The SwiftBar plugin reads this instead of
# querying the macOS Accessibility API, which has multi-second lag reflecting
# ANSI-set tab titles while Ghostty is backgrounded.
#
# State file format:
#   Line 1: full tab title with icon prefix (matches the ANSI title set above)
#   Line 2: status string (input | working | idle | watching | agents)
#   Line 3: the claude ancestor PID (stored for all write states).
#           sweep-bell-state.sh uses it to prune orphaned files when the
#           process has exited. The plugin also uses it for watching files
#           to detect when the monitored process has exited. For agents
#           files the PID is only used for the sweep's PID-liveness pass —
#           the plugin re-derives freshness from the subagent transcript
#           mtime instead (see _count_live_agents), not this PID.
STATE_DIR="${BELL_STATE_DIR:-$HOME/.claude/bell-state}"
state_file="$STATE_DIR/$session_id"
state_changed=0

_write_state() {
  mkdir -p "$STATE_DIR"
  local desired="$1" st="$2" extra="$3"
  local new
  if [ -n "$extra" ]; then
    new=$(printf '%s\n%s\n%s\n' "$desired" "$st" "$extra")
  else
    new=$(printf '%s\n%s\n' "$desired" "$st")
  fi
  local existing=""
  [ -f "$state_file" ] && existing=$(cat "$state_file" 2>/dev/null)
  if [ "$existing" != "$new" ]; then
    printf '%s\n' "$new" > "$state_file"
    state_changed=1
    __trace "state-file write ($st): $state_file"
  else
    __trace "state-file unchanged ($st)"
  fi
}

_remove_state() {
  if [ -f "$state_file" ]; then
    rm -f "$state_file"
    state_changed=1
    __trace "state-file remove: $state_file"
  else
    __trace "state-file absent (nothing to remove)"
  fi
}

case "$BELL_MODE" in
  off)
    _remove_state
    ;;
  always-on)
    case "$effective_status" in
      input)    _write_state "🔔 $base_title" "input"   "$claude_pid" ;;
      working)  _write_state "⏳ $base_title" "working" "$claude_pid" ;;
      watching) _write_state "👀 $base_title" "watching" "$claude_pid" ;;
      agents)   _write_state "☕️ $base_title" "agents"  "$claude_pid" ;;
      idle)     _write_state "$base_title"    "idle"    "$claude_pid" ;;
      end)      _remove_state ;;
      *)        __trace "state-file unchanged (status=$effective_status)" ;;
    esac
    ;;
  *)
    # notifs mode (default): only "needs attention" writes a state file.
    # watching and agents are refinements of idle and are not surfaced in
    # notifs mode.
    case "$effective_status" in
      input)
        _write_state "🔔 $base_title" "input" "$claude_pid"
        ;;
      idle|watching|agents|working|end)
        _remove_state
        ;;
      *)
        __trace "state-file unchanged (status=$effective_status)"
        ;;
    esac
    ;;
esac

unset -f _write_state _remove_state

# Log state transitions to ~/.claude/.ccg/events.jsonl for the metrics
# dashboard. Independent of BELL_MODE — the log captures every transition
# even in notifs mode (where idle/working don't write a bell-state file).
# Per-session "logical state" files at ~/.claude/.ccg/sessions/<sid> let us
# detect transitions without scanning the log on every hook invocation
# (PostToolUse can fire many times per second).
case "$effective_status" in
  idle|watching|agents|working|input|end)
    EVENT_LOG="${CCG_EVENT_LOG:-$HOME/.claude/.ccg/events.jsonl}"
    # SESSION_STATE_DIR / session_state_file hoisted above (near the pending set).
    prev_state=""
    [ -f "$session_state_file" ] && prev_state=$(head -n1 "$session_state_file" 2>/dev/null)
    if [ "$effective_status" != "$prev_state" ]; then
      # End event only meaningful if there was a prior state to end.
      if [ "$effective_status" = "end" ] && [ -z "$prev_state" ]; then
        __trace "event-log skip (end with no prior state)"
      else
        mkdir -p "$(dirname "$EVENT_LOG")" "$SESSION_STATE_DIR"
        ts=$(gdate +%s.%3N 2>/dev/null || date +%s)
        jq -nc --arg ts "$ts" --arg sid "$session_id" --arg state "$effective_status" \
              --arg title "$base_title" --arg cwd "${CLAUDE_PROJECT_DIR:-$PWD}" \
          '{ts: ($ts|tonumber), session_id: $sid, state: $state, title: $title, cwd: $cwd}' \
          >> "$EVENT_LOG" 2>/dev/null
        __trace "event-log append state=$effective_status prev=${prev_state:-<none>}"
        if [ "$effective_status" = "end" ]; then
          rm -f "$session_state_file"
        else
          # Line 1: logical state (read via head -n1 by dedup + the
          # stray-subagent guard). Line 2: the ancestor claude PID, so
          # sweep-bell-state.sh can PID-check every logged session and emit a
          # synthetic `end` to events.jsonl when the process is gone — even in
          # notifs mode, where no bell-state file exists for working/idle to
          # key off. The dashboard reads events.jsonl over HTTP and can't probe
          # a PID itself, so this server-side backstop is the only thing that
          # keeps its "right now" count honest about sessions that died without
          # firing the SessionEnd hook (crash, kill, closed tab, reboot).
          printf '%s\n%s\n' "$effective_status" "$claude_pid" > "$session_state_file"
        fi
      fi
    else
      __trace "event-log skip (no transition, state=$effective_status)"
    fi
    ;;
esac

# Nudge the optional SwiftBar menubar plugin only on actual state transitions.
if [ "$state_changed" = "1" ]; then
  __trace "fire-refresh"
  "$(dirname "$0")/refresh-menubar.sh"
  __trace "refresh-menubar.sh returned rc=$?"
else
  __trace "skip-refresh (no state change)"
fi

__trace "exit"
if [ "$status" = "query" ]; then
  echo "$base_title"
  echo "$summary"
else
  # Emit terminalSequence JSON for Claude Code 2.1.141+ direct hook calls.
  # Claude Code writes the sequence to the terminal on our behalf, which is
  # race-free and works without a controlling TTY. The /dev/tty write above
  # stays as the fallback for older versions and subprocess invocations.
  _seq=$(printf '\033]2;%s\007' "$title")
  __trace "terminalSequence title=\"$title\""
  jq -nc --arg seq "$_seq" '{terminalSequence: $seq}'
  printf '%s title="%s" session=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$title" "$short_id" \
    >> "${CCG_DIR:-$HOME/.claude/.ccg}/termseq.log" 2>/dev/null
  unset _seq
fi
