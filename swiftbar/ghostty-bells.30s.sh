#!/bin/bash
# SwiftBar plugin: menubar indicator for Ghostty Claude Code sessions.
# Reads per-session state files written by ~/.claude/hooks/tab-title.sh.
#
# Three modes (set via ~/.claude/cc-ghostty-config.json):
#   notifs (default) — visible only when sessions are awaiting input; shows count
#   off              — always hidden even if the feature is installed
#   always-on        — always visible; :bell:N :hourglass:N :zzz:N counts;
#                      switches to emoji 🔔 for the bell count when N>0
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

# Load bell config from JSON (~/.claude/cc-ghostty-config.json).
# Only .mode is read; icon appearance is fixed and not configurable.
BELL_MODE="notifs"
BELL_CONFIG="${BELL_CONFIG:-$HOME/.claude/cc-ghostty-config.json}"
if [ -f "$BELL_CONFIG" ]; then
  _m=""
  IFS= read -r _m < <(jq -r '.mode // "notifs"' "$BELL_CONFIG" 2>/dev/null)
  [ -n "$_m" ] && BELL_MODE="$_m"
  unset _m
fi
__trace "mode=$BELL_MODE"

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

# Returns status for a state file, or empty string if the file is not a
# recognised session state file (e.g. stray files in the state directory).
_file_status() {
  local f="$1"
  local st
  st=$(sed -n '2p' "$f" 2>/dev/null)
  case "$st" in
    input|working|idle) printf '%s' "$st"; return ;;
  esac
  # Backwards compat: infer from line-1 prefix for single-line state files.
  local t
  t=$(head -n1 "$f" 2>/dev/null)
  case "$t" in
    "🔔 "*)            printf 'input'   ;;
    "⏳ "*)            printf 'working' ;;
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

  # Fire stale-state cleanup in the background so menubar rendering isn't
  # delayed by the ~300 ms AX enumeration.
  "$HOOKS_DIR/sweep-bell-state.sh" </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
  __trace "sweep-dispatched (background)"
  __trace "exit"
  exit 0
fi

# -------------------------------------------------------------------------
# always-on mode: show all sessions with counts; attention color on bell
# -------------------------------------------------------------------------

n_input=0; n_working=0; n_idle=0
any_files=0

# First pass: count by status.
while IFS= read -r f; do
  st=$(_file_status "$f")
  [ -z "$st" ] && continue
  any_files=1
  case "$st" in
    input)   n_input=$((n_input+1))   ;;
    working) n_working=$((n_working+1)) ;;
    *)       n_idle=$((n_idle+1))     ;;
  esac
done < <(_read_state_files)

if [ "$any_files" = "0" ] || [ $((n_input + n_working + n_idle)) -eq 0 ]; then
  __trace "result=hidden (always-on zero sessions)"
  exit 0
fi

__trace "result=visible always-on input=$n_input working=$n_working idle=$n_idle"

# When sessions are awaiting input, prepend the emoji bell (yellow) so it
# stands out against the monochrome SF Symbol icons. When there are none,
# omit the bell entirely — it would only ever show :bell:0 which is pointless.
if [ "$n_input" -gt 0 ]; then
  echo "🔔${n_input} :hourglass:${n_working} :zzz:${n_idle}"
else
  echo ":hourglass:${n_working} :zzz:${n_idle}"
fi
echo "---"

# Second pass: emit one dropdown entry per session.
while IFS= read -r f; do
  st=$(_file_status "$f")
  [ -z "$st" ] && continue
  title=$(head -n1 "$f" 2>/dev/null)
  [ -z "$title" ] && continue
  case "$st" in
    input)   label="awaiting input" ;;
    working) label="working"        ;;
    *)       label="idle"           ;;
  esac
  # Strip "Claude Code | " prefix (present regardless of icon prefix).
  case "$title" in
    *"Claude Code | "*) dir_part="${title#*Claude Code | }" ;;
    *) dir_part="$title" ;;
  esac
  # Swap " | " → " — " so it doesn't collide with SwiftBar's param separator.
  display="${dir_part// | / — } — ${label}"
  printf '%s | shell="%s" param1="%s" terminal=false\n' "$display" "$FOCUS" "$title"
done < <(_read_state_files)

# Fire stale-state cleanup in background.
"$HOOKS_DIR/sweep-bell-state.sh" </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true
__trace "sweep-dispatched (background)"
__trace "exit"
