#!/bin/bash
# Runnable validator for the Ghostty + Claude Code bell integration.
#
# Exercises the deployed scripts in ~/.claude/hooks/ and the SwiftBar plugin
# (if installed) across every major surface: state-file lifecycle, refresh
# gating, plugin output, stale-file sweep, BELL_TRACE toggle, and end-to-end
# latency.
#
# Uses a sandboxed BELL_STATE_DIR so it never touches real session state. Safe
# to run at any time; the only side effect is that if SwiftBar is running and
# the plugin is deployed, the menubar briefly refreshes during the run.
#
# Usage:
#   ./tests/validate.sh                   # test deployed scripts, concise output
#   ./tests/validate.sh --verbose         # test deployed scripts, show passes
#   ./tests/validate.sh <project-dir>     # test project scripts (e.g. .)
#   ./tests/validate.sh <project-dir> -v
#
# Exit code: 0 if all non-skipped checks pass, non-zero equal to fail count.

set -u

VERBOSE=0
PROJECT_DIR=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -v|--verbose) VERBOSE=1 ;;
    -*) ;;
    *) PROJECT_DIR="$1" ;;
  esac
  shift
done

SWIFTBAR_APP="/Applications/SwiftBar.app"

if [ -n "$PROJECT_DIR" ]; then
  PROJECT_DIR="$(cd "$PROJECT_DIR" 2>/dev/null && pwd)" || { printf 'Error: directory not found: %s\n' "$PROJECT_DIR" >&2; exit 1; }
  HOOKS_DIR="$PROJECT_DIR/hooks"
  export GHOSTTY_HOOKS_DIR="$HOOKS_DIR"
  PLUGIN_PATH="$PROJECT_DIR/swiftbar/ghostty-bells.30s.sh"
else
  HOOKS_DIR="$HOME/.claude/hooks"
  SWIFTBAR_PLUGIN_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
  PLUGIN_PATH=""
  [ -n "$SWIFTBAR_PLUGIN_DIR" ] && PLUGIN_PATH="$SWIFTBAR_PLUGIN_DIR/ghostty-bells.30s.sh"
fi

TMPROOT="$(mktemp -d -t bell-validate.XXXXXX)"
export BELL_STATE_DIR="$TMPROOT/state"
export BELL_TRACE_LOG="$TMPROOT/trace.log"
export BELL_CONFIG="$TMPROOT/bell-config"
export CCG_EVENT_LOG="$TMPROOT/events.jsonl"
export CCG_SESSION_STATE_DIR="$TMPROOT/sessions"
mkdir -p "$BELL_STATE_DIR" "$CCG_SESSION_STATE_DIR"
touch "$BELL_TRACE_LOG"
# Start with an empty (notifs-default) config.
: > "$BELL_CONFIG"

if [ -t 1 ]; then
  C_OK=$'\e[32m'; C_NG=$'\e[31m'; C_SK=$'\e[33m'; C_B=$'\e[1m'; C_R=$'\e[0m'
else
  C_OK=""; C_NG=""; C_SK=""; C_B=""; C_R=""
fi

PASS=0; FAIL=0; SKIP=0
# Helpers always return 0 so they compose safely in `check && ok ... || ng ...`
# chains even when their body's last command (the verbose-mode conditional)
# returns non-zero.
ok()      { PASS=$((PASS+1)); [ "$VERBOSE" -eq 1 ] && printf '  %s✓%s %s\n' "$C_OK" "$C_R" "$*"; return 0; }
ng()      { FAIL=$((FAIL+1)); printf '  %s✗%s %s\n' "$C_NG" "$C_R" "$*"; return 0; }
skip()    { SKIP=$((SKIP+1)); [ "$VERBOSE" -eq 1 ] && printf '  %s·%s %s %s(skipped)%s\n' "$C_SK" "$C_R" "$*" "$C_SK" "$C_R"; return 0; }
section() { printf '\n%s==>%s %s%s%s\n' "$C_B" "$C_R" "$C_B" "$*" "$C_R"; }

cleanup() {
  rm -rf "$TMPROOT"
  unset BELL_STATE_DIR BELL_TRACE BELL_TRACE_LOG BELL_CONFIG GHOSTTY_HOOKS_DIR \
        CCG_EVENT_LOG CCG_SESSION_STATE_DIR
}
trap cleanup EXIT

# Helpers.
now_ms()     { gdate +%s%3N 2>/dev/null || echo 0; }
trace_reset() { : > "$BELL_TRACE_LOG"; }
age_file()   { touch -t "$(gdate -d "$1" +%Y%m%d%H%M.%S)" "$2"; }
sf_exists()  { [ -f "$BELL_STATE_DIR/$1" ]; }
write_sf()   { printf '%s\n' "$2" > "$BELL_STATE_DIR/$1"; }

# ---------------------------------------------------------------------------
section "Prerequisites"

[ "$(uname -s)" = "Darwin" ] && ok "macOS" || { ng "not macOS"; exit 1; }

for cmd in jq terminal-notifier gdate osascript; do
  if command -v "$cmd" >/dev/null 2>&1; then ok "$cmd installed"; else ng "$cmd missing"; fi
done

for f in tab-title.sh notify.sh refresh-menubar.sh focus-ghostty-tab.sh sweep-bell-state.sh dashboard-server.sh; do
  if [ -x "$HOOKS_DIR/$f" ]; then ok "$HOOKS_DIR/$f executable"; else ng "$HOOKS_DIR/$f missing or not executable"; fi
done

swiftbar=0
if [ -d "$SWIFTBAR_APP" ]; then swiftbar=1; ok "SwiftBar installed"; else skip "SwiftBar not installed"; fi

plugin=0
if [ -n "$PROJECT_DIR" ]; then
  if [ -x "$PLUGIN_PATH" ]; then plugin=1; ok "plugin at $PLUGIN_PATH"
  else ng "plugin not found at $PLUGIN_PATH"; fi
elif [ "$swiftbar" = "1" ]; then
  if [ -n "$PLUGIN_PATH" ] && [ -x "$PLUGIN_PATH" ]; then plugin=1; ok "plugin at $PLUGIN_PATH"
  else ng "plugin not found at expected path ($PLUGIN_PATH)"; fi
fi

# ---------------------------------------------------------------------------
section "tab-title.sh state-file lifecycle"

SID="vA"

# input writes state file with 🔔 prefix
echo "{\"session_id\":\"$SID\"}" | "$HOOKS_DIR/tab-title.sh" input > /dev/null 2>&1
if sf_exists "$SID"; then ok "input writes state file"; else ng "input did not write state file"; fi
if sf_exists "$SID" && grep -qF "🔔" "$BELL_STATE_DIR/$SID"; then ok "state file has 🔔 prefix"; else ng "state file missing 🔔 prefix"; fi

# working removes state file
echo "{\"session_id\":\"$SID\"}" | "$HOOKS_DIR/tab-title.sh" working > /dev/null 2>&1
if ! sf_exists "$SID"; then ok "working removes state file"; else ng "working did not remove state file"; fi

# idle removes state file
echo "{\"session_id\":\"$SID\"}" | "$HOOKS_DIR/tab-title.sh" input > /dev/null 2>&1
echo "{\"session_id\":\"$SID\"}" | "$HOOKS_DIR/tab-title.sh" idle > /dev/null 2>&1
if ! sf_exists "$SID"; then ok "idle removes state file"; else ng "idle did not remove state file"; fi

# query doesn't touch state
echo "{\"session_id\":\"$SID\"}" | "$HOOKS_DIR/tab-title.sh" input > /dev/null 2>&1
mt_before=$(stat -f %m "$BELL_STATE_DIR/$SID" 2>/dev/null)
sleep 1.2
"$HOOKS_DIR/tab-title.sh" query "$SID" > /dev/null 2>&1
mt_after=$(stat -f %m "$BELL_STATE_DIR/$SID" 2>/dev/null)
if [ -n "$mt_before" ] && [ "$mt_before" = "$mt_after" ]; then ok "query does not touch state"
else ng "query mutated state (before=$mt_before after=$mt_after)"; fi

# idempotent input (no rewrite when content matches)
mt_before=$(stat -f %m "$BELL_STATE_DIR/$SID" 2>/dev/null)
sleep 1.2
echo "{\"session_id\":\"$SID\"}" | "$HOOKS_DIR/tab-title.sh" input > /dev/null 2>&1
mt_after=$(stat -f %m "$BELL_STATE_DIR/$SID" 2>/dev/null)
if [ "$mt_before" = "$mt_after" ]; then ok "idempotent input (no rewrite when unchanged)"
else ng "repeat input rewrote state file"; fi

# end removes state file (for SessionEnd hook)
echo "{\"session_id\":\"$SID\"}" | "$HOOKS_DIR/tab-title.sh" input > /dev/null 2>&1
echo "{\"session_id\":\"$SID\"}" | "$HOOKS_DIR/tab-title.sh" end > /dev/null 2>&1
if ! sf_exists "$SID"; then ok "end removes state file"; else ng "end did not remove state file"; fi

# state file has two lines (title + status)
echo "{\"session_id\":\"$SID\"}" | "$HOOKS_DIR/tab-title.sh" input > /dev/null 2>&1
line2=$(sed -n '2p' "$BELL_STATE_DIR/$SID" 2>/dev/null)
if [ "$line2" = "input" ]; then ok "state file line 2 = status"; else ng "state file line 2 wrong (got: $line2)"; fi

rm -f "$BELL_STATE_DIR/$SID"

# ---------------------------------------------------------------------------
section "tab-title.sh refresh gating"

export BELL_TRACE=1

trace_reset
echo "{\"session_id\":\"gA\"}" | "$HOOKS_DIR/tab-title.sh" input > /dev/null 2>&1
grep -q "fire-refresh" "$BELL_TRACE_LOG" && ok "fires refresh on input (state changed)" || ng "did not fire refresh on input"

trace_reset
echo "{\"session_id\":\"gA\"}" | "$HOOKS_DIR/tab-title.sh" input > /dev/null 2>&1
grep -q "skip-refresh" "$BELL_TRACE_LOG" && ok "skips refresh on duplicate input" || ng "fired refresh on unchanged input"

trace_reset
echo "{\"session_id\":\"gA\"}" | "$HOOKS_DIR/tab-title.sh" working > /dev/null 2>&1
grep -q "fire-refresh" "$BELL_TRACE_LOG" && ok "fires refresh on working (state changed)" || ng "did not fire refresh on working"

trace_reset
echo "{\"session_id\":\"gA\"}" | "$HOOKS_DIR/tab-title.sh" working > /dev/null 2>&1
grep -q "skip-refresh" "$BELL_TRACE_LOG" && ok "skips refresh on repeated working" || ng "fired refresh on unchanged working"

unset BELL_TRACE
rm -f "$BELL_STATE_DIR/gA"

# ---------------------------------------------------------------------------
section "events.jsonl logging"

# Reset the event log and per-session state for this section.
: > "$CCG_EVENT_LOG"
rm -rf "$CCG_SESSION_STATE_DIR"
mkdir -p "$CCG_SESSION_STATE_DIR"

# Count occurrences of session_id in the event log, robustly. Avoids the
# grep-on-empty-file case where `grep -c` returns "0\n" + exit 1.
count_events_for() {
  local sid="$1"
  [ -s "$CCG_EVENT_LOG" ] || { echo 0; return; }
  local c
  c=$(grep -c "\"session_id\":\"$sid\"" "$CCG_EVENT_LOG" 2>/dev/null) || c=0
  echo "${c:-0}"
}

EID="evt-$$"

# 1. idle (SessionStart) — first transition logs.
echo "{\"session_id\":\"$EID\"}" | "$HOOKS_DIR/tab-title.sh" idle > /dev/null 2>&1
n=$(count_events_for "$EID")
[ "$n" = "1" ] && ok "idle (first transition) appends event" || ng "first idle did not append (got $n events)"

# 2. Repeat idle — no log entry (no transition).
echo "{\"session_id\":\"$EID\"}" | "$HOOKS_DIR/tab-title.sh" idle > /dev/null 2>&1
n=$(count_events_for "$EID")
[ "$n" = "1" ] && ok "repeat idle does not duplicate event" || ng "repeat idle duplicated event (got $n)"

# 3. working — logs.
echo "{\"session_id\":\"$EID\"}" | "$HOOKS_DIR/tab-title.sh" working > /dev/null 2>&1
n=$(count_events_for "$EID")
[ "$n" = "2" ] && ok "idle → working appends event" || ng "working did not append (got $n)"

# 4. PostToolUse-style repeat working — no log.
for _ in 1 2 3; do
  echo "{\"session_id\":\"$EID\"}" | "$HOOKS_DIR/tab-title.sh" working > /dev/null 2>&1
done
n=$(count_events_for "$EID")
[ "$n" = "2" ] && ok "repeated working (PostToolUse churn) does not duplicate" || ng "repeated working logged extra (got $n)"

# 5. input — logs.
echo "{\"session_id\":\"$EID\"}" | "$HOOKS_DIR/tab-title.sh" input > /dev/null 2>&1
n=$(count_events_for "$EID")
[ "$n" = "3" ] && ok "working → input appends event" || ng "input did not append (got $n)"

# 6. Event JSON shape.
last=$(tail -n1 "$CCG_EVENT_LOG")
echo "$last" | jq -e '.ts | type == "number"' >/dev/null 2>&1 \
  && ok "event ts is numeric" || ng "event ts not numeric: $last"
echo "$last" | jq -e '.session_id and .state and .title' >/dev/null 2>&1 \
  && ok "event has session_id, state, title" || ng "event missing fields: $last"
state_field=$(echo "$last" | jq -r '.state')
[ "$state_field" = "input" ] && ok "last event state == input" || ng "last event state wrong: $state_field"

# 7. end after a real prior state — logs.
echo "{\"session_id\":\"$EID\"}" | "$HOOKS_DIR/tab-title.sh" end > /dev/null 2>&1
n=$(count_events_for "$EID")
[ "$n" = "4" ] && ok "input → end appends event" || ng "end did not append (got $n)"

# 8. Per-session state file is removed on end.
[ ! -f "$CCG_SESSION_STATE_DIR/$EID" ] \
  && ok "session state file cleaned up on end" \
  || ng "session state file lingered after end"

# 9. end with no prior state — does NOT log (avoids zombie events).
EID2="evt-empty-$$"
echo "{\"session_id\":\"$EID2\"}" | "$HOOKS_DIR/tab-title.sh" end > /dev/null 2>&1
n=$(count_events_for "$EID2")
[ "$n" = "0" ] && ok "end with no prior state does not log" || ng "end-with-no-prior wrongly logged (got $n)"

# 10. notifs mode does not suppress event logging (events are mode-independent).
EID3="evt-notifs-$$"
echo "{\"session_id\":\"$EID3\"}" | "$HOOKS_DIR/tab-title.sh" working > /dev/null 2>&1
n=$(count_events_for "$EID3")
# notifs mode (current $BELL_CONFIG is empty → notifs default) doesn't write a
# bell-state file for working, but the event log is independent of bell mode.
[ "$n" = "1" ] && ok "notifs mode still logs working event" || ng "notifs mode missed working event (got $n)"

# 11. query never logs.
events_before=$(wc -l < "$CCG_EVENT_LOG")
"$HOOKS_DIR/tab-title.sh" query "$EID3" > /dev/null 2>&1
events_after=$(wc -l < "$CCG_EVENT_LOG")
[ "$events_before" = "$events_after" ] && ok "query never logs an event" || ng "query mutated event log"

rm -f "$BELL_STATE_DIR/$EID" "$BELL_STATE_DIR/$EID2" "$BELL_STATE_DIR/$EID3"

# ---------------------------------------------------------------------------
section "refresh-menubar.sh"

out=$("$HOOKS_DIR/refresh-menubar.sh" 2>&1); rc=$?
[ "$rc" = "0" ] && ok "exit 0" || ng "non-zero exit ($rc)"
[ -z "$out" ] && ok "silent (no stdout/stderr)" || ng "emitted output: $out"

export BELL_TRACE=1
trace_reset
"$HOOKS_DIR/refresh-menubar.sh" > /dev/null 2>&1
if [ "$swiftbar" = "1" ]; then
  grep -q "gate=opted-in" "$BELL_TRACE_LOG" && ok "takes opted-in gate" || ng "did not take opted-in gate"
  grep -q "open-exit=0" "$BELL_TRACE_LOG" && ok "open dispatched rc=0" || ng "open-exit not 0"
else
  grep -q "gate=not-installed" "$BELL_TRACE_LOG" && ok "takes not-installed gate" || ng "did not take not-installed gate"
fi
unset BELL_TRACE

# ---------------------------------------------------------------------------
section "Plugin output"

if [ "$plugin" = "1" ]; then
  write_sf "pA" "🔔 Claude Code | plug-alpha (pA12345)"
  write_sf "pB" "🔔 Claude Code | plug-beta (pB67890)"

  out=$(bash "$PLUGIN_PATH" 2>&1)
  echo "$out" | grep -q '^:bell.fill: 2' && ok "emits SF Symbol + correct count" || ng "missing or wrong count: $out"
  echo "$out" | grep -q 'plug-alpha' && ok "entry for plug-alpha present" || ng "missing plug-alpha"
  echo "$out" | grep -q 'plug-beta' && ok "entry for plug-beta present" || ng "missing plug-beta"
  echo "$out" | grep -q 'param1="🔔 Claude Code | plug-alpha' && ok "param1 preserves full 🔔 title" || ng "param1 missing 🔔"
  # Stored title contains " | "; display must swap it to " — " so it doesn't
  # collide with SwiftBar's own " | " parameter separator.
  echo "$out" | grep -q 'Claude Code — plug-alpha' && ok "display swaps ' | ' to ' — '" || ng "display did not swap ' | ' to ' — '"

  rm -f "$BELL_STATE_DIR/pA" "$BELL_STATE_DIR/pB"

  # Empty dir => exit 0 with no output
  out=$(bash "$PLUGIN_PATH" 2>&1); rc=$?
  [ "$rc" = "0" ] && [ -z "$out" ] && ok "empty state dir => icon hidden (no stdout, exit 0)" || ng "plugin output when empty: rc=$rc out=\"$out\""
else
  skip "plugin output tests"
fi

# ---------------------------------------------------------------------------
section "dashboard entry in plugin output"

if [ "$plugin" = "1" ]; then
  # Use an isolated CCG_DIR so we don't trip over a real server if one is
  # running on the user's machine.
  export CCG_DIR="$TMPROOT/ccg-plugin"
  mkdir -p "$CCG_DIR"

  write_sf "dA" "🔔 Claude Code | dash-alpha (dA12345)"

  # Stopped state: no PID file → entry says "Open dashboard".
  out=$(CCG_DIR="$CCG_DIR" bash "$PLUGIN_PATH" 2>&1)
  echo "$out" | grep -q 'Open dashboard' \
    && ok "stopped → emits 'Open dashboard' entry" \
    || ng "stopped → missing 'Open dashboard' entry: $out"
  echo "$out" | grep -q 'param1="start"' \
    && ok "stopped entry uses param1=start" \
    || ng "stopped entry missing param1=start"
  echo "$out" | grep -q 'refresh=true' \
    && ok "dashboard entry has refresh=true (menu re-renders after click)" \
    || ng "dashboard entry missing refresh=true"

  # Dashboard entry must come AFTER the session entries (separator between).
  last_sep_line=$(echo "$out" | grep -n '^---$' | tail -n1 | cut -d: -f1)
  dash_line=$(echo "$out" | grep -n 'dashboard' | tail -n1 | cut -d: -f1)
  if [ -n "$last_sep_line" ] && [ -n "$dash_line" ] && [ "$dash_line" -gt "$last_sep_line" ]; then
    ok "dashboard entry follows last separator (positioned after sessions)"
  else
    ng "dashboard entry not positioned after sessions: sep=$last_sep_line dash=$dash_line"
  fi

  # Running state: stub PID file pointing at this shell's PID (alive).
  echo "$$" > "$CCG_DIR/server.pid"
  out=$(CCG_DIR="$CCG_DIR" bash "$PLUGIN_PATH" 2>&1)
  echo "$out" | grep -q 'Stop dashboard server' \
    && ok "running → emits 'Stop dashboard server' entry" \
    || ng "running → missing 'Stop dashboard server' entry: $out"
  echo "$out" | grep -q 'param1="stop"' \
    && ok "running entry uses param1=stop" \
    || ng "running entry missing param1=stop"
  echo "$out" | grep -qv 'Open dashboard' \
    && ok "running → 'Open dashboard' suppressed" \
    || ng "running → 'Open dashboard' wrongly present: $out"

  # Stale PID file (pointing at a non-existent process) → treated as stopped.
  echo "999999" > "$CCG_DIR/server.pid"
  out=$(CCG_DIR="$CCG_DIR" bash "$PLUGIN_PATH" 2>&1)
  echo "$out" | grep -q 'Open dashboard' \
    && ok "stale PID file → entry reverts to 'Open dashboard'" \
    || ng "stale PID file → still showing 'Stop': $out"

  rm -f "$BELL_STATE_DIR/dA" "$CCG_DIR/server.pid"
  unset CCG_DIR
else
  skip "dashboard entry tests"
fi

# ---------------------------------------------------------------------------
section "dashboard-server.sh status"

# Status is the only branch we exercise unconditionally — start/stop spawn a
# real http.server which we don't want running unattended in the validator.
if [ -x "$HOOKS_DIR/dashboard-server.sh" ]; then
  CCG_DIR="$TMPROOT/ccg-status"
  mkdir -p "$CCG_DIR"

  out=$(CCG_DIR="$CCG_DIR" "$HOOKS_DIR/dashboard-server.sh" status 2>&1)
  [ "$out" = "stopped" ] && ok "status without PID file → 'stopped'" || ng "status wrong (got '$out')"

  echo "999999" > "$CCG_DIR/server.pid"
  out=$(CCG_DIR="$CCG_DIR" "$HOOKS_DIR/dashboard-server.sh" status 2>&1)
  [ "$out" = "stopped" ] && ok "status with stale PID → 'stopped'" || ng "stale PID status wrong (got '$out')"

  echo "$$" > "$CCG_DIR/server.pid"
  out=$(CCG_DIR="$CCG_DIR" "$HOOKS_DIR/dashboard-server.sh" status 2>&1)
  [ "$out" = "running" ] && ok "status with live PID → 'running'" || ng "live PID status wrong (got '$out')"

  out=$("$HOOKS_DIR/dashboard-server.sh" 2>&1); rc=$?
  [ "$rc" = "2" ] && ok "no-arg invocation exits 2 (usage)" || ng "no-arg rc=$rc"
fi

# ---------------------------------------------------------------------------
section "sweep-bell-state.sh"

# Use a fresh, isolated state dir for the entire sweep section.
# Background sweeps dispatched by the plugin tests above (which still have
# the old BELL_STATE_DIR in scope) cannot interfere with our test files.
export BELL_STATE_DIR="$TMPROOT/sweep-state"
mkdir -p "$BELL_STATE_DIR"

# Hard-age: 25h-old file pruned unconditionally
write_sf "sH" "🔔 Claude Code | hard-aged (sH12345)"
age_file "25 hours ago" "$BELL_STATE_DIR/sH"
export BELL_TRACE=1; trace_reset
"$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
if ! sf_exists "sH"; then ok "hard-age cap (24h) prunes"; else ng "hard-age did not prune"; fi
grep -q "hard-expire" "$BELL_TRACE_LOG" && ok "sweep logs hard-expire" || ng "no hard-expire in trace"

# Grace protects fresh file even with fake title
write_sf "sF" "🔔 Claude Code | never-seen-by-ax (sFresh)"
"$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
if sf_exists "sF"; then ok "grace period protects fresh files"; else ng "fresh file pruned — grace period failed"; fi
rm -f "$BELL_STATE_DIR/sF"

# AX-verified prune for past-grace files not in Ghostty
ghostty_running=0
osascript -e 'tell application "System Events" to return (exists process "Ghostty")' 2>/dev/null | grep -q true && ghostty_running=1
if [ "$ghostty_running" = "1" ]; then
  write_sf "sO" "🔔 Claude Code | never-seen-by-ax-orphan (sOrphan$(date +%s))"
  age_file "6 minutes ago" "$BELL_STATE_DIR/sO"
  trace_reset
  "$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
  if ! sf_exists "sO"; then ok "AX prunes past-grace orphan"; else ng "AX did not prune past-grace orphan"; fi
  grep -q "ax-prune" "$BELL_TRACE_LOG" && ok "sweep logs ax-prune" || ng "no ax-prune in trace"
else
  skip "AX-verified prune (Ghostty not running)"
fi

# Sweep fires refresh after pruning
write_sf "sR" "🔔 Claude Code | sweep-refresh-trigger (sR)"
age_file "25 hours ago" "$BELL_STATE_DIR/sR"
trace_reset
"$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
grep -q "refresh-menubar.sh" "$BELL_TRACE_LOG" && ok "sweep triggers refresh after pruning" || ng "sweep did not trigger refresh after pruning"
unset BELL_TRACE

# ---------------------------------------------------------------------------
section "Mode=off"

printf '{"mode":"off"}\n' > "$BELL_CONFIG"

# tab-title.sh in off mode: never writes state files
echo "{\"session_id\":\"mOA\"}" | "$HOOKS_DIR/tab-title.sh" input   > /dev/null 2>&1
if ! sf_exists "mOA"; then ok "off: input does not write state file"; else ng "off: input wrote state file"; fi

echo "{\"session_id\":\"mOA\"}" | "$HOOKS_DIR/tab-title.sh" idle    > /dev/null 2>&1
if ! sf_exists "mOA"; then ok "off: idle does not write state file"; else ng "off: idle wrote state file"; fi

echo "{\"session_id\":\"mOA\"}" | "$HOOKS_DIR/tab-title.sh" working > /dev/null 2>&1
if ! sf_exists "mOA"; then ok "off: working does not write state file"; else ng "off: working wrote state file"; fi

# tab-title.sh in off mode: cleans up an existing state file
write_sf "mOB" "🔔 Claude Code | off-cleanup (mOB)"
echo "{\"session_id\":\"mOB\"}" | "$HOOKS_DIR/tab-title.sh" working > /dev/null 2>&1
if ! sf_exists "mOB"; then ok "off: removes existing state file on transition"; else ng "off: did not remove state file"; fi

if [ "$plugin" = "1" ]; then
  out=$(BELL_CONFIG="$BELL_CONFIG" bash "$PLUGIN_PATH" 2>&1); rc=$?
  [ "$rc" = "0" ] && [ -z "$out" ] && ok "off: plugin emits no output" || ng "off: plugin output when mode=off: rc=$rc out=\"$out\""
else
  skip "off: plugin output test"
fi

# ---------------------------------------------------------------------------
section "Mode=always-on"

printf '{"mode":"always-on"}\n' > "$BELL_CONFIG"

SID_AO="ao-$(date +%s)"

# idle writes state file in always-on mode
echo "{\"session_id\":\"${SID_AO}i\"}" | "$HOOKS_DIR/tab-title.sh" idle > /dev/null 2>&1
if sf_exists "${SID_AO}i"; then ok "always-on: idle writes state file"; else ng "always-on: idle did not write state file"; fi
line2=$(sed -n '2p' "$BELL_STATE_DIR/${SID_AO}i" 2>/dev/null)
[ "$line2" = "idle" ] && ok "always-on: idle state file line 2 = 'idle'" || ng "always-on: idle state file line 2 wrong (got: $line2)"

# working writes state file in always-on mode
echo "{\"session_id\":\"${SID_AO}w\"}" | "$HOOKS_DIR/tab-title.sh" working > /dev/null 2>&1
if sf_exists "${SID_AO}w"; then ok "always-on: working writes state file"; else ng "always-on: working did not write state file"; fi
line2=$(sed -n '2p' "$BELL_STATE_DIR/${SID_AO}w" 2>/dev/null)
[ "$line2" = "working" ] && ok "always-on: working state file line 2 = 'working'" || ng "always-on: working state file line 2 wrong (got: $line2)"

# end removes state file in always-on mode
echo "{\"session_id\":\"${SID_AO}e\"}" | "$HOOKS_DIR/tab-title.sh" idle  > /dev/null 2>&1
echo "{\"session_id\":\"${SID_AO}e\"}" | "$HOOKS_DIR/tab-title.sh" end   > /dev/null 2>&1
if ! sf_exists "${SID_AO}e"; then ok "always-on: end removes state file"; else ng "always-on: end did not remove state file"; fi

# idempotency in always-on: repeated working does not rewrite
echo "{\"session_id\":\"${SID_AO}w2\"}" | "$HOOKS_DIR/tab-title.sh" idle    > /dev/null 2>&1
echo "{\"session_id\":\"${SID_AO}w2\"}" | "$HOOKS_DIR/tab-title.sh" working > /dev/null 2>&1
mt_before=$(stat -f %m "$BELL_STATE_DIR/${SID_AO}w2" 2>/dev/null)
sleep 1.2
echo "{\"session_id\":\"${SID_AO}w2\"}" | "$HOOKS_DIR/tab-title.sh" working > /dev/null 2>&1
mt_after=$(stat -f %m "$BELL_STATE_DIR/${SID_AO}w2" 2>/dev/null)
[ "$mt_before" = "$mt_after" ] && ok "always-on: repeated working is idempotent" || ng "always-on: repeated working rewrote state file"

rm -f "$BELL_STATE_DIR/${SID_AO}i" "$BELL_STATE_DIR/${SID_AO}w" \
      "$BELL_STATE_DIR/${SID_AO}w2"

if [ "$plugin" = "1" ]; then
  # Write a mix of states and verify plugin output.
  printf '%s\n%s\n' "🔔 Claude Code | ao-bell (aoB1)"    "input"   > "$BELL_STATE_DIR/aoB1"
  printf '%s\n%s\n' "⏳ Claude Code | ao-work (aoW1)"    "working" > "$BELL_STATE_DIR/aoW1"
  printf '%s\n%s\n' "Claude Code | ao-idle (aoD1)"       "idle"    > "$BELL_STATE_DIR/aoD1"

  out=$(BELL_CONFIG="$BELL_CONFIG" bash "$PLUGIN_PATH" 2>&1)

  echo "$out" | grep -q '🔔 1' && ok "always-on: header uses emoji bell when input > 0" || ng "always-on: header missing emoji bell: $out"
  echo "$out" | grep -q ':hourglass: 1' && ok "always-on: header contains working count" || ng "always-on: header missing working count: $out"
  echo "$out" | grep -q ':zzz: 1' && ok "always-on: header contains idle count" || ng "always-on: header missing idle count: $out"
  echo "$out" | head -n1 | grep -q 'font=.AppleSystemUIFontBold' && ok "always-on: header uses bold font" || ng "always-on: header missing bold font: $out"
  echo "$out" | grep -q 'ao-bell' && ok "always-on: bell entry present" || ng "always-on: bell entry missing: $out"
  echo "$out" | grep -q 'ao-work' && ok "always-on: working entry present" || ng "always-on: working entry missing: $out"
  echo "$out" | grep -q 'ao-idle' && ok "always-on: idle entry present" || ng "always-on: idle entry missing: $out"
  echo "$out" | grep -q 'sfimage=bell.fill' && ok "always-on: input entry has bell.fill icon" || ng "always-on: input entry missing bell.fill icon: $out"
  echo "$out" | grep -q 'sfimage=hourglass' && ok "always-on: working entry has hourglass icon" || ng "always-on: working entry missing hourglass icon: $out"
  echo "$out" | grep -q 'sfimage=zzz' && ok "always-on: idle entry has zzz icon" || ng "always-on: idle entry missing zzz icon: $out"
  echo "$out" | grep -q 'Awaiting input' && ok "always-on: input section header present" || ng "always-on: input section header missing: $out"
  echo "$out" | grep -q 'Working' && ok "always-on: working section header present" || ng "always-on: working section header missing: $out"
  echo "$out" | grep -q 'Idle' && ok "always-on: idle section header present" || ng "always-on: idle section header missing: $out"

  # With only idle/working (no bell), header shows only hourglass + zzz
  rm -f "$BELL_STATE_DIR/aoB1"
  out2=$(BELL_CONFIG="$BELL_CONFIG" bash "$PLUGIN_PATH" 2>&1)
  echo "$out2" | head -n1 | grep -q ':hourglass:' && ok "always-on: :hourglass: in header when no input sessions" || ng "always-on: :hourglass: missing from header: $out2"
  echo "$out2" | head -n1 | grep -qv ':bell:' && ok "always-on: :bell: absent from header when no input sessions" || ng "always-on: :bell: shown in header when no input: $out2"
  echo "$out2" | head -n1 | grep -qv '🔔' && ok "always-on: emoji bell absent from header when no input sessions" || ng "always-on: emoji bell shown when no input: $out2"
  echo "$out2" | head -n1 | grep -q 'font=.AppleSystemUIFontBold' && ok "always-on: no-input header uses bold font" || ng "always-on: no-input header missing bold font: $out2"

  rm -f "$BELL_STATE_DIR/aoW1" "$BELL_STATE_DIR/aoD1"
else
  skip "always-on: plugin output tests"
fi

# Restore to notifs default for remaining tests.
: > "$BELL_CONFIG"

# ---------------------------------------------------------------------------
section "BELL_TRACE toggle"

unset BELL_TRACE
trace_reset
"$HOOKS_DIR/refresh-menubar.sh" > /dev/null 2>&1
echo "{\"session_id\":\"tA\"}" | "$HOOKS_DIR/tab-title.sh" working > /dev/null 2>&1
[ ! -s "$BELL_TRACE_LOG" ] && ok "unset => zero trace bytes" || ng "trace log written with BELL_TRACE unset ($(wc -c < "$BELL_TRACE_LOG") bytes)"

export BELL_TRACE=1
trace_reset
"$HOOKS_DIR/refresh-menubar.sh" > /dev/null 2>&1
[ -s "$BELL_TRACE_LOG" ] && ok "set => trace populated" || ng "trace empty with BELL_TRACE=1"
unset BELL_TRACE

# ---------------------------------------------------------------------------
section "End-to-end latency"

if [ "$plugin" = "1" ]; then
  SID="e2e-$(date +%s)"
  t0=$(now_ms)
  echo "{\"session_id\":\"$SID\"}" | "$HOOKS_DIR/tab-title.sh" input > /dev/null 2>&1
  t1=$(now_ms)
  if sf_exists "$SID"; then ok "state file written in $((t1-t0)) ms"; else ng "state file not written"; fi

  out=$(bash "$PLUGIN_PATH" 2>&1)
  t2=$(now_ms)
  # tab-title.sh truncates session_id to 8 chars in the rendered title; grep
  # for that substring (the full SID is only visible as the state filename).
  short_sid="${SID:0:8}"
  if echo "$out" | grep -qF "$short_sid"; then ok "plugin reflects new state in $((t2-t1)) ms"
  else ng "plugin did not pick up new state (short=$short_sid): $out"; fi

  echo "{\"session_id\":\"$SID\"}" | "$HOOKS_DIR/tab-title.sh" idle > /dev/null 2>&1
  if ! sf_exists "$SID"; then ok "idle clears e2e state"; else ng "idle did not clear state"; fi
else
  skip "end-to-end"
fi

# ---------------------------------------------------------------------------
printf '\n%s==> Summary:%s %s%d passed%s, %s%d failed%s, %s%d skipped%s\n' \
  "$C_B" "$C_R" \
  "$C_OK" "$PASS" "$C_R" \
  "$C_NG" "$FAIL" "$C_R" \
  "$C_SK" "$SKIP" "$C_R"

exit "$FAIL"
