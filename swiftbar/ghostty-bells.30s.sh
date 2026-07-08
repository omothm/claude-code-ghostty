#!/bin/bash
# SwiftBar plugin: menubar indicator for Ghostty Claude Code sessions.
# Reads per-session state files written by ~/.claude/hooks/tab-title.sh.
#
# Three modes (set via ~/.claude/.ccg/config.json):
#   notifs (default) — visible only when sessions are awaiting input; shows count
#   off              — always hidden even if the feature is installed
#   always-on        — always visible; :bell:N :hourglass:N :cup.and.heat.waves.fill:N
#                      :binoculars:N :zzz:N counts; switches to emoji 🔔 for
#                      the bell count when N>0
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
__trace "mode=$BELL_MODE"

# Fire stale-state cleanup unconditionally on every poll so notification
# expiry and bell-state pruning run even when there are no active sessions
# (the plugin would otherwise exit early before reaching the dispatch at the
# bottom of each mode path, leaving old notifications lingering indefinitely).
"$HOOKS_DIR/sweep-bell-state.sh" </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true
__trace "sweep-dispatched (background)"

# Mode off: never emit any output.
if [ "$BELL_MODE" = "off" ]; then
  __trace "result=hidden (mode=off)"
  exit 0
fi

# -------------------------------------------------------------------------
# Collect state files
# -------------------------------------------------------------------------
_read_state_files() {
  [ -d "$STATE_DIR" ] || return
  for f in "$STATE_DIR"/*; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done
}

# Emit the dashboard control entry. Toggles between "Open dashboard" (which
# starts the server and opens the browser) and "Stop dashboard server" based
# on whether dashboard-server.sh reports a live PID.
_emit_dashboard_entry() {
  local script="$HOOKS_DIR/dashboard-server.sh"
  [ -x "$script" ] || return 0
  local state
  state=$("$script" status 2>/dev/null)
  echo "---"
  if [ "$state" = "running" ]; then
    printf 'Stop dashboard server | sfimage=stop.circle shell="%s" param1="stop" terminal=false refresh=true\n' "$script"
  else
    printf 'Open dashboard | sfimage=chart.line.uptrend.xyaxis shell="%s" param1="start" terminal=false refresh=true\n' "$script"
  fi
}

# Count subagent transcripts for session $1 with a jsonl mtime within the
# last CCG_AGENTS_FRESH_SEC seconds. Mirrors _count_live_agents in
# tab-title.sh — background Agent/Task/Workflow runs live in-process with no
# child PID to check, so freshness of the on-disk transcript is the only
# externally-visible liveness signal.
_count_live_agents() {
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

# Returns status for a state file, or empty string if the file is not a
# recognised session state file (e.g. stray files in the state directory).
#
# For status=watching, line 3 holds the claude ancestor PID. If that PID is
# either dead or no longer owns a Claude-bash-marker child process (the
# Monitor / run_in_background process has exited), we downgrade to idle in
# memory so the dropdown reflects reality without waiting for the next hook
# firing (which may be far in the future — there's no hook for "monitor
# exited while session is still idle").
#
# For status=agents, the state file's basename IS the session_id (tab-title.sh
# keys state files by $session_id), so we re-run _count_live_agents at render
# time and downgrade to idle the moment the background subagent's transcript
# goes stale — same rationale as the watching re-check above, just filesystem-
# instead of PID-based since there's no subagent PID to check.
_file_status() {
  local f="$1"
  local st
  st=$(sed -n '2p' "$f" 2>/dev/null)
  case "$st" in
    watching)
      local cpid
      cpid=$(sed -n '3p' "$f" 2>/dev/null | tr -d ' ')
      if [ -n "$cpid" ] && kill -0 "$cpid" 2>/dev/null && \
         [ "$(ps -axo ppid=,command= 2>/dev/null \
                | awk -v p="$cpid" '$1 == p && /\/tmp\/claude-[0-9a-f]+-cwd/ { n++ } END { print n+0 }')" -gt 0 ]; then
        printf 'watching'
      else
        printf 'idle'
      fi
      return
      ;;
    agents)
      local sid
      sid=$(basename "$f")
      if [ "$(_count_live_agents "$sid")" -gt 0 ]; then
        printf 'agents'
      else
        printf 'idle'
      fi
      return
      ;;
    input|working|idle) printf '%s' "$st"; return ;;
  esac
  # Backwards compat: infer from line-1 prefix for single-line state files.
  local t
  t=$(head -n1 "$f" 2>/dev/null)
  case "$t" in
    "🔔 "*)            printf 'input'   ;;
    "⏳ "*)            printf 'working' ;;
    "👀 "*)            printf 'watching' ;;
    "☕️ "*)             printf 'agents'  ;;
    "Claude Code | "*) printf 'idle'    ;;
    # Not a recognised state file — return empty so callers can skip it.
  esac
}

# -------------------------------------------------------------------------
# notifs mode (default): show bell count, list only waiting sessions
# -------------------------------------------------------------------------
if [ "$BELL_MODE" != "always-on" ]; then
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

  # Only show entries that are in bell/input state.
  bell_titles=""
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    case "$t" in
      "🔔 "*) bell_titles="${bell_titles}${t}"$'\n' ;;
    esac
  done <<< "$titles"
  bell_titles="${bell_titles%$'\n'}"

  if [ -z "$bell_titles" ]; then
    __trace "result=hidden (zero bells)"
    exit 0
  fi

  count=$(printf '%s\n' "$bell_titles" | grep -c .)
  __trace "result=visible count=$count"
  echo ":bell.fill: ${count}"
  echo "---"

  while IFS= read -r title; do
    [ -z "$title" ] && continue
    # Strip leading 🔔 and swap " | " so it doesn't collide with SwiftBar's
    # param separator.
    display="${title#"🔔 "}"
    display="${display// | / — }"
    printf '%s | shell="%s" param1="%s" terminal=false\n' "$display" "$FOCUS" "$title"
  done <<< "$bell_titles"

  _emit_dashboard_entry

  __trace "exit"
  exit 0
fi

# -------------------------------------------------------------------------
# always-on mode: show all sessions with counts; attention color on bell
# -------------------------------------------------------------------------

n_input=0; n_working=0; n_agents=0; n_watching=0; n_idle=0
any_files=0

# First pass: count by status.
while IFS= read -r f; do
  st=$(_file_status "$f")
  [ -z "$st" ] && continue
  any_files=1
  case "$st" in
    input)    n_input=$((n_input+1))     ;;
    working)  n_working=$((n_working+1)) ;;
    agents)   n_agents=$((n_agents+1))   ;;
    watching) n_watching=$((n_watching+1)) ;;
    *)        n_idle=$((n_idle+1))       ;;
  esac
done < <(_read_state_files)

if [ "$any_files" = "0" ] || [ $((n_input + n_working + n_agents + n_watching + n_idle)) -eq 0 ]; then
  __trace "result=hidden (always-on zero sessions)"
  exit 0
fi

__trace "result=visible always-on input=$n_input working=$n_working agents=$n_agents watching=$n_watching idle=$n_idle"

# Header segments:
#   - 🔔 (emoji): only when input > 0 — input is yellow attention; "0" would
#     just be noise. The emoji also stands out against the monochrome SF
#     Symbols, which is the point.
#   - :hourglass: + :zzz: (SF Symbols): always shown, "working" and "idle"
#     are the steady-state baselines.
#   - :cup.and.heat.waves.fill: (SF Symbol): only when agents > 0 — a session with a
#     background Agent/Task/Workflow still running is real progress, but rare
#     enough that ":cup.and.heat.waves.fill: 0" would just be noise.
#   - :binoculars:  (SF Symbol): only when watching > 0. Watching is rare enough
#     that ":binoculars: 0" would just clutter the menubar most of the time. The
#     section below the separator only renders when count > 0 too.
header=""
[ "$n_input" -gt 0 ] && header="🔔 ${n_input} "
header="${header}:hourglass: ${n_working} "
[ "$n_agents" -gt 0 ] && header="${header}:cup.and.heat.waves.fill: ${n_agents} "
[ "$n_watching" -gt 0 ] && header="${header}:binoculars: ${n_watching} "
header="${header}:zzz: ${n_idle}"
echo "${header} | font=.AppleSystemUIFontBold"
echo "---"

# Second pass: collect entries by status group, then emit with section headers.
input_entries=""; working_entries=""; agents_entries=""; watching_entries=""; idle_entries=""
while IFS= read -r f; do
  st=$(_file_status "$f")
  [ -z "$st" ] && continue
  title=$(head -n1 "$f" 2>/dev/null)
  [ -z "$title" ] && continue
  # When _file_status downgraded a stale watching/agents file, drop the icon
  # prefix from the displayed title so the dropdown matches the section it
  # lands in.
  if [ "$st" = "idle" ]; then
    title="${title#"👀 "}"
    title="${title#"☕️ "}"
  fi
  # Strip "Claude Code | " prefix and icon prefix.
  case "$title" in
    *"Claude Code | "*) dir_part="${title#*Claude Code | }" ;;
    *) dir_part="$title" ;;
  esac
  # Swap " | " → " — " so it doesn't collide with SwiftBar's param separator.
  display="${dir_part// | / — }"
  case "$st" in
    input)
      input_entries="${input_entries}$(printf '%s | sfimage=bell.fill shell="%s" param1="%s" terminal=false' \
        "$display" "$FOCUS" "$title")"$'\n' ;;
    working)
      working_entries="${working_entries}$(printf '%s | sfimage=hourglass shell="%s" param1="%s" terminal=false' \
        "$display" "$FOCUS" "$title")"$'\n' ;;
    agents)
      agents_entries="${agents_entries}$(printf '%s | sfimage=cup.and.heat.waves.fill shell="%s" param1="%s" terminal=false' \
        "$display" "$FOCUS" "$title")"$'\n' ;;
    watching)
      watching_entries="${watching_entries}$(printf '%s | sfimage=binoculars shell="%s" param1="%s" terminal=false' \
        "$display" "$FOCUS" "$title")"$'\n' ;;
    *)
      idle_entries="${idle_entries}$(printf '%s | sfimage=zzz shell="%s" param1="%s" terminal=false' \
        "$display" "$FOCUS" "$title")"$'\n' ;;
  esac
done < <(_read_state_files)

need_sep=0
if [ -n "$input_entries" ]; then
  echo "Awaiting input | size=11 color=gray"
  printf '%s' "$input_entries"
  need_sep=1
fi
if [ -n "$working_entries" ]; then
  [ "$need_sep" = "1" ] && echo "---"
  echo "Working | size=11 color=gray"
  printf '%s' "$working_entries"
  need_sep=1
fi
if [ -n "$agents_entries" ]; then
  [ "$need_sep" = "1" ] && echo "---"
  echo "Agents running | size=11 color=gray"
  printf '%s' "$agents_entries"
  need_sep=1
fi
if [ -n "$watching_entries" ]; then
  [ "$need_sep" = "1" ] && echo "---"
  echo "Watching | size=11 color=gray"
  printf '%s' "$watching_entries"
  need_sep=1
fi
if [ -n "$idle_entries" ]; then
  [ "$need_sep" = "1" ] && echo "---"
  echo "Idle | size=11 color=gray"
  printf '%s' "$idle_entries"
fi

_emit_dashboard_entry

__trace "exit"
