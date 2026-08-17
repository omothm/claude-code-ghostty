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
# .mode controls dropdown behavior (see below). .show5hPace and
# .rateLimitsCacheFile control the opt-in 5h-limit pace indicator (see
# "5h-limit pace indicator" below) — icon appearance itself is fixed and not
# configurable.
BELL_MODE="notifs"
SHOW_5H_PACE="false"
RATE_CACHE_FILE="$HOME/.claude/.ccg/rate-limits-cache.json"
BELL_CONFIG="${BELL_CONFIG:-$HOME/.claude/.ccg/config.json}"
if [ -f "$BELL_CONFIG" ]; then
  _m=""
  IFS= read -r _m < <(jq -r '.mode // "notifs"' "$BELL_CONFIG" 2>/dev/null)
  [ -n "$_m" ] && BELL_MODE="$_m"
  _p=""
  IFS= read -r _p < <(jq -r '.show5hPace // false' "$BELL_CONFIG" 2>/dev/null)
  [ -n "$_p" ] && SHOW_5H_PACE="$_p"
  _c=""
  IFS= read -r _c < <(jq -r '.rateLimitsCacheFile // empty' "$BELL_CONFIG" 2>/dev/null)
  [ -n "$_c" ] && RATE_CACHE_FILE="${_c/#\~/$HOME}"
  unset _m _p _c
fi
__trace "mode=$BELL_MODE show5hPace=$SHOW_5H_PACE"

# ─── 5h-limit pace indicator ─────────────────────────────────────────────────
#
# Reads ~/.claude/.ccg/rate-limits-cache.json (overridable via config key
# rateLimitsCacheFile). Expected shape:
#   { "fetched_at": <unix-ts>,
#     "five_hour":  { "used_percentage": <0-100>, "resets_at": <unix-ts> } }
# Absent file = feature invisible. Key "five_hour" absent = no data (no output).
#
# Computes the same ahead/behind pace logic as maat-usage.sh:
#   diff = pct * window / 100  −  elapsed
#        = pct * window / 100  −  (window − remaining)
# Positive diff = ahead (consuming slower than the clock — 🔥 emoji alert).
# Negative diff = behind (consuming faster than the clock).
#
# Formats seconds as a natural-unit duration (ceiled to the smallest unit
# shown), matching maat-usage.sh's format_remaining. Returns empty when no
# data, the window has elapsed, or the feature is off.
#
# Used for the AHEAD-of-pace case, where ceiling is the right call: "9m
# ahead" rounded up to "9m" (rather than down to "8m") doesn't overstate how
# much slack you have.
_pace_format_remaining() {
  local secs="$1"
  (( secs < 0 )) && secs=0
  local total_min=$(( (secs + 59) / 60 ))
  if (( total_min < 60 )); then
    printf "%dm" "$total_min"
  elif (( total_min < 1440 )); then
    local h=$(( total_min / 60 )) m=$(( total_min % 60 ))
    if (( m > 0 )); then printf "%dh%dm" "$h" "$m"; else printf "%dh" "$h"; fi
  else
    local d=$(( total_min / 1440 )) rem=$(( total_min % 1440 ))
    local h=$(( rem / 60 )) m=$(( rem % 60 ))
    (( m > 0 )) && h=$(( h + 1 ))
    if (( h >= 24 )); then d=$(( d + 1 )); h=0; fi
    if (( h > 0 )); then printf "%dd%dh" "$d" "$h"; else printf "%dd" "$d"; fi
  fi
}

# Same natural-unit formatting, but floored instead of ceiled. Used for the
# BEHIND-pace case: ceiling there would overstate how far behind you are
# (e.g. "12600s behind" reads as a clean 3h30m either way, but "12601s"
# should still read "3h30m", not round up to "3h31m" and imply more slack
# has been burned than actually has).
_pace_format_remaining_floor() {
  local secs="$1"
  (( secs < 0 )) && secs=0
  local total_min=$(( secs / 60 ))
  if (( total_min < 60 )); then
    printf "%dm" "$total_min"
  elif (( total_min < 1440 )); then
    local h=$(( total_min / 60 )) m=$(( total_min % 60 ))
    if (( m > 0 )); then printf "%dh%dm" "$h" "$m"; else printf "%dh" "$h"; fi
  else
    local d=$(( total_min / 1440 )) rem=$(( total_min % 1440 ))
    local h=$(( rem / 60 )) m=$(( rem % 60 ))
    if (( h > 0 )); then printf "%dd%dh" "$d" "$h"; else printf "%dd" "$d"; fi
  fi
}

# Returns the formatted pace segment string, or empty string when unavailable.
# $1 = five_h_pct  (number, 0-100)
# $2 = resets_at   (unix timestamp)
# $3 = now         (unix timestamp)
_compute_pace_segment() {
  local pct="$1" resets_at="$2" now="$3"
  local window=18000   # 5 hours in seconds
  local remaining=$(( resets_at - now ))
  (( remaining <= 0 )) && return
  # bc: scale=0 truncates (integer division); format_remaining then ceils
  local diff
  diff=$(echo "scale=0; $pct * $window / 100 - ($window - $remaining)" | bc 2>/dev/null)
  [ -z "$diff" ] && return
  # Ceiled (not rounded) — "42.1%" reads as 43% so the displayed number never
  # understates actual usage (rounding 42.1 down to 42% would).
  local pct_int
  pct_int=$(echo "scale=0; ($pct+0.9999999)/1" | bc 2>/dev/null)
  [ -z "$pct_int" ] && pct_int="$pct"
  if (( diff > 0 )); then
    # Ahead of pace: consuming slower than clock — good. Replace icon with 🔥
    # (no other color/markup needed — emoji grabs the eye against any bg).
    local fmt
    fmt=$(_pace_format_remaining "$diff")
    printf '🔥%s%%←%s' "$pct_int" "$fmt"
  elif (( diff < 0 )); then
    # Behind pace: consuming faster than clock — everyday case, no alarm.
    # :speedometer: icon provides visual separation from the adjacent counters.
    # Floored (not ceiled) — rounding up here would overstate how far behind
    # pace you are.
    local abs=$(( -diff ))
    local fmt
    fmt=$(_pace_format_remaining_floor "$abs")
    printf ':speedometer:%s%% %s→' "$pct_int" "$fmt"
  else
    # Exactly on pace.
    printf ':speedometer:%s%%' "$pct_int"
  fi
}

# Returns "HH:MM|STATE|AS_OF" for the toggle-entry subtitle, or empty string
# when unavailable. Computed independently of $SHOW_5H_PACE so the dropdown
# can preview reset time/pace even while the header segment is off.
# STATE mirrors the ahead/behind pace direction: ahead of pace (diff > 0,
# consuming slower than the clock) reads "too fast" against the quota you
# still have; behind pace (diff < 0, consuming faster than the clock) reads
# "room available" for the time still left in the window.
# AS_OF is the cache's fetched_at formatted as HH:MM, or empty when the
# cache predates that field (older statusline scripts) — the caller omits
# the ", as of HH:MM" clause entirely in that case.
# $1 = five_h_pct   (number, 0-100)
# $2 = resets_at    (unix timestamp)
# $3 = now          (unix timestamp)
# $4 = fetched_at   (unix timestamp, optional)
_compute_pace_toggle_info() {
  local pct="$1" resets_at="$2" now="$3" fetched_at="$4"
  local window=18000   # 5 hours in seconds
  local remaining=$(( resets_at - now ))
  (( remaining <= 0 )) && return
  local diff
  diff=$(echo "scale=0; $pct * $window / 100 - ($window - $remaining)" | bc 2>/dev/null)
  [ -z "$diff" ] && return
  local hhmm
  hhmm=$(date -r "$resets_at" +%H:%M 2>/dev/null)
  [ -z "$hhmm" ] && return
  local state fmt
  if (( diff > 0 )); then
    fmt=$(_pace_format_remaining "$diff")
    state="${fmt} too fast"
  elif (( diff < 0 )); then
    local abs=$(( -diff ))
    fmt=$(_pace_format_remaining_floor "$abs")
    state="${fmt} room available"
  else
    state="on pace"
  fi
  local as_of=""
  [ -n "$fetched_at" ] && as_of=$(date -r "$fetched_at" +%H:%M 2>/dev/null)
  printf '%s|%s|%s' "$hhmm" "$state" "$as_of"
}

# Computes PACE_SEGMENT (exported) by reading the rate-limits cache, or sets
# PACE_SEGMENT="" when the feature is off or data is unavailable. Also
# computes PACE_TOGGLE_INFO (unconditionally on SHOW_5H_PACE) for the
# dropdown toggle entry's subtitle.
PACE_SEGMENT=""
PACE_TOGGLE_INFO=""
if [ -f "$RATE_CACHE_FILE" ]; then
  _now=$(date +%s)
  _pct=$(jq -r '.five_hour.used_percentage // empty' "$RATE_CACHE_FILE" 2>/dev/null)
  _reset=$(jq -r '.five_hour.resets_at // empty' "$RATE_CACHE_FILE" 2>/dev/null)
  _fetched=$(jq -r '.fetched_at // empty' "$RATE_CACHE_FILE" 2>/dev/null)
  if [ -n "$_pct" ] && [ -n "$_reset" ]; then
    PACE_TOGGLE_INFO=$(_compute_pace_toggle_info "$_pct" "$_reset" "$_now" "$_fetched")
    if [ "$SHOW_5H_PACE" = "true" ]; then
      PACE_SEGMENT=$(_compute_pace_segment "$_pct" "$_reset" "$_now")
    fi
  fi
  unset _now _pct _reset _fetched
fi
__trace "pace_segment=$PACE_SEGMENT pace_toggle_info=$PACE_TOGGLE_INFO"

# Emits the "Show 5h Pace" toggle entry at the bottom of any dropdown that
# calls it, with a checkmark when the feature is on. When pace data is
# available, appends "— Reset: HH:MM, STATE, as of HH:MM" in the same muted
# gray used for the bell-entry timestamps (see the ansi=true comment above).
# The ", as of HH:MM" clause is the cache's fetched_at — it's how staleness
# (e.g. a cache that stopped updating while idle) is visible at a glance —
# and is omitted for caches written before that field existed.
_emit_pace_toggle() {
  local toggle_script="$HOOKS_DIR/toggle-5h-pace.sh"
  [ -x "$toggle_script" ] || return 0
  echo "---"
  local label="Show 5h Pace"
  if [ -n "$PACE_TOGGLE_INFO" ]; then
    local hhmm="${PACE_TOGGLE_INFO%%|*}" _rest="${PACE_TOGGLE_INFO#*|}"
    local state="${_rest%%|*}" as_of="${_rest#*|}"
    local as_of_part=""
    [ -n "$as_of" ] && as_of_part=", as of ${as_of}"
    label="Show 5h Pace $(printf '\033[38;5;245m')— Reset: ${hhmm}, ${state}${as_of_part}$(printf '\033[0m')"
  fi
  if [ "$SHOW_5H_PACE" = "true" ]; then
    printf '%s | checked=True bash="%s" terminal=false refresh=true ansi=true\n' "$label" "$toggle_script"
  else
    printf '%s | bash="%s" terminal=false refresh=true ansi=true\n' "$label" "$toggle_script"
  fi
}

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

# Formats a state file's mtime as a time-only string (e.g. "3:14 PM") so each
# dropdown entry can show when it last transitioned, without opening the
# dashboard to find a stale tab.
_fmt_mtime() {
  date -r "$1" "+%-I:%M %p" 2>/dev/null || date -r "$1" "+%H:%M" 2>/dev/null
}

# stdin: "<epoch>\t...\n" entries (one bucket's worth, tab-delimited, epoch
# first column). Sorts oldest-update-first so the tab that's been sitting
# longest in a section surfaces at the top of it.
_sort_by_mtime() {
  sort -t "$(printf '\t')" -k1,1n
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
  # Only bell/input state files get a dropdown entry in notifs mode. Collect
  # "<mtime>\t<title>" per file so entries can later be sorted oldest-first
  # and each line can show when it last transitioned.
  bell_titles=""
  if [ -d "$STATE_DIR" ]; then
    for f in "$STATE_DIR"/*; do
      [ -f "$f" ] || continue
      line=$(head -n1 "$f" 2>/dev/null)
      case "$line" in
        "🔔 "*)
          mtime=$(stat -f %m "$f" 2>/dev/null || echo 0)
          bell_titles="${bell_titles}${mtime}"$'\t'"${line}"$'\n'
          ;;
      esac
    done
    bell_titles="${bell_titles%$'\n'}"
  fi
  __trace "state-read bytes=${#bell_titles}"

  if [ -z "$bell_titles" ]; then
    __trace "result=hidden (zero bells)"
    exit 0
  fi

  count=$(printf '%s\n' "$bell_titles" | grep -c .)
  __trace "result=visible count=$count"
  echo ":bell.fill: ${count}"
  echo "---"

  while IFS=$'\t' read -r mtime title; do
    [ -z "$title" ] && continue
    # Strip leading 🔔 so the AX contains-match still hits when tab-title.sh
    # has swapped the live tab title to ❓ (AskUserQuestion) — the bell-state
    # file's icon stays 🔔 unconditionally, so matching on the full title
    # would never find the tab. Mirrors notify.sh's icon-agnostic match_key.
    stripped="${title#"🔔 "}"
    # Swap " | " so the display text doesn't collide with SwiftBar's param
    # separator.
    display="${stripped// | / — }"
    ts=$(_fmt_mtime "$mtime")
    # ansi=true renders the trailing timestamp in a muted gray; it conflicts
    # with SwiftBar's `symbolize` but not with a co-existing `sfimage=`.
    printf '%s | shell="%s" param1="%s" terminal=false ansi=true\n' \
      "${display} $(printf '\033[38;5;245m')— ${ts}$(printf '\033[0m')" "$FOCUS" "$stripped"
  done < <(printf '%s\n' "$bell_titles" | _sort_by_mtime)

  _emit_dashboard_entry
  _emit_pace_toggle

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
#   - :hourglass: (SF Symbol): always shown when n_working > 0. When
#     n_working == 0, the zero is shown only if BOTH :cup.and.heat.waves.fill:
#     (agents) and :binoculars: (watching) are also zero — i.e. only when
#     there's truly nothing else going on, so ":hourglass: 0" acts as the
#     steady-state anchor. If either agents or watching is active, omitting
#     the zero hourglass keeps the bar from being crowded with a counter that
#     has nothing to say.
#   - :zzz: (SF Symbol): always shown, "idle" is the other steady-state
#     baseline alongside :hourglass:.
#   - :cup.and.heat.waves.fill: (SF Symbol): only when agents > 0 — a session with a
#     background Agent/Task/Workflow still running is real progress, but rare
#     enough that ":cup.and.heat.waves.fill: 0" would just be noise.
#   - :binoculars:  (SF Symbol): only when watching > 0. Watching is rare enough
#     that ":binoculars: 0" would just clutter the menubar most of the time. The
#     section below the separator only renders when count > 0 too.
header=""
[ "$n_input" -gt 0 ] && header="🔔 ${n_input} "
if [ "$n_working" -gt 0 ] || { [ "$n_agents" -eq 0 ] && [ "$n_watching" -eq 0 ]; }; then
  header="${header}:hourglass: ${n_working} "
fi
[ "$n_agents" -gt 0 ] && header="${header}:cup.and.heat.waves.fill: ${n_agents} "
[ "$n_watching" -gt 0 ] && header="${header}:binoculars: ${n_watching} "
header="${header}:zzz: ${n_idle}"
# 5h-limit pace indicator: opt-in (see "5h-limit pace indicator" above),
# comes after every other counter, at the very right. Prefixed with
# :speedometer: (SF Symbol, matches the other counters' icon-prefix
# convention and gives it visual separation from :zzz:) in the everyday
# behind/on-pace case; swapped for 🔥 when ahead of pace (consuming slower
# than time is passing — a good state worth noticing) since emoji draws the
# eye regardless of the menu bar's background/tint in a way color text can't.
[ -n "$PACE_SEGMENT" ] && header="${header} ${PACE_SEGMENT}"
echo "${header} | font=.AppleSystemUIFontBold"
echo "---"

# Second pass: collect entries by status group (each line prefixed with its
# file's mtime + a tab, so the group can be sorted oldest-first just before
# printing), then emit with section headers.
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
  mtime=$(stat -f %m "$f" 2>/dev/null || echo 0)
  ts=$(_fmt_mtime "$mtime")
  # ansi=true renders the trailing timestamp in a muted gray; it conflicts
  # with SwiftBar's `symbolize` but not with a co-existing `sfimage=`.
  display="${display} $(printf '\033[38;5;245m')— ${ts}$(printf '\033[0m')"
  case "$st" in
    input)
      # Strip leading 🔔 from the match key: the bell-state file keeps 🔔
      # unconditionally even when tab-title.sh has swapped the live tab
      # title to ❓ (AskUserQuestion), so matching on the full icon-prefixed
      # title would never find the tab. Mirrors notify.sh's match_key.
      match_title="${title#"🔔 "}"
      input_entries="${input_entries}${mtime}"$'\t'"$(printf '%s | sfimage=bell.fill shell="%s" param1="%s" terminal=false ansi=true' \
        "$display" "$FOCUS" "$match_title")"$'\n' ;;
    working)
      working_entries="${working_entries}${mtime}"$'\t'"$(printf '%s | sfimage=hourglass shell="%s" param1="%s" terminal=false ansi=true' \
        "$display" "$FOCUS" "$title")"$'\n' ;;
    agents)
      agents_entries="${agents_entries}${mtime}"$'\t'"$(printf '%s | sfimage=cup.and.heat.waves.fill shell="%s" param1="%s" terminal=false ansi=true' \
        "$display" "$FOCUS" "$title")"$'\n' ;;
    watching)
      watching_entries="${watching_entries}${mtime}"$'\t'"$(printf '%s | sfimage=binoculars shell="%s" param1="%s" terminal=false ansi=true' \
        "$display" "$FOCUS" "$title")"$'\n' ;;
    *)
      idle_entries="${idle_entries}${mtime}"$'\t'"$(printf '%s | sfimage=zzz shell="%s" param1="%s" terminal=false ansi=true' \
        "$display" "$FOCUS" "$title")"$'\n' ;;
  esac
done < <(_read_state_files)

need_sep=0
if [ -n "$input_entries" ]; then
  echo "Awaiting input | size=11 color=gray"
  printf '%s' "$input_entries" | _sort_by_mtime | cut -f2-
  need_sep=1
fi
if [ -n "$working_entries" ]; then
  [ "$need_sep" = "1" ] && echo "---"
  echo "Working | size=11 color=gray"
  printf '%s' "$working_entries" | _sort_by_mtime | cut -f2-
  need_sep=1
fi
if [ -n "$agents_entries" ]; then
  [ "$need_sep" = "1" ] && echo "---"
  echo "Agents running | size=11 color=gray"
  printf '%s' "$agents_entries" | _sort_by_mtime | cut -f2-
  need_sep=1
fi
if [ -n "$watching_entries" ]; then
  [ "$need_sep" = "1" ] && echo "---"
  echo "Watching | size=11 color=gray"
  printf '%s' "$watching_entries" | _sort_by_mtime | cut -f2-
  need_sep=1
fi
if [ -n "$idle_entries" ]; then
  [ "$need_sep" = "1" ] && echo "---"
  echo "Idle | size=11 color=gray"
  printf '%s' "$idle_entries" | _sort_by_mtime | cut -f2-
fi

_emit_dashboard_entry
_emit_pace_toggle

__trace "exit"
