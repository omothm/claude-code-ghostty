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
  DASHBOARD_PATH="$PROJECT_DIR/.ccg/dashboard.html"
else
  HOOKS_DIR="$HOME/.claude/hooks"
  SWIFTBAR_PLUGIN_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
  PLUGIN_PATH=""
  [ -n "$SWIFTBAR_PLUGIN_DIR" ] && PLUGIN_PATH="$SWIFTBAR_PLUGIN_DIR/ghostty-bells.30s.sh"
  DASHBOARD_PATH="$HOME/.claude/.ccg/dashboard.html"
fi

TMPROOT="$(mktemp -d -t bell-validate.XXXXXX)"
export BELL_STATE_DIR="$TMPROOT/state"
export BELL_TRACE_LOG="$TMPROOT/trace.log"
export BELL_CONFIG="$TMPROOT/bell-config"
export CCG_EVENT_LOG="$TMPROOT/events.jsonl"
export CCG_SESSION_STATE_DIR="$TMPROOT/sessions"
export CCG_PENDING_DIR="$TMPROOT/pending"
# The validator typically runs INSIDE a live Claude Code session, whose
# claude process has live Monitor descendants. Without an override, every
# `idle` test would walk up the process tree, find that claude, and upgrade
# to `watching` — breaking unrelated tests. Pin CCG_CLAUDE_PID to a dead
# PID so the upgrade path is disabled by default; the watching section
# overrides it explicitly per-test to a controlled PID we own.
export CCG_CLAUDE_PID=999999
mkdir -p "$BELL_STATE_DIR" "$CCG_SESSION_STATE_DIR"
touch "$BELL_TRACE_LOG"
# Start with an empty (notifs-default) config.
: > "$BELL_CONFIG"

# Global terminal-notifier stub: several code paths exercised throughout this
# suite (sweep-bell-state.sh's notif-expiry pass on every invocation, its
# idle-refinement "Background task completed" notification, notify.sh calls
# made before a section installs its own PATH-shadowing stub) would otherwise
# shell out to the REAL terminal-notifier — flooding the OS with actual
# notification banners and needlessly touching the live notification database
# on every run. Sections that need to inspect the exact argv still prepend
# their own stub dir onto PATH, which shadows this one, so their assertions
# are unaffected. This just catches everything that would otherwise fall
# through to the real binary.
GLOBAL_NOTIFY_BIN="$TMPROOT/bin-global-notify"
mkdir -p "$GLOBAL_NOTIFY_BIN"
printf '#!/bin/bash\nexit 0\n' > "$GLOBAL_NOTIFY_BIN/terminal-notifier"
chmod +x "$GLOBAL_NOTIFY_BIN/terminal-notifier"
export PATH="$GLOBAL_NOTIFY_BIN:$PATH"

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

FAKE_MONITOR_PIDS=""
cleanup() {
  # Kill any fake-monitor sleep processes the watching section may have spawned.
  for _fp in $FAKE_MONITOR_PIDS; do
    kill "$_fp" 2>/dev/null
  done
  rm -rf "$TMPROOT"
  unset BELL_STATE_DIR BELL_TRACE BELL_TRACE_LOG BELL_CONFIG GHOSTTY_HOOKS_DIR \
        CCG_EVENT_LOG CCG_SESSION_STATE_DIR CCG_CLAUDE_PID CCG_PENDING_DIR
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
section "tab-title.sh title write to terminal"

# Regression guard: Claude Code v2.1.139 spawns hook subprocesses without a
# controlling terminal, so the historical `> /dev/tty` write fails with
# ENXIO and the title silently never updates. The hook must instead resolve
# a TTY by walking up the process tree to a parent that owns one (the
# `claude` process). Verify (a) the trace records the resolved device path,
# and (b) no "Device not configured" error leaks to stderr.

export BELL_TRACE=1
trace_reset
tt_err=$(echo "{\"session_id\":\"tw-$$\"}" | "$HOOKS_DIR/tab-title.sh" idle 2>&1 >/dev/null)
unset BELL_TRACE

# Strip the legitimate first-line stdout (base_title) noise — only stderr matters here.
echo "$tt_err" | grep -qi "device not configured" \
  && ng "hook still writes /dev/tty (ENXIO leaked): $tt_err" \
  || ok "no /dev/tty ENXIO error on hook invocation"

if grep -qE 'title-set title=.* dev=/dev/' "$BELL_TRACE_LOG"; then
  ok "title-set trace records resolved TTY device (parent walk found one)"
elif grep -q 'title-set skipped (no parent tty found)' "$BELL_TRACE_LOG"; then
  # Validator itself runs from a TTY, so its child (the hook) must find one
  # via PPID. Skipping here would mask the very bug we're guarding against.
  ng "hook reported no parent TTY despite validator running from a terminal"
else
  ng "no title-set trace entry produced (hook didn't reach the title-write branch)"
fi

rm -f "$BELL_STATE_DIR/tw-$$"

# ---------------------------------------------------------------------------
section "tab-title.sh terminalSequence JSON output"

# Non-query statuses must emit JSON {"terminalSequence":"..."} containing an
# OSC 2 sequence so Claude Code 2.1.141+ can write it to the terminal directly.
ts_out=$(echo '{"session_id":"ts-test"}' | "$HOOKS_DIR/tab-title.sh" idle 2>/dev/null)
ts_seq=$(printf '%s' "$ts_out" | jq -r '.terminalSequence // empty' 2>/dev/null)
if printf '%s' "$ts_seq" | grep -q $'\033]2;'; then
  ok "non-query stdout is JSON with terminalSequence containing OSC 2"
else
  ng "non-query stdout missing terminalSequence OSC 2 (got: $ts_out)"
fi
rm -f "$BELL_STATE_DIR/ts-test"

# query must still output two plain lines (used by notify.sh subprocess calls)
q_out=$(echo '{"session_id":"ts-test"}' | "$HOOKS_DIR/tab-title.sh" query 2>/dev/null)
q_line1=$(printf '%s' "$q_out" | sed -n '1p')
if [ -n "$q_line1" ] && printf '%s' "$q_line1" | grep -q "Claude Code"; then
  ok "query stdout is plain text (base_title on line 1)"
else
  ng "query stdout format broken (line 1: '$q_line1')"
fi

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

# 6b. cwd + title pin to CLAUDE_PROJECT_DIR (project root), not the live $PWD.
# Guards against drift when Claude cd's mid-session — the event log and tab
# title must reflect the project the session belongs to, not wherever it sits.
PDID="evt-projdir-$$"
PDROOT="$TMPROOT/proj-root-marker"
echo "{\"session_id\":\"$PDID\"}" \
  | CLAUDE_PROJECT_DIR="$PDROOT" "$HOOKS_DIR/tab-title.sh" input > /dev/null 2>&1
pd_last=$(jq -rc --arg sid "$PDID" 'select(.session_id == $sid)' "$CCG_EVENT_LOG" 2>/dev/null | tail -1)
pd_cwd=$(echo "$pd_last" | jq -r '.cwd')
[ "$pd_cwd" = "$PDROOT" ] \
  && ok "event cwd pins to CLAUDE_PROJECT_DIR (not live \$PWD)" \
  || ng "event cwd wrong: got '$pd_cwd' want '$PDROOT'"
echo "$pd_last" | jq -r '.title' | grep -q 'proj-root-marker' \
  && ok "event title basenames CLAUDE_PROJECT_DIR" \
  || ng "event title missing project basename: $(echo "$pd_last" | jq -r '.title')"
# Tidy the bell-state file this input left behind so it doesn't inflate later
# plugin-count assertions.
echo "{\"session_id\":\"$PDID\"}" | "$HOOKS_DIR/tab-title.sh" end > /dev/null 2>&1

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
section "Plugin output: last-update timestamp + oldest-first sort"

if [ "$plugin" = "1" ]; then
  write_sf "tsNewer" "🔔 Claude Code | ts-newer (tsN1)"
  age_file "1 minute ago" "$BELL_STATE_DIR/tsNewer"
  write_sf "tsOlder" "🔔 Claude Code | ts-older (tsO1)"
  age_file "5 minutes ago" "$BELL_STATE_DIR/tsOlder"

  out=$(bash "$PLUGIN_PATH" 2>&1)

  expected_older_ts=$(date -r "$(stat -f %m "$BELL_STATE_DIR/tsOlder")" "+%-I:%M %p" 2>/dev/null)
  expected_newer_ts=$(date -r "$(stat -f %m "$BELL_STATE_DIR/tsNewer")" "+%-I:%M %p" 2>/dev/null)

  echo "$out" | grep -q "ts-older.*${expected_older_ts}" \
    && ok "notifs: entry shows its own last-update time" \
    || ng "notifs: missing/wrong timestamp for ts-older: $out"
  echo "$out" | grep -q 'ansi=true' \
    && ok "notifs: entries opt into ansi=true for muted timestamp color" \
    || ng "notifs: ansi=true missing: $out"
  echo "$out" | grep -q $'\033\[38;5;245m' \
    && ok "notifs: timestamp uses muted gray ANSI color" \
    || ng "notifs: muted gray ANSI escape missing"

  older_line=$(echo "$out" | grep -n 'ts-older' | head -n1 | cut -d: -f1)
  newer_line=$(echo "$out" | grep -n 'ts-newer' | head -n1 | cut -d: -f1)
  if [ -n "$older_line" ] && [ -n "$newer_line" ] && [ "$older_line" -lt "$newer_line" ]; then
    ok "notifs: oldest-updated entry sorts first"
  else
    ng "notifs: sort order wrong (older=$older_line newer=$newer_line)"
  fi

  rm -f "$BELL_STATE_DIR/tsNewer" "$BELL_STATE_DIR/tsOlder"

  # Same check in always-on mode, within a single section (Working).
  printf '{"mode":"always-on"}\n' > "$BELL_CONFIG"
  printf '⏳ Claude Code | ao-ts-newer (aoTsN1)\nworking\n' > "$BELL_STATE_DIR/aoTsNewer"
  age_file "1 minute ago" "$BELL_STATE_DIR/aoTsNewer"
  printf '⏳ Claude Code | ao-ts-older (aoTsO1)\nworking\n' > "$BELL_STATE_DIR/aoTsOlder"
  age_file "5 minutes ago" "$BELL_STATE_DIR/aoTsOlder"

  out=$(BELL_CONFIG="$BELL_CONFIG" bash "$PLUGIN_PATH" 2>&1)

  older_line=$(echo "$out" | grep -n 'ao-ts-older' | head -n1 | cut -d: -f1)
  newer_line=$(echo "$out" | grep -n 'ao-ts-newer' | head -n1 | cut -d: -f1)
  if [ -n "$older_line" ] && [ -n "$newer_line" ] && [ "$older_line" -lt "$newer_line" ]; then
    ok "always-on: oldest-updated entry sorts first within its section"
  else
    ng "always-on: sort order wrong within section (older=$older_line newer=$newer_line)"
  fi
  echo "$out" | grep -q 'ao-ts-older.*ansi=true' \
    && ok "always-on: entry shows muted timestamp with ansi=true" \
    || ng "always-on: ansi=true/timestamp missing: $out"

  rm -f "$BELL_STATE_DIR/aoTsNewer" "$BELL_STATE_DIR/aoTsOlder"
  : > "$BELL_CONFIG"
else
  skip "plugin output: last-update timestamp + sort tests"
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

# Hard-age: 13h-old file pruned unconditionally (cap is 12h)
write_sf "sH" "🔔 Claude Code | hard-aged (sH12345)"
age_file "13 hours ago" "$BELL_STATE_DIR/sH"
export BELL_TRACE=1; trace_reset
"$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
if ! sf_exists "sH"; then ok "hard-age cap (12h) prunes"; else ng "hard-age did not prune"; fi
grep -q "hard-expire" "$BELL_TRACE_LOG" && ok "sweep logs hard-expire" || ng "no hard-expire in trace"

# Fresh file (no age manipulation) is protected from the hard-age cap.
write_sf "sF" "🔔 Claude Code | fresh-survives-sweep (sFresh)"
"$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
if sf_exists "sF"; then ok "fresh file (< 12h) survives sweep"; else ng "fresh file pruned by hard-age cap"; fi
rm -f "$BELL_STATE_DIR/sF"

# Regression guard: the sweep must NOT prune based on Ghostty's tab tree.
# A previous version queried AppleScript for live tab titles and deleted
# state files whose titles weren't present, but the AX query races with
# Ghostty's tab-bar redraws and intermittently returns partial lists,
# which silently dropped live idle sessions from the menubar. The sweep
# is now hard-age-only.
write_sf "sN" "🔔 Claude Code | not-in-any-ax (sN-$(date +%s))"
age_file "6 minutes ago" "$BELL_STATE_DIR/sN"
"$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
if sf_exists "sN"; then ok "AX-verified prune is gone (past-grace file with absent title survives)"
else ng "sweep deleted a file that's only past the old 5-min grace — AX prune re-introduced?"; fi
rm -f "$BELL_STATE_DIR/sN"

# Sweep fires refresh after pruning
write_sf "sR" "🔔 Claude Code | sweep-refresh-trigger (sR)"
age_file "13 hours ago" "$BELL_STATE_DIR/sR"
trace_reset
"$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
grep -q "refresh-menubar.sh" "$BELL_TRACE_LOG" && ok "sweep triggers refresh after pruning" || ng "sweep did not trigger refresh after pruning"

# PID-liveness: file with dead PID is pruned quickly (no need to wait 12h).
printf '⏳ Claude Code | orphan-working (sPL1)\nworking\n999999\n' > "$BELL_STATE_DIR/sPL1"
export BELL_TRACE=1; trace_reset
"$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
if ! sf_exists "sPL1"; then ok "pid-liveness: orphaned working (dead PID) pruned"; else ng "pid-liveness: orphaned file not pruned"; fi
grep -q "pid-expire" "$BELL_TRACE_LOG" && ok "sweep logs pid-expire" || ng "no pid-expire in trace"

# PID-liveness: file with live PID is preserved.
printf '⏳ Claude Code | live-working (sPL2)\nworking\n%s\n' "$$" > "$BELL_STATE_DIR/sPL2"
trace_reset
"$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
if sf_exists "sPL2"; then ok "pid-liveness: live session (live PID) preserved"; else ng "pid-liveness: live session wrongly pruned"; fi
rm -f "$BELL_STATE_DIR/sPL2"

# PID-liveness: a FRESH file with no PID is kept (a live session may rewrite it
# with a PID on its next transition; don't evict prematurely).
printf '🔔 Claude Code | no-pid-legacy (sPL3)\ninput\n' > "$BELL_STATE_DIR/sPL3"
trace_reset
"$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
if sf_exists "sPL3"; then ok "pid-liveness: fresh no-PID file kept"; else ng "pid-liveness: fresh no-PID file wrongly pruned"; fi
rm -f "$BELL_STATE_DIR/sPL3"

# PID-liveness: a STALE no-PID file (untouched past NO_PID_STALE_MIN) is reaped,
# so a stuck phantom (e.g. _find_claude_pid failed at write time) clears from
# the menubar without waiting the 12h hard-age cap.
printf '⏳ Claude Code | stale-no-pid (sPL4)\nworking\n' > "$BELL_STATE_DIR/sPL4"
age_file "70 minutes ago" "$BELL_STATE_DIR/sPL4"
trace_reset
"$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
if ! sf_exists "sPL4"; then ok "pid-liveness: stale (>NO_PID_STALE_MIN) no-PID file reaped"; else ng "pid-liveness: stale no-PID file not reaped"; fi
grep -q "no-pid-stale-expire" "$BELL_TRACE_LOG" && ok "sweep logs no-pid-stale-expire" || ng "no no-pid-stale-expire in trace"

# Pending-set cleanup: a leaked pending dir (crashed session, no end hook) older
# than 12h is hard-expired; a fresh one is preserved.
rm -rf "$CCG_PENDING_DIR"; mkdir -p "$CCG_PENDING_DIR/stale-sess" "$CCG_PENDING_DIR/fresh-sess"
: > "$CCG_PENDING_DIR/stale-sess/AAAA"
: > "$CCG_PENDING_DIR/fresh-sess/BBBB"
age_file "13 hours ago" "$CCG_PENDING_DIR/stale-sess" 2>/dev/null
"$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
[ ! -d "$CCG_PENDING_DIR/stale-sess" ] && ok "pending sweep: stale (>12h) pending dir pruned" || ng "pending sweep: stale dir not pruned"
[ -d "$CCG_PENDING_DIR/fresh-sess" ] && ok "pending sweep: fresh pending dir preserved" || ng "pending sweep: fresh dir wrongly pruned"
rm -rf "$CCG_PENDING_DIR"
unset BELL_TRACE

# Logical-state reconciliation: the sweep emits a synthetic `end` to
# events.jsonl for a session whose owning claude PID is dead but that never
# fired SessionEnd, so the dashboard's right-now count converges with the
# menubar (which reaps bell-state files on the same signal). The synthetic
# `end` ts is capped at mtime + 30 min to match the dashboard's trailing-span
# cap, NOT `now` (which would inflate the dead session's working-time).
mkdir -p "$CCG_SESSION_STATE_DIR"
: > "$CCG_EVENT_LOG"

# Dead PID → emit `end`, remove logical-state file.
# Age 40 min so mtime + 30min cap lands below `now` (the uncapped path);
# a fresher file would clamp to now and not exercise the cap arithmetic.
printf 'working\n999999\n' > "$CCG_SESSION_STATE_DIR/recon-dead"
recon_mtime=$(gdate -d "40 minutes ago" +%s)
age_file "40 minutes ago" "$CCG_SESSION_STATE_DIR/recon-dead"
"$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
if jq -e 'select(.session_id=="recon-dead" and .state=="end")' "$CCG_EVENT_LOG" >/dev/null 2>&1; then
  ok "reconcile: dead-PID session gets synthetic end in events.jsonl"
else ng "reconcile: no synthetic end emitted for dead-PID session"; fi
[ ! -f "$CCG_SESSION_STATE_DIR/recon-dead" ] && ok "reconcile: dead-PID logical-state file removed" || ng "reconcile: dead-PID logical-state file not removed"
# ts must be mtime + 1800 (the trailing-span cap), not `now`.
recon_ts=$(jq -r 'select(.session_id=="recon-dead" and .state=="end") | .ts' "$CCG_EVENT_LOG" 2>/dev/null | tail -1)
recon_expected=$((recon_mtime + 1800))
if [ -n "$recon_ts" ] && [ "${recon_ts%.*}" = "$recon_expected" ]; then
  ok "reconcile: synthetic end ts == mtime + 30min cap (not now)"
else ng "reconcile: synthetic end ts wrong (got ${recon_ts:-<none>}, want $recon_expected)"; fi

# Live PID → keep, no `end`.
: > "$CCG_EVENT_LOG"
printf 'working\n%s\n' "$$" > "$CCG_SESSION_STATE_DIR/recon-live"
"$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
if jq -e 'select(.session_id=="recon-live")' "$CCG_EVENT_LOG" >/dev/null 2>&1; then
  ng "reconcile: live-PID session wrongly got an end"
else ok "reconcile: live-PID session left untouched (no end)"; fi
[ -f "$CCG_SESSION_STATE_DIR/recon-live" ] && ok "reconcile: live-PID logical-state file preserved" || ng "reconcile: live-PID logical-state file wrongly removed"
rm -f "$CCG_SESSION_STATE_DIR/recon-live"

# No-PID logical-state file: fresh → kept; stale (>NO_PID_STALE_MIN) → reaped
# with end, in lockstep with the bell-state no-PID cap.
: > "$CCG_EVENT_LOG"
printf 'idle\n' > "$CCG_SESSION_STATE_DIR/recon-legacy-fresh"
printf 'idle\n' > "$CCG_SESSION_STATE_DIR/recon-legacy-old"
age_file "70 minutes ago" "$CCG_SESSION_STATE_DIR/recon-legacy-old"
"$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
[ -f "$CCG_SESSION_STATE_DIR/recon-legacy-fresh" ] && ok "reconcile: fresh no-PID file kept" || ng "reconcile: fresh no-PID file wrongly reaped"
if [ ! -f "$CCG_SESSION_STATE_DIR/recon-legacy-old" ] && jq -e 'select(.session_id=="recon-legacy-old" and .state=="end")' "$CCG_EVENT_LOG" >/dev/null 2>&1; then
  ok "reconcile: stale no-PID file reaped with end"
else ng "reconcile: legacy no-PID aged file not reaped/end-emitted"; fi
rm -f "$CCG_SESSION_STATE_DIR/recon-legacy-fresh"

# tab-title.sh writes a 2-line logical-state file (state + pid) and dedup still
# works off line 1. Precede with idle so the logical-state file exists — a real
# session always fires SessionStart(idle) before the first working.
: > "$CCG_EVENT_LOG"; rm -rf "$CCG_SESSION_STATE_DIR"; mkdir -p "$CCG_SESSION_STATE_DIR"
CCG_CLAUDE_PID=4242 "$HOOKS_DIR/tab-title.sh" idle "recon-fmt" >/dev/null 2>&1
CCG_CLAUDE_PID=4242 "$HOOKS_DIR/tab-title.sh" working "recon-fmt" >/dev/null 2>&1
_lsf="$CCG_SESSION_STATE_DIR/recon-fmt"
if [ "$(sed -n '1p' "$_lsf" 2>/dev/null)" = "working" ] && [ "$(sed -n '2p' "$_lsf" 2>/dev/null)" = "4242" ]; then
  ok "tab-title: logical-state file is 2-line (state + pid)"
else ng "tab-title: logical-state file not 2-line state+pid (got: $(cat "$_lsf" 2>/dev/null | tr '\n' '/'))"; fi
# Second identical working must dedup (no new event appended).
_before=$(wc -l < "$CCG_EVENT_LOG")
CCG_CLAUDE_PID=4242 "$HOOKS_DIR/tab-title.sh" working "recon-fmt" >/dev/null 2>&1
_after=$(wc -l < "$CCG_EVENT_LOG")
[ "$_before" = "$_after" ] && ok "tab-title: dedup still works off line 1 (2-line file)" || ng "tab-title: dedup broke with 2-line logical-state file"
rm -rf "$CCG_SESSION_STATE_DIR"; mkdir -p "$CCG_SESSION_STATE_DIR"; : > "$CCG_EVENT_LOG"

# Idle-refinement correction pass: a bell-state file stuck at `agents` (or
# `watching`) with NO further hook ever firing must self-correct via the
# background sweep, not just at hook time. This is the fix for the reported
# live bug: a background agent finished, the session went fully quiet (no
# more hooks), and the ☕️ tab title + menubar entry stayed stuck indefinitely
# because nothing but a hook ever re-derived idle-refinement state.
# The pass is gated on always-on mode (see test 4 below); this section's
# BELL_CONFIG is otherwise empty (notifs default), so switch explicitly.
printf '{"mode":"always-on"}\n' > "$BELL_CONFIG"
export CCG_PROJECTS_DIR="$TMPROOT/sweep-projects"
mkdir -p "$CCG_PROJECTS_DIR"

# 1. agents -> idle: bell-state file says agents, live PID, but the subagent
#    transcript is stale (no live agent). Sweep must rewrite the file to idle
#    and strip the ☕️ prefix from the title.
IRSID="ir-agents-stale-$$"
mkdir -p "$CCG_PROJECTS_DIR/fake-project/$IRSID/subagents"
: > "$CCG_PROJECTS_DIR/fake-project/$IRSID/subagents/agent-oldhex$$.jsonl"
age_file "5 minutes ago" "$CCG_PROJECTS_DIR/fake-project/$IRSID/subagents/agent-oldhex$$.jsonl"
printf '☕️ Claude Code | ir-agents-stale (%s)\nagents\n%s\n' "$IRSID" "$$" > "$BELL_STATE_DIR/$IRSID"
CCG_AGENTS_FRESH_SEC=5 "$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
line2=$(sed -n '2p' "$BELL_STATE_DIR/$IRSID" 2>/dev/null)
line1=$(sed -n '1p' "$BELL_STATE_DIR/$IRSID" 2>/dev/null)
[ "$line2" = "idle" ] && ok "sweep idle-refinement: stuck agents (stale transcript, live PID) corrected to idle" \
  || ng "sweep idle-refinement: agents not corrected (got '$line2')"
case "$line1" in "☕️ "*) ng "sweep idle-refinement: title still has ☕️ prefix after correction to idle" ;; *) ok "sweep idle-refinement: ☕️ prefix stripped from title" ;; esac
rm -f "$BELL_STATE_DIR/$IRSID"

# 2. idle -> agents: bell-state file says idle, live PID, but a fresh subagent
#    transcript exists (a real live background agent the hook missed, e.g.
#    the stray-working guard's own-transcript exclusion cleared it while a
#    DIFFERENT sibling was still running and no subsequent hook re-checked).
IRSID2="ir-idle-live-$$"
mkdir -p "$CCG_PROJECTS_DIR/fake-project/$IRSID2/subagents"
: > "$CCG_PROJECTS_DIR/fake-project/$IRSID2/subagents/agent-freshhex$$.jsonl"
printf 'Claude Code | ir-idle-live (%s)\nidle\n%s\n' "$IRSID2" "$$" > "$BELL_STATE_DIR/$IRSID2"
"$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
line2=$(sed -n '2p' "$BELL_STATE_DIR/$IRSID2" 2>/dev/null)
line1=$(sed -n '1p' "$BELL_STATE_DIR/$IRSID2" 2>/dev/null)
[ "$line2" = "agents" ] && ok "sweep idle-refinement: stuck idle (live transcript) corrected to agents" \
  || ng "sweep idle-refinement: idle not corrected to agents (got '$line2')"
case "$line1" in "☕️ "*) ok "sweep idle-refinement: ☕️ prefix added to corrected title" ;; *) ng "sweep idle-refinement: title missing ☕️ prefix after correction (got '$line1')" ;; esac
rm -f "$BELL_STATE_DIR/$IRSID2"

# 3. Dead PID is left alone by the idle-refinement pass (the PID-liveness pass
#    above already reaps it; this pass must not resurrect a dead session).
IRSID3="ir-dead-pid-$$"
mkdir -p "$CCG_PROJECTS_DIR/fake-project/$IRSID3/subagents"
: > "$CCG_PROJECTS_DIR/fake-project/$IRSID3/subagents/agent-deadhex$$.jsonl"
printf '☕️ Claude Code | ir-dead-pid (%s)\nagents\n999999\n' "$IRSID3" > "$BELL_STATE_DIR/$IRSID3"
"$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
if ! sf_exists "$IRSID3"; then ok "sweep idle-refinement: dead-PID agents file pruned (not corrected) by PID-liveness pass"
else ng "sweep idle-refinement: dead-PID file unexpectedly survived"; fi

# 4. Not in always-on mode: the idle-refinement pass is gated on always-on,
#    since notifs mode doesn't write agents/watching bell-state files at all
#    (nothing to correct).
: > "$BELL_CONFIG"  # notifs default
IRSID4="ir-notifs-$$"
printf '☕️ Claude Code | ir-notifs (%s)\nagents\n%s\n' "$IRSID4" "$$" > "$BELL_STATE_DIR/$IRSID4"
"$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
line2=$(sed -n '2p' "$BELL_STATE_DIR/$IRSID4" 2>/dev/null)
[ "$line2" = "agents" ] && ok "sweep idle-refinement: gated on always-on mode (untouched in notifs)" \
  || ng "sweep idle-refinement: incorrectly ran outside always-on mode (got '$line2')"
rm -f "$BELL_STATE_DIR/$IRSID4"
printf '{"mode":"always-on"}\n' > "$BELL_CONFIG"

# 5. Logical-state file (events.jsonl path) gets the same correction: a
#    session logged as `agents` with a live PID but stale transcript emits a
#    new `idle` event and rewrites the logical-state file, so the dashboard's
#    right-now count converges with the corrected bell-state/tab-title.
: > "$CCG_EVENT_LOG"
IRSID5="ir-logical-$$"
mkdir -p "$CCG_PROJECTS_DIR/fake-project/$IRSID5/subagents"
: > "$CCG_PROJECTS_DIR/fake-project/$IRSID5/subagents/agent-logicalhex$$.jsonl"
age_file "5 minutes ago" "$CCG_PROJECTS_DIR/fake-project/$IRSID5/subagents/agent-logicalhex$$.jsonl"
printf 'agents\n%s\n' "$$" > "$CCG_SESSION_STATE_DIR/$IRSID5"
CCG_AGENTS_FRESH_SEC=5 "$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
if jq -e --arg sid "$IRSID5" 'select(.session_id==$sid and .state=="idle")' "$CCG_EVENT_LOG" >/dev/null 2>&1; then
  ok "sweep idle-refinement: logical-state agents->idle emits corrected events.jsonl entry"
else ng "sweep idle-refinement: no corrected event emitted for logical-state file"; fi
[ "$(sed -n '1p' "$CCG_SESSION_STATE_DIR/$IRSID5" 2>/dev/null)" = "idle" ] \
  && ok "sweep idle-refinement: logical-state file rewritten to idle" \
  || ng "sweep idle-refinement: logical-state file not rewritten"
rm -f "$CCG_SESSION_STATE_DIR/$IRSID5"

# 6. agents -> idle via the logical-state pass fires the deferred "Background
#    task completed" notification (via notify.sh) — the counterpart to
#    notify.sh's gate=agents suppression on the Stop hook's "Task completed"
#    call: the notification the Stop hook swallowed must show up here once the
#    background agent actually finishes, or the user is never told.
IRNOTIFY_BIN="$TMPROOT/bin-ir-notify"
mkdir -p "$IRNOTIFY_BIN"
IRNOTIFY_ARGS="$TMPROOT/tn-args-ir.txt"
# Append (not overwrite): sweep-bell-state.sh's own notif-expiry pass also
# calls terminal-notifier (-list ALL) later in the same run, which would
# otherwise clobber the completion-notification argv we're checking for.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$IRNOTIFY_ARGS" > "$IRNOTIFY_BIN/terminal-notifier"
chmod +x "$IRNOTIFY_BIN/terminal-notifier"
_saved_path_ir="$PATH"
export PATH="$IRNOTIFY_BIN:$PATH"
: > "$CCG_EVENT_LOG"
IRSID6="ir-notify-$$"
mkdir -p "$CCG_PROJECTS_DIR/fake-project/$IRSID6/subagents"
: > "$CCG_PROJECTS_DIR/fake-project/$IRSID6/subagents/agent-notifyhex$$.jsonl"
age_file "5 minutes ago" "$CCG_PROJECTS_DIR/fake-project/$IRSID6/subagents/agent-notifyhex$$.jsonl"
printf 'agents\n%s\n' "$$" > "$CCG_SESSION_STATE_DIR/$IRSID6"
: > "$IRNOTIFY_ARGS"
CCG_AGENTS_FRESH_SEC=5 "$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
grep -qF -- "-message Background task completed" "$IRNOTIFY_ARGS" 2>/dev/null \
  && ok "sweep idle-refinement: agents->idle fires 'Background task completed' notification" \
  || ng "sweep idle-refinement: no completion notification fired (got: $(cat "$IRNOTIFY_ARGS" 2>/dev/null))"
rm -f "$CCG_SESSION_STATE_DIR/$IRSID6"

# 6b. A plain idle->idle (no transition) or non-agents->idle transition must
#     NOT fire the notification — only the specific agents->idle edge.
IRSID7="ir-notify-nowatch-$$"
mkdir -p "$CCG_PROJECTS_DIR/fake-project/$IRSID7/subagents"
printf 'watching\n%s\n' "$$" > "$CCG_SESSION_STATE_DIR/$IRSID7"
: > "$IRNOTIFY_ARGS"
"$HOOKS_DIR/sweep-bell-state.sh" > /dev/null 2>&1
grep -qF -- "-message Background task completed" "$IRNOTIFY_ARGS" 2>/dev/null \
  && ng "sweep idle-refinement: watching->idle wrongly fired notification (got: $(cat "$IRNOTIFY_ARGS" 2>/dev/null))" \
  || ok "sweep idle-refinement: watching->idle does not fire completion notification"
rm -f "$CCG_SESSION_STATE_DIR/$IRSID7"

export PATH="$_saved_path_ir"

rm -rf "$CCG_PROJECTS_DIR"; unset CCG_PROJECTS_DIR
rm -rf "$CCG_SESSION_STATE_DIR"; mkdir -p "$CCG_SESSION_STATE_DIR"; : > "$CCG_EVENT_LOG"

# Restore to the canonical sandbox state-dir for the remaining sections.
export BELL_STATE_DIR="$TMPROOT/state"
mkdir -p "$BELL_STATE_DIR"

# ---------------------------------------------------------------------------
section "watching state (idle + live Claude-owned monitor)"

# Reset the event log and per-session state so this section's counts are
# independent of earlier sections.
: > "$CCG_EVENT_LOG"
rm -rf "$CCG_SESSION_STATE_DIR"
mkdir -p "$CCG_SESSION_STATE_DIR"

# Spawn a fake "monitor" — a child of THIS validator process whose argv
# contains the same /tmp/claude-<hex>-cwd marker Claude Code emits for its
# bash-tool wrapper. exec -a rewrites argv[0] so ps -o command= sees the
# marker, which is what tab-title.sh and the plugin grep for. The marker
# hex must be all [0-9a-f] — `fakebeef` works because every char is hex;
# anything like `fake1234` would also pass the regex.
(exec -a "_fake-mon /tmp/claude-deef-cwd live" sleep 60) &
FAKE_MON_PID=$!
FAKE_MONITOR_PIDS="$FAKE_MONITOR_PIDS $FAKE_MON_PID"
sleep 0.2

# Confirm the marker process is visible to ps under our PID. If this fails
# the rest of the section is meaningless (exec -a may have been intercepted
# by some shell quirk), so we ng + skip.
ps_seen=$(ps -axo ppid=,command= 2>/dev/null \
  | awk -v p="$$" '$1 == p && /\/tmp\/claude-[0-9a-f]+-cwd/ { n++ } END { print n+0 }')
if [ "$ps_seen" -gt 0 ]; then
  ok "fake monitor visible under validator PID (ps awk count = $ps_seen)"

  # always-on so we can observe the state file.
  printf '{"mode":"always-on"}\n' > "$BELL_CONFIG"

  # Pipeline-aware hook invoker. `VAR=x cmd1 | cmd2` only exports VAR to
  # cmd1, so we have to set CCG_CLAUDE_PID inside a subshell that owns both
  # ends of the pipe.
  _run_hook_with_cpid() {
    local cpid="$1" status="$2" sid="$3"
    ( export CCG_CLAUDE_PID="$cpid"
      printf '{"session_id":"%s"}\n' "$sid" | "$HOOKS_DIR/tab-title.sh" "$status" > /dev/null 2>&1 )
  }

  # 1. idle + live monitor + CCG_CLAUDE_PID override → upgrades to watching.
  WSID="wA-$$"
  _run_hook_with_cpid "$$" idle "$WSID"
  if sf_exists "$WSID"; then ok "watching: state file written"; else ng "watching: no state file"; fi
  line1=$(sed -n '1p' "$BELL_STATE_DIR/$WSID" 2>/dev/null)
  line2=$(sed -n '2p' "$BELL_STATE_DIR/$WSID" 2>/dev/null)
  line3=$(sed -n '3p' "$BELL_STATE_DIR/$WSID" 2>/dev/null)
  case "$line1" in "👀 "*) ok "watching: state file line 1 has 👀 prefix" ;; *) ng "watching: line 1 missing 👀: $line1" ;; esac
  [ "$line2" = "watching" ] && ok "watching: state file line 2 = 'watching'" || ng "watching: line 2 wrong (got '$line2')"
  [ "$line3" = "$$" ] && ok "watching: state file line 3 = validator PID" || ng "watching: line 3 wrong (got '$line3', expected '$$')"

  # 2. Event log records the watching transition (not idle).
  last_state=$(jq -r --arg sid "$WSID" 'select(.session_id == $sid) | .state' "$CCG_EVENT_LOG" 2>/dev/null | tail -1)
  [ "$last_state" = "watching" ] && ok "watching: event log state == 'watching'" || ng "watching: event log state wrong (got '$last_state')"

  # 3. Per-session logical-state file uses 'watching' so a repeat idle
  #    transition with the monitor still alive doesn't re-log.
  events_before=$(jq -rc --arg sid "$WSID" 'select(.session_id == $sid)' "$CCG_EVENT_LOG" 2>/dev/null | wc -l | tr -d ' ')
  _run_hook_with_cpid "$$" idle "$WSID"
  events_after=$(jq -rc --arg sid "$WSID" 'select(.session_id == $sid)' "$CCG_EVENT_LOG" 2>/dev/null | wc -l | tr -d ' ')
  [ "$events_before" = "$events_after" ] && ok "watching: repeat idle with same monitor does not duplicate event" \
    || ng "watching: repeat idle re-logged (before=$events_before after=$events_after)"

  rm -f "$BELL_STATE_DIR/$WSID"

  # 4. idle WITHOUT a monitor → plain idle (override at a PID with no marker
  #    children; the global default CCG_CLAUDE_PID=999999 already does this,
  #    but we make the test explicit by pointing at PID 1).
  ISID="iA-$$"
  _run_hook_with_cpid 1 idle "$ISID"
  line2=$(sed -n '2p' "$BELL_STATE_DIR/$ISID" 2>/dev/null)
  line3=$(sed -n '3p' "$BELL_STATE_DIR/$ISID" 2>/dev/null)
  [ "$line2" = "idle" ] && ok "no-monitor idle: line 2 = 'idle'" || ng "no-monitor idle: line 2 wrong (got '$line2')"
  [ "$line3" = "1" ] && ok "no-monitor idle: line 3 holds claude_pid" \
    || ng "no-monitor idle: line 3 wrong (got '$line3', expected '1')"

  last_state=$(jq -r --arg sid "$ISID" 'select(.session_id == $sid) | .state' "$CCG_EVENT_LOG" 2>/dev/null | tail -1)
  [ "$last_state" = "idle" ] && ok "no-monitor idle: event log state == 'idle'" || ng "no-monitor idle: event state wrong (got '$last_state')"
  rm -f "$BELL_STATE_DIR/$ISID"

  # 5. notifs mode: watching does NOT write a state file (watching is a
  #    refinement of idle, and idle is invisible in notifs mode).
  : > "$BELL_CONFIG"  # empty → notifs default
  NSID="nA-$$"
  _run_hook_with_cpid "$$" idle "$NSID"
  if ! sf_exists "$NSID"; then ok "notifs mode: watching writes no state file (idle-equivalent)"
  else ng "notifs mode: watching wrote a state file"; fi
  # Event log still records the watching transition (events are mode-independent).
  last_state=$(jq -r --arg sid "$NSID" 'select(.session_id == $sid) | .state' "$CCG_EVENT_LOG" 2>/dev/null | tail -1)
  [ "$last_state" = "watching" ] && ok "notifs mode: event log still records watching" || ng "notifs mode: event state wrong (got '$last_state')"

  # 6. Plugin output (always-on): watching session shows up under its own
  #    section, positioned between Working and Idle, with the 👀 emoji in
  #    the header count and sfimage=binoculars on the entry. Stale watching files
  #    (claude_pid alive but no marker child OR claude_pid dead) are
  #    downgraded to idle so the dropdown reflects current reality.
  if [ "$plugin" = "1" ]; then
    printf '{"mode":"always-on"}\n' > "$BELL_CONFIG"
    rm -f "$BELL_STATE_DIR"/*

    # One live watching file (line 3 = $$, which has the fake-mon child).
    printf '👀 Claude Code | live-watch (lW1)\nwatching\n%s\n' "$$" > "$BELL_STATE_DIR/lW1"
    # One stale watching file (line 3 = dead PID 999999).
    printf '👀 Claude Code | stale-watch (sW1)\nwatching\n999999\n'  > "$BELL_STATE_DIR/sW1"
    # One working + one idle so we can verify section order.
    printf '⏳ Claude Code | working-sess (wK1)\nworking\n'          > "$BELL_STATE_DIR/wK1"
    printf 'Claude Code | idle-sess (iD1)\nidle\n'                    > "$BELL_STATE_DIR/iD1"

    # GHOSTTY_HOOKS_DIR="$TMPROOT" suppresses the background sweep the plugin
    # fires on every run. The sweep would race and delete the stale file (dead
    # PID 999999) before the plugin's first counting pass, making the test
    # non-deterministic. We want to exercise the plugin's own _file_status
    # downgrade logic here, not the sweep — the sweep is tested separately.
    out=$(BELL_STATE_DIR="$BELL_STATE_DIR" BELL_CONFIG="$BELL_CONFIG" \
          GHOSTTY_HOOKS_DIR="$TMPROOT" bash "$PLUGIN_PATH" 2>&1)

    # Header includes the :binoculars: count == 1 (only the live watching file).
    # The segment is shown only when count > 0 (otherwise it would clutter
    # the menubar — watching is rare).
    echo "$out" | head -n1 | grep -q ':binoculars: 1' \
      && ok "plugin: always-on header includes ':binoculars: 1'" \
      || ng "plugin: header missing ':binoculars: 1': $(echo "$out" | head -n1)"

    # Header :zzz: count == 2 (idle-sess + downgraded stale-watch).
    echo "$out" | head -n1 | grep -q ':zzz: 2' \
      && ok "plugin: stale watching counts toward :zzz:" \
      || ng "plugin: :zzz: count wrong: $(echo "$out" | head -n1)"

    # Section "Watching" present with the live entry.
    echo "$out" | grep -q '^Watching | size=11' \
      && ok "plugin: 'Watching' section header emitted" \
      || ng "plugin: 'Watching' section header missing"
    echo "$out" | grep -q 'live-watch.*sfimage=binoculars' \
      && ok "plugin: live watching entry uses sfimage=binoculars" \
      || ng "plugin: live watching entry missing sfimage=binoculars"

    # Stale watching demoted into the Idle section, 👀 prefix stripped from
    # the display path (param1 is read by focus-ghostty-tab.sh — the actual
    # tab title still has 👀 until the next hook firing, so we don't rewrite
    # the file, just the display).
    echo "$out" | grep -q 'stale-watch.*sfimage=zzz' \
      && ok "plugin: stale watching downgrades to sfimage=zzz" \
      || ng "plugin: stale watching not downgraded: $out"

    # Section order: Working appears before Watching appears before Idle.
    working_line=$(echo "$out" | grep -n '^Working | size=11' | head -n1 | cut -d: -f1)
    watching_line=$(echo "$out" | grep -n '^Watching | size=11' | head -n1 | cut -d: -f1)
    idle_line=$(echo "$out" | grep -n '^Idle | size=11' | head -n1 | cut -d: -f1)
    if [ -n "$working_line" ] && [ -n "$watching_line" ] && [ -n "$idle_line" ] \
       && [ "$working_line" -lt "$watching_line" ] \
       && [ "$watching_line" -lt "$idle_line" ]; then
      ok "plugin: section order is Working → Watching → Idle"
    else
      ng "plugin: section order wrong (working=$working_line watching=$watching_line idle=$idle_line)"
    fi

    # Watching count zero → the :binoculars: segment must be entirely absent from
    # the header (the same hide-when-zero behavior the 🔔 segment has).
    rm -f "$BELL_STATE_DIR/lW1" "$BELL_STATE_DIR/sW1"
    out2=$(BELL_STATE_DIR="$BELL_STATE_DIR" BELL_CONFIG="$BELL_CONFIG" bash "$PLUGIN_PATH" 2>&1)
    echo "$out2" | head -n1 | grep -qv ':binoculars:' \
      && ok "plugin: ':binoculars:' segment hidden when watching count is 0" \
      || ng "plugin: ':binoculars:' segment shown despite zero count: $(echo "$out2" | head -n1)"
    # Sanity: the other always-shown segments are still there.
    echo "$out2" | head -n1 | grep -q ':hourglass:' \
      && ok "plugin: ':hourglass:' segment still shown alongside" \
      || ng "plugin: ':hourglass:' segment missing: $(echo "$out2" | head -n1)"
    echo "$out2" | head -n1 | grep -q ':zzz:' \
      && ok "plugin: ':zzz:' segment still shown alongside" \
      || ng "plugin: ':zzz:' segment missing: $(echo "$out2" | head -n1)"
    # And no 'Watching' section is emitted when count is zero.
    echo "$out2" | grep -qv '^Watching | size=11' \
      && ok "plugin: 'Watching' section suppressed when count is 0" \
      || ng "plugin: 'Watching' section present despite zero count"

    rm -f "$BELL_STATE_DIR/wK1" "$BELL_STATE_DIR/iD1"
  else
    skip "plugin: watching display tests"
  fi
else
  ng "fake monitor not detectable via ps (exec -a may have failed) — skipping watching tests"
  skip "watching: state-file shape"
  skip "watching: event log"
  skip "watching: repeat idle dedup"
  skip "no-monitor idle"
  skip "notifs mode watching"
  skip "plugin watching display"
fi

# Tidy up the fake monitor (cleanup trap also handles this).
kill $FAKE_MON_PID 2>/dev/null
wait $FAKE_MON_PID 2>/dev/null
# Restore the dead-PID default so subsequent sections don't accidentally
# upgrade their idle tests to watching by walking up to the real claude
# process the validator is running under.
export CCG_CLAUDE_PID=999999

# Restore to notifs default for the remaining sections.
: > "$BELL_CONFIG"

# ---------------------------------------------------------------------------
section "agents-running state (idle + live background Agent/Task/Workflow)"

# A background Agent/Task/Workflow invocation runs IN-PROCESS inside the main
# claude binary — it spawns no child OS process, so there is no PID to walk to
# the way `watching` walks to a Monitor/run_in_background marker. The only
# externally-visible liveness signal is the on-disk subagent transcript at
# ~/.claude/projects/<project>/<session_id>/subagents/agent-<hex>.jsonl, whose
# mtime advances while the subagent works and freezes once it finishes.
# CCG_PROJECTS_DIR sandboxes this to a temp dir so the validator never reads
# the real ~/.claude/projects tree.
export CCG_PROJECTS_DIR="$TMPROOT/projects"
: > "$CCG_EVENT_LOG"
rm -rf "$CCG_SESSION_STATE_DIR"
mkdir -p "$CCG_SESSION_STATE_DIR"

_touch_subagent_transcript() {
  local sid="$1" agehint="$2"
  local dir="$CCG_PROJECTS_DIR/fake-project/$sid/subagents"
  mkdir -p "$dir"
  : > "$dir/agent-fakehex$$.jsonl"
  [ -n "$agehint" ] && age_file "$agehint" "$dir/agent-fakehex$$.jsonl"
}

printf '{"mode":"always-on"}\n' > "$BELL_CONFIG"

# 1. idle + fresh subagent transcript → upgrades to agents.
ASID="agA-$$"
_touch_subagent_transcript "$ASID" ""
printf '{"session_id":"%s"}\n' "$ASID" | "$HOOKS_DIR/tab-title.sh" idle "$ASID" > /dev/null 2>&1
if sf_exists "$ASID"; then ok "agents: state file written"; else ng "agents: no state file"; fi
line1=$(sed -n '1p' "$BELL_STATE_DIR/$ASID" 2>/dev/null)
line2=$(sed -n '2p' "$BELL_STATE_DIR/$ASID" 2>/dev/null)
case "$line1" in "☕️ "*) ok "agents: state file line 1 has ☕️ prefix" ;; *) ng "agents: line 1 missing ☕️: $line1" ;; esac
[ "$line2" = "agents" ] && ok "agents: state file line 2 = 'agents'" || ng "agents: line 2 wrong (got '$line2')"

# 2. Event log records the agents transition.
last_state=$(jq -r --arg sid "$ASID" 'select(.session_id == $sid) | .state' "$CCG_EVENT_LOG" 2>/dev/null | tail -1)
[ "$last_state" = "agents" ] && ok "agents: event log state == 'agents'" || ng "agents: event log state wrong (got '$last_state')"

# 3. Repeat idle with the same fresh transcript does not duplicate the event.
events_before=$(jq -rc --arg sid "$ASID" 'select(.session_id == $sid)' "$CCG_EVENT_LOG" 2>/dev/null | wc -l | tr -d ' ')
printf '{"session_id":"%s"}\n' "$ASID" | "$HOOKS_DIR/tab-title.sh" idle "$ASID" > /dev/null 2>&1
events_after=$(jq -rc --arg sid "$ASID" 'select(.session_id == $sid)' "$CCG_EVENT_LOG" 2>/dev/null | wc -l | tr -d ' ')
[ "$events_before" = "$events_after" ] && ok "agents: repeat idle with same fresh transcript does not duplicate event" \
  || ng "agents: repeat idle re-logged (before=$events_before after=$events_after)"
rm -f "$BELL_STATE_DIR/$ASID"

# 4. Stale transcript (mtime older than CCG_AGENTS_FRESH_SEC) → plain idle,
#    not agents. Use a tiny freshness window so we don't need to sleep.
SSID="agS-$$"
_touch_subagent_transcript "$SSID" "2 minutes ago"
CCG_AGENTS_FRESH_SEC=5 bash -c "printf '{\"session_id\":\"%s\"}\n' '$SSID' | '$HOOKS_DIR/tab-title.sh' idle '$SSID'" > /dev/null 2>&1
line2=$(sed -n '2p' "$BELL_STATE_DIR/$SSID" 2>/dev/null)
[ "$line2" = "idle" ] && ok "agents: stale transcript does not upgrade (line 2 = 'idle')" \
  || ng "agents: stale transcript wrongly upgraded (got '$line2')"
rm -f "$BELL_STATE_DIR/$SSID"

# 5. Precedence: both a fresh subagent transcript AND a live monitor marker
#    present → agents wins over watching. The fake monitor is spawned as a
#    child of THIS validator process, so CCG_CLAUDE_PID must be $$ (not the
#    monitor's own PID) for _count_live_monitors to find it as a child —
#    same pattern the watching section above uses.
(exec -a "_fake-mon2 /tmp/claude-caffe-cwd live" sleep 30) &
FAKE_MON2_PID=$!
FAKE_MONITOR_PIDS="$FAKE_MONITOR_PIDS $FAKE_MON2_PID"
sleep 0.2
PSID2="agP-$$"
_touch_subagent_transcript "$PSID2" ""
CCG_CLAUDE_PID="$$" bash -c "printf '{\"session_id\":\"%s\"}\n' '$PSID2' | '$HOOKS_DIR/tab-title.sh' idle '$PSID2'" > /dev/null 2>&1
line2=$(sed -n '2p' "$BELL_STATE_DIR/$PSID2" 2>/dev/null)
[ "$line2" = "agents" ] && ok "agents: precedence over watching when both present" \
  || ng "agents: precedence wrong when both agents+watching present (got '$line2')"
rm -f "$BELL_STATE_DIR/$PSID2"
kill "$FAKE_MON2_PID" 2>/dev/null
wait "$FAKE_MON2_PID" 2>/dev/null

# 5b. Regression: a background agent finishing is ITSELF what fires
#     SubagentStop -> working for that actor. If the stray-working guard
#     mirrored the stale logical-state file back unconditionally, `agents`
#     would stick forever once the transcript goes stale, since no other
#     hook re-checks it. The guard must re-derive live state instead.
DASID="agD-$$"
_touch_subagent_transcript "$DASID" ""
printf '{"session_id":"%s"}\n' "$DASID" | "$HOOKS_DIR/tab-title.sh" idle "$DASID" > /dev/null 2>&1
[ "$(sed -n '2p' "$BELL_STATE_DIR/$DASID" 2>/dev/null)" = "agents" ] \
  && ok "stray-agents: session settled to agents" \
  || ng "stray-agents: did not settle to agents (got '$(sed -n '2p' "$BELL_STATE_DIR/$DASID" 2>/dev/null)')"
# Age the transcript past freshness — simulates the background agent finishing.
_dir="$CCG_PROJECTS_DIR/fake-project/$DASID/subagents"
age_file "2 minutes ago" "$_dir"/*.jsonl
# The finishing subagent's SubagentStop fires (working, hex agent_id, empty pending set).
CCG_AGENTS_FRESH_SEC=5 bash -c "printf '{\"session_id\":\"%s\",\"agent_id\":\"deadbeef\"}\n' '$DASID' | '$HOOKS_DIR/tab-title.sh' working" > /dev/null 2>&1
line2=$(sed -n '2p' "$BELL_STATE_DIR/$DASID" 2>/dev/null)
[ "$line2" = "idle" ] && ok "stray-agents: finishing agent's SubagentStop downgrades agents to idle (not stuck)" \
  || ng "stray-agents: agents state stuck after transcript went stale (got '$line2')"
rm -f "$BELL_STATE_DIR/$DASID"

# 5c. Regression: the finishing agent's OWN transcript is still fresh (mtime a
#     second or two old) at the exact instant its SubagentStop fires — nobody
#     artificially ages it first, unlike 5b. Without excluding the finishing
#     actor's own transcript from the re-derive count, _resolve_idle_refinement
#     would see that (very fresh) file and re-confirm `agents`, so the state
#     would never clear until the transcript aged out on some later, unrelated
#     hook (the bug reported live: "agents-running status lingers until
#     another prompt is sent"). agent_id must match the transcript's
#     "agent-<id>.jsonl" basename for the exclusion to apply.
ESID="agE-$$"
EACTOR="fakehex$$"
_touch_subagent_transcript "$ESID" ""
printf '{"session_id":"%s"}\n' "$ESID" | "$HOOKS_DIR/tab-title.sh" idle "$ESID" > /dev/null 2>&1
[ "$(sed -n '2p' "$BELL_STATE_DIR/$ESID" 2>/dev/null)" = "agents" ] \
  && ok "stray-agents-fresh: session settled to agents" \
  || ng "stray-agents-fresh: did not settle to agents (got '$(sed -n '2p' "$BELL_STATE_DIR/$ESID" 2>/dev/null)')"
# No aging here — the transcript's mtime is still fresh, exactly as it would
# be in production when SubagentStop fires within a second or two of the
# subagent's last write.
printf '{"session_id":"%s","agent_id":"%s"}\n' "$ESID" "$EACTOR" | "$HOOKS_DIR/tab-title.sh" working > /dev/null 2>&1
line2=$(sed -n '2p' "$BELL_STATE_DIR/$ESID" 2>/dev/null)
[ "$line2" = "idle" ] && ok "stray-agents-fresh: finishing agent's own fresh transcript is excluded, downgrades to idle" \
  || ng "stray-agents-fresh: agents state stuck on own fresh transcript (got '$line2')"
rm -f "$BELL_STATE_DIR/$ESID"

# 5d. Same as 5c but a SECOND subagent is still genuinely live (a different,
#     fresh transcript). The finishing actor's SubagentStop must exclude only
#     ITS OWN transcript, not every transcript — the session should stay in
#     `agents` because the sibling is still working.
FSID="agF-$$"
FACTOR="fakehex$$"
_touch_subagent_transcript "$FSID" ""
printf '{"session_id":"%s"}\n' "$FSID" | "$HOOKS_DIR/tab-title.sh" idle "$FSID" > /dev/null 2>&1
# Add a second, sibling transcript for a different actor, also fresh.
_sib_dir="$CCG_PROJECTS_DIR/fake-project/$FSID/subagents"
: > "$_sib_dir/agent-siblinghex$$.jsonl"
printf '{"session_id":"%s","agent_id":"%s"}\n' "$FSID" "$FACTOR" | "$HOOKS_DIR/tab-title.sh" working > /dev/null 2>&1
line2=$(sed -n '2p' "$BELL_STATE_DIR/$FSID" 2>/dev/null)
[ "$line2" = "agents" ] && ok "stray-agents-fresh: sibling still live keeps state at agents (only own transcript excluded)" \
  || ng "stray-agents-fresh: wrongly downgraded despite live sibling (got '$line2')"
rm -f "$BELL_STATE_DIR/$FSID"

# 6. notifs mode: agents does NOT write a state file (agents is a refinement
#    of idle, and idle is invisible in notifs mode).
: > "$BELL_CONFIG"
NASID="agN-$$"
_touch_subagent_transcript "$NASID" ""
printf '{"session_id":"%s"}\n' "$NASID" | "$HOOKS_DIR/tab-title.sh" idle "$NASID" > /dev/null 2>&1
if ! sf_exists "$NASID"; then ok "notifs mode: agents writes no state file (idle-equivalent)"
else ng "notifs mode: agents wrote a state file"; fi
last_state=$(jq -r --arg sid "$NASID" 'select(.session_id == $sid) | .state' "$CCG_EVENT_LOG" 2>/dev/null | tail -1)
[ "$last_state" = "agents" ] && ok "notifs mode: event log still records agents" || ng "notifs mode: event state wrong (got '$last_state')"

# 7. Plugin output (always-on): agents session shows up under its own
#    section, positioned between Working and Watching, with the
#    :cup.and.heat.waves.fill: emoji in the header count and sfimage=cup.and.heat.waves.fill on
#    the entry. A stale agents file (fresh transcript aged out) is downgraded
#    to idle so the dropdown reflects current reality.
if [ "$plugin" = "1" ]; then
  printf '{"mode":"always-on"}\n' > "$BELL_CONFIG"
  rm -f "$BELL_STATE_DIR"/*

  # A genuinely live watching entry needs a real monitor PID (the plugin's
  # _file_status re-verifies watching files against a live PID + marker
  # child, same as the "watching state" section above), not just a dead-PID
  # placeholder — otherwise it downgrades to idle and skews the :zzz: count.
  (exec -a "_fake-mon3 /tmp/claude-decaf-cwd live" sleep 30) &
  FAKE_MON3_PID=$!
  FAKE_MONITOR_PIDS="$FAKE_MONITOR_PIDS $FAKE_MON3_PID"
  sleep 0.2

  LASID="lAg1"
  _touch_subagent_transcript "$LASID" ""
  SASID="sAg1"
  _touch_subagent_transcript "$SASID" "2 minutes ago"

  printf '☕️ Claude Code | live-agents (lAg1)\nagents\n999999\n'   > "$BELL_STATE_DIR/$LASID"
  printf '☕️ Claude Code | stale-agents (sAg1)\nagents\n999999\n' > "$BELL_STATE_DIR/$SASID"
  printf '⏳ Claude Code | working-sess (wK2)\nworking\n'          > "$BELL_STATE_DIR/wK2"
  printf '👀 Claude Code | watch-sess (wA2)\nwatching\n%s\n' "$$"  > "$BELL_STATE_DIR/wA2"
  printf 'Claude Code | idle-sess (iD2)\nidle\n'                    > "$BELL_STATE_DIR/iD2"

  out=$(CCG_AGENTS_FRESH_SEC=60 BELL_STATE_DIR="$BELL_STATE_DIR" BELL_CONFIG="$BELL_CONFIG" \
        CCG_PROJECTS_DIR="$CCG_PROJECTS_DIR" GHOSTTY_HOOKS_DIR="$TMPROOT" bash "$PLUGIN_PATH" 2>&1)

  echo "$out" | head -n1 | grep -q ':cup.and.heat.waves.fill: 1' \
    && ok "plugin: always-on header includes ':cup.and.heat.waves.fill: 1'" \
    || ng "plugin: header missing ':cup.and.heat.waves.fill: 1': $(echo "$out" | head -n1)"

  # :zzz: count == 2 (idle-sess + downgraded stale-agents).
  echo "$out" | head -n1 | grep -q ':zzz: 2' \
    && ok "plugin: stale agents counts toward :zzz:" \
    || ng "plugin: :zzz: count wrong: $(echo "$out" | head -n1)"

  echo "$out" | grep -q '^Agents running | size=11' \
    && ok "plugin: 'Agents running' section header emitted" \
    || ng "plugin: 'Agents running' section header missing"
  echo "$out" | grep -q 'live-agents.*sfimage=cup.and.heat.waves.fill' \
    && ok "plugin: live agents entry uses sfimage=cup.and.heat.waves.fill" \
    || ng "plugin: live agents entry missing sfimage=cup.and.heat.waves.fill"
  echo "$out" | grep -q 'stale-agents.*sfimage=zzz' \
    && ok "plugin: stale agents downgrades to sfimage=zzz" \
    || ng "plugin: stale agents not downgraded: $out"

  # Section order: Working → Agents running → Watching → Idle.
  working_line=$(echo "$out" | grep -n '^Working | size=11' | head -n1 | cut -d: -f1)
  agents_line=$(echo "$out" | grep -n '^Agents running | size=11' | head -n1 | cut -d: -f1)
  watching_line=$(echo "$out" | grep -n '^Watching | size=11' | head -n1 | cut -d: -f1)
  idle_line=$(echo "$out" | grep -n '^Idle | size=11' | head -n1 | cut -d: -f1)
  if [ -n "$working_line" ] && [ -n "$agents_line" ] && [ -n "$watching_line" ] && [ -n "$idle_line" ] \
     && [ "$working_line" -lt "$agents_line" ] \
     && [ "$agents_line" -lt "$watching_line" ] \
     && [ "$watching_line" -lt "$idle_line" ]; then
    ok "plugin: section order is Working → Agents running → Watching → Idle"
  else
    ng "plugin: section order wrong (working=$working_line agents=$agents_line watching=$watching_line idle=$idle_line)"
  fi

  # Agents count zero → the :cup.and.heat.waves.fill: segment must be entirely absent.
  rm -f "$BELL_STATE_DIR/$LASID" "$BELL_STATE_DIR/$SASID"
  out2=$(CCG_AGENTS_FRESH_SEC=60 BELL_STATE_DIR="$BELL_STATE_DIR" BELL_CONFIG="$BELL_CONFIG" \
         CCG_PROJECTS_DIR="$CCG_PROJECTS_DIR" GHOSTTY_HOOKS_DIR="$TMPROOT" bash "$PLUGIN_PATH" 2>&1)
  echo "$out2" | head -n1 | grep -qv ':cup.and.heat.waves.fill:' \
    && ok "plugin: ':cup.and.heat.waves.fill:' segment hidden when agents count is 0" \
    || ng "plugin: ':cup.and.heat.waves.fill:' segment shown despite zero count: $(echo "$out2" | head -n1)"
  echo "$out2" | grep -qv '^Agents running | size=11' \
    && ok "plugin: 'Agents running' section suppressed when count is 0" \
    || ng "plugin: 'Agents running' section present despite zero count"

  rm -f "$BELL_STATE_DIR/wK2" "$BELL_STATE_DIR/wA2" "$BELL_STATE_DIR/iD2"
  kill "$FAKE_MON3_PID" 2>/dev/null
  wait "$FAKE_MON3_PID" 2>/dev/null
else
  skip "plugin: agents display tests"
fi

rm -rf "$CCG_PROJECTS_DIR"
unset CCG_PROJECTS_DIR
: > "$CCG_EVENT_LOG"
rm -rf "$CCG_SESSION_STATE_DIR"
mkdir -p "$CCG_SESSION_STATE_DIR"

# Restore to notifs default for the remaining sections.
: > "$BELL_CONFIG"

# ---------------------------------------------------------------------------
section "pending-input set (parallel subagent bell hold)"

# Regression guard for the bug where a bell raised by one actor (subagent A's
# permission prompt) was cleared seconds later by a DIFFERENT actor's
# PostToolUse(working) — subagent B grinding through tool calls under the same
# session_id. The fix keys a per-actor pending set: working only returns to
# `working` once EVERY pending actor has cleared.
#
# agent_id arrives two ways, both exercised here:
#   - input  : via arg 3 (the notify.sh path forwards agent_id as an arg)
#   - working: via stdin JSON .agent_id (the PostToolUse/SubagentStop path)
rm -rf "$CCG_PENDING_DIR"
printf '{"mode":"always-on"}\n' > "$BELL_CONFIG"
PSID="pend-$$"
_p_line2() { sed -n '2p' "$BELL_STATE_DIR/$PSID" 2>/dev/null; }
_p_count() { ls -A "$CCG_PENDING_DIR/$PSID" 2>/dev/null | wc -l | tr -d ' '; }

# A raises a permission prompt (input, agent_id via arg 3 like notify.sh).
printf '{"session_id":"%s","agent_id":"AAAA"}\n' "$PSID" | "$HOOKS_DIR/tab-title.sh" input "$PSID" AAAA >/dev/null 2>&1
[ "$(_p_line2)" = "input" ] && ok "pending: subagent A input writes bell" || ng "pending: A input wrong (got '$(_p_line2)')"
[ "$(_p_count)" = "1" ] && ok "pending: set has 1 actor after A input" || ng "pending: set count wrong after A (got $(_p_count))"

# B's PostToolUse (working, agent_id via stdin) must NOT clear A's bell.
printf '{"session_id":"%s","agent_id":"BBBB"}\n' "$PSID" | "$HOOKS_DIR/tab-title.sh" working >/dev/null 2>&1
[ "$(_p_line2)" = "input" ] && ok "pending: sibling B working HOLDS bell as input (the bug)" \
  || ng "pending: B working cleared A's bell — regression! (got '$(_p_line2)')"
[ "$(_p_count)" = "1" ] && ok "pending: B working leaves A in the set" || ng "pending: set count wrong after B (got $(_p_count))"

# Repeat B working — still held.
printf '{"session_id":"%s","agent_id":"BBBB"}\n' "$PSID" | "$HOOKS_DIR/tab-title.sh" working >/dev/null 2>&1
[ "$(_p_line2)" = "input" ] && ok "pending: repeated sibling working still holds bell" || ng "pending: repeat B cleared bell (got '$(_p_line2)')"

# A's own permission answered → A runs its tool → PostToolUse(working) for A.
# Set now empty → genuine working.
printf '{"session_id":"%s","agent_id":"AAAA"}\n' "$PSID" | "$HOOKS_DIR/tab-title.sh" working >/dev/null 2>&1
[ "$(_p_line2)" = "working" ] && ok "pending: A working with empty set → true working" || ng "pending: A working did not clear (got '$(_p_line2)')"
[ "$(_p_count)" = "0" ] && ok "pending: set empty after last actor clears" || ng "pending: set not empty (got $(_p_count))"

# Reaper: a denied subagent never fires PostToolUse, but SubagentStop is wired
# to `working`, so it removes that actor from the set. Without this the bell
# would stick forever.
printf '{"session_id":"%s","agent_id":"CCCC"}\n' "$PSID" | "$HOOKS_DIR/tab-title.sh" input "$PSID" CCCC >/dev/null 2>&1
[ "$(_p_count)" = "1" ] && ok "pending: denied actor C added on input" || ng "pending: C not added (got $(_p_count))"
printf '{"session_id":"%s","agent_id":"CCCC"}\n' "$PSID" | "$HOOKS_DIR/tab-title.sh" working >/dev/null 2>&1
[ "$(_p_count)" = "0" ] && ok "pending: SubagentStop(working) reaps denied actor C" || ng "pending: C not reaped (got $(_p_count))"

# idle clears the entire set (turn truly ended) regardless of stragglers.
printf '{"session_id":"%s","agent_id":"DDDD"}\n' "$PSID" | "$HOOKS_DIR/tab-title.sh" input "$PSID" DDDD >/dev/null 2>&1
printf '{"session_id":"%s","agent_id":"EEEE"}\n' "$PSID" | "$HOOKS_DIR/tab-title.sh" input "$PSID" EEEE >/dev/null 2>&1
[ "$(_p_count)" = "2" ] && ok "pending: two stragglers in set" || ng "pending: expected 2 (got $(_p_count))"
printf '{"session_id":"%s"}\n' "$PSID" | "$HOOKS_DIR/tab-title.sh" idle >/dev/null 2>&1
[ ! -d "$CCG_PENDING_DIR/$PSID" ] && ok "pending: idle clears the whole set" || ng "pending: idle left set behind (count=$(_p_count))"

# Main agent (no agent_id) maps to the __main__ sentinel and behaves normally.
printf '{"session_id":"%s"}\n' "$PSID" | "$HOOKS_DIR/tab-title.sh" input "$PSID" >/dev/null 2>&1
[ "$(ls -A "$CCG_PENDING_DIR/$PSID" 2>/dev/null)" = "__main__" ] && ok "pending: main agent maps to __main__ key" \
  || ng "pending: main agent key wrong (got '$(ls -A "$CCG_PENDING_DIR/$PSID" 2>/dev/null)')"
printf '{"session_id":"%s"}\n' "$PSID" | "$HOOKS_DIR/tab-title.sh" working >/dev/null 2>&1
[ "$(_p_line2)" = "working" ] && ok "pending: main agent working clears its own bell" || ng "pending: main working did not clear (got '$(_p_line2)')"

# notifs mode (production default): the held bell writes the 🔔 file, and the
# final clear removes it entirely (working is invisible in notifs mode).
: > "$BELL_CONFIG"
rm -rf "$CCG_PENDING_DIR" "$BELL_STATE_DIR/$PSID"
printf '{"session_id":"%s","agent_id":"AAAA"}\n' "$PSID" | "$HOOKS_DIR/tab-title.sh" input "$PSID" AAAA >/dev/null 2>&1
sf_exists "$PSID" && grep -qF "🔔" "$BELL_STATE_DIR/$PSID" && ok "pending(notifs): A input writes 🔔 file" || ng "pending(notifs): no 🔔 file after A input"
printf '{"session_id":"%s","agent_id":"BBBB"}\n' "$PSID" | "$HOOKS_DIR/tab-title.sh" working >/dev/null 2>&1
sf_exists "$PSID" && grep -qF "🔔" "$BELL_STATE_DIR/$PSID" && ok "pending(notifs): sibling working keeps 🔔 file" || ng "pending(notifs): 🔔 file lost on sibling working"
printf '{"session_id":"%s","agent_id":"AAAA"}\n' "$PSID" | "$HOOKS_DIR/tab-title.sh" working >/dev/null 2>&1
! sf_exists "$PSID" && ok "pending(notifs): last actor clear removes file (working hidden)" || ng "pending(notifs): file lingered after set emptied"

rm -rf "$CCG_PENDING_DIR" "$BELL_STATE_DIR/$PSID"
: > "$BELL_CONFIG"

# ---------------------------------------------------------------------------
section "AskUserQuestion bell (❓ tab-title icon, menubar unaffected)"

# notify.sh forwards kind=query as tab-title.sh's 4th arg when the
# PermissionRequest payload's tool_name is "AskUserQuestion". The tab title
# swaps to ❓; the bell-state file (what the menubar reads) must keep the
# plain 🔔 prefix regardless.
QSID="askq-$$"
rm -rf "$CCG_PENDING_DIR/$QSID" "$BELL_STATE_DIR/$QSID"
printf '{"mode":"always-on"}\n' > "$BELL_CONFIG"
export BELL_TRACE=1

trace_reset
printf '{"session_id":"%s"}\n' "$QSID" | "$HOOKS_DIR/tab-title.sh" input "$QSID" "" query >/dev/null 2>&1
grep -q 'title-set title="❓ ' "$BELL_TRACE_LOG" \
  && ok "AskUserQuestion input sets ❓ tab title" \
  || ng "AskUserQuestion input did not set ❓ title (trace: $(cat "$BELL_TRACE_LOG"))"
grep -qF "🔔" "$BELL_STATE_DIR/$QSID" \
  && ok "AskUserQuestion input still writes 🔔-prefixed bell-state file (menubar unaffected)" \
  || ng "bell-state file missing 🔔 prefix for AskUserQuestion (got: $(cat "$BELL_STATE_DIR/$QSID" 2>/dev/null))"

# notify.sh's actual call path: tab_status arg then session_id/agent_id/kind.
trace_reset
rm -rf "$CCG_PENDING_DIR/$QSID" "$BELL_STATE_DIR/$QSID"
printf '{"session_id":"%s","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Pick one"}]}}\n' "$QSID" \
  | "$HOOKS_DIR/notify.sh" '🔔' 'Needs your input' input >/dev/null 2>&1
grep -qF "🔔" "$BELL_STATE_DIR/$QSID" \
  && ok "notify.sh: AskUserQuestion still writes 🔔 bell-state file via full call path" \
  || ng "notify.sh: bell-state file missing 🔔 (got: $(cat "$BELL_STATE_DIR/$QSID" 2>/dev/null))"

# notify.sh's macOS notification title itself must also swap 🔔 -> ❓ for an
# AskUserQuestion PermissionRequest, independent of the tab-title/bell-state
# behavior above (which stays 🔔 unconditionally).
QNOTIFY_BIN="$TMPROOT/bin-askq-notify"
mkdir -p "$QNOTIFY_BIN"
QTN_ARGS_FILE="$TMPROOT/tn-args-askq.txt"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" > "%s"\n' "$QTN_ARGS_FILE" > "$QNOTIFY_BIN/terminal-notifier"
chmod +x "$QNOTIFY_BIN/terminal-notifier"
_saved_path_askq="$PATH"
export PATH="$QNOTIFY_BIN:$PATH"
rm -rf "$CCG_PENDING_DIR/$QSID" "$BELL_STATE_DIR/$QSID"
printf '{"session_id":"%s","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Pick one"}]}}\n' "$QSID" \
  | "$HOOKS_DIR/notify.sh" '🔔' 'Needs your input' input >/dev/null 2>&1
qtn=$(cat "$QTN_ARGS_FILE" 2>/dev/null)
echo "$qtn" | grep -qF -- "-title ❓ Claude Code" \
  && ok "notify.sh: AskUserQuestion swaps notification icon to ❓" \
  || ng "notify.sh: AskUserQuestion notification icon not swapped to ❓ (got: $qtn)"
export PATH="$_saved_path_askq"

# A plain (non-AskUserQuestion) permission request must still show the
# ordinary 🔔 tab title, not ❓.
PLSID="plainq-$$"
rm -rf "$CCG_PENDING_DIR/$PLSID" "$BELL_STATE_DIR/$PLSID"
trace_reset
printf '{"session_id":"%s"}\n' "$PLSID" | "$HOOKS_DIR/tab-title.sh" input "$PLSID" >/dev/null 2>&1
grep -q 'title-set title="🔔 ' "$BELL_TRACE_LOG" \
  && ok "plain permission request keeps 🔔 tab title (no kind arg)" \
  || ng "plain permission request wrongly got a different title (trace: $(cat "$BELL_TRACE_LOG"))"
grep -q 'title-set title="❓ ' "$BELL_TRACE_LOG" \
  && ng "plain permission request incorrectly showed ❓" \
  || ok "plain permission request does not show ❓"

# A plain permission request must also keep the ordinary 🔔 notification icon.
export PATH="$QNOTIFY_BIN:$PATH"
: > "$QTN_ARGS_FILE"
printf '{"session_id":"%s"}\n' "$PLSID" \
  | "$HOOKS_DIR/notify.sh" '🔔' 'Needs your input' input >/dev/null 2>&1
qtn2=$(cat "$QTN_ARGS_FILE" 2>/dev/null)
echo "$qtn2" | grep -qF -- "-title 🔔 Claude Code" \
  && ok "notify.sh: plain permission request keeps 🔔 notification icon" \
  || ng "notify.sh: plain permission request icon wrongly changed (got: $qtn2)"
export PATH="$_saved_path_askq"

# Mixed pending set: a sibling's plain permission prompt must not mask an
# AskUserQuestion bell raised by a different actor in the same session.
MQSID="mixq-$$"
rm -rf "$CCG_PENDING_DIR/$MQSID" "$BELL_STATE_DIR/$MQSID"
printf '{"session_id":"%s","agent_id":"PLAIN"}\n' "$MQSID" | "$HOOKS_DIR/tab-title.sh" input "$MQSID" PLAIN >/dev/null 2>&1
trace_reset
printf '{"session_id":"%s","agent_id":"QUERY"}\n' "$MQSID" | "$HOOKS_DIR/tab-title.sh" input "$MQSID" QUERY query >/dev/null 2>&1
grep -q 'title-set title="❓ ' "$BELL_TRACE_LOG" \
  && ok "mixed pending set: query actor's bell shows ❓ even with a plain sibling pending" \
  || ng "mixed pending set: ❓ not shown (trace: $(cat "$BELL_TRACE_LOG"))"

# Once the query actor's bell clears (its permission answered → working) but
# the plain sibling is still pending, the title reverts to plain 🔔.
trace_reset
printf '{"session_id":"%s","agent_id":"QUERY"}\n' "$MQSID" | "$HOOKS_DIR/tab-title.sh" working >/dev/null 2>&1
grep -q 'title-set title="🔔 ' "$BELL_TRACE_LOG" \
  && ok "after query actor clears, remaining plain sibling shows 🔔 (not ❓)" \
  || ng "title did not revert to 🔔 after query actor cleared (trace: $(cat "$BELL_TRACE_LOG"))"

rm -rf "$CCG_PENDING_DIR/$QSID" "$CCG_PENDING_DIR/$PLSID" "$CCG_PENDING_DIR/$MQSID" \
       "$BELL_STATE_DIR/$QSID" "$BELL_STATE_DIR/$PLSID" "$BELL_STATE_DIR/$MQSID"
: > "$BELL_CONFIG"
unset BELL_TRACE

# ---------------------------------------------------------------------------
section "stray working after turn settled (subagent and main-after-end)"

# Regression guard for the stuck-working bug. Two variants:
#
# (A) Stray-late-SubagentStop: SubagentStop is wired to `working`, but a
#     subagent's terminal event can land a second or two AFTER the main agent's
#     Stop settled the session to idle, with no pending bell to clear. That lone
#     subagent `working` used to overwrite idle and stick forever.
#
# (B) Stray-main-after-end: a Stop/StopFailure hook fires AFTER SessionEnd
#     already removed the logical-state file. The actor is __main__, so the old
#     subagent-only guard missed it (observed: end at T, __main__ working at
#     T+0.66s, no-PID bell-state file, frozen ⏳ until the stale cap).
#
# The guard now covers all actors: if pending is empty and logical state is
# settled (idle/watching) or absent (file removed by end), suppress the working.
printf '{"mode":"always-on"}\n' > "$BELL_CONFIG"
SLSID="strayss-$$"
rm -rf "$CCG_PENDING_DIR/$SLSID" "$BELL_STATE_DIR/$SLSID" "$CCG_SESSION_STATE_DIR/$SLSID"

# --- Variant A: subagent working after idle ---
# Turn ends: main agent Stop → idle. Logical state is now idle.
printf '{"session_id":"%s"}\n' "$SLSID" | "$HOOKS_DIR/tab-title.sh" idle "$SLSID" >/dev/null 2>&1
[ "$(sed -n '2p' "$BELL_STATE_DIR/$SLSID" 2>/dev/null)" = "idle" ] \
  && ok "stray-ss: session settled to idle" || ng "stray-ss: did not settle to idle (got '$(sed -n '2p' "$BELL_STATE_DIR/$SLSID" 2>/dev/null)')"

# A subagent's SubagentStop arrives 2s late (working, hex agent_id, empty set).
# Must NOT resurrect working — state file stays idle.
printf '{"session_id":"%s","agent_id":"f00d"}\n' "$SLSID" | "$HOOKS_DIR/tab-title.sh" working >/dev/null 2>&1
[ "$(sed -n '2p' "$BELL_STATE_DIR/$SLSID" 2>/dev/null)" = "idle" ] \
  && ok "stray-ss: late subagent working does NOT resurrect working (variant A)" \
  || ng "stray-ss: late subagent working stuck the session — regression! (got '$(sed -n '2p' "$BELL_STATE_DIR/$SLSID" 2>/dev/null)')"

# And it must not have appended a spurious working transition to the event log.
[ "$(grep -c "\"session_id\":\"$SLSID\".*\"state\":\"working\"" "$CCG_EVENT_LOG" 2>/dev/null)" = "0" ] \
  && ok "stray-ss: no spurious working event logged" \
  || ng "stray-ss: spurious working event logged"

# --- Variant B: __main__ working after end (logical-state file deleted) ---
# SessionEnd fires → end removes the logical-state file.
printf '{"session_id":"%s"}\n' "$SLSID" | "$HOOKS_DIR/tab-title.sh" end "$SLSID" >/dev/null 2>&1
[ ! -f "$CCG_SESSION_STATE_DIR/$SLSID" ] \
  && ok "stray-ss: end removed logical-state file" \
  || ng "stray-ss: end did not remove logical-state file"

# A Stop/StopFailure hook fires 0.66s later as __main__ (no agent_id in payload).
# Must NOT resurrect working even though actor=__main__. The distinguisher is the
# absent logical-state file: in real sessions SessionStart idle always precedes
# working, so absent means post-end. At this point end already deleted the file.
printf '{"session_id":"%s"}\n' "$SLSID" | "$HOOKS_DIR/tab-title.sh" working >/dev/null 2>&1
[ "$(sed -n '2p' "$BELL_STATE_DIR/$SLSID" 2>/dev/null)" != "working" ] \
  && ok "stray-ss: __main__ working after end does NOT resurrect working (variant B)" \
  || ng "stray-ss: __main__ working after end stuck the session — regression! (got '$(sed -n '2p' "$BELL_STATE_DIR/$SLSID" 2>/dev/null)')"

# The main agent's legitimate start-of-turn working (actor=__main__, fired right
# after the SessionStart idle) MUST still pass through. Simulate: idle writes
# the logical-state file, then __main__ working arrives — must land as working.
printf '{"session_id":"%s"}\n' "$SLSID" | "$HOOKS_DIR/tab-title.sh" idle "$SLSID" >/dev/null 2>&1
printf '{"session_id":"%s"}\n' "$SLSID" | "$HOOKS_DIR/tab-title.sh" working "$SLSID" >/dev/null 2>&1
[ "$(sed -n '2p' "$BELL_STATE_DIR/$SLSID" 2>/dev/null)" = "working" ] \
  && ok "stray-ss: main agent working from idle still passes through (not over-suppressed)" \
  || ng "stray-ss: main agent working wrongly suppressed (got '$(sed -n '2p' "$BELL_STATE_DIR/$SLSID" 2>/dev/null)')"

# During an active turn (logical=working), a real subagent working is genuine
# work and must pass through unchanged.
printf '{"session_id":"%s","agent_id":"beef"}\n' "$SLSID" | "$HOOKS_DIR/tab-title.sh" working >/dev/null 2>&1
[ "$(sed -n '2p' "$BELL_STATE_DIR/$SLSID" 2>/dev/null)" = "working" ] \
  && ok "stray-ss: subagent working during active turn passes through" \
  || ng "stray-ss: subagent working wrongly suppressed mid-turn (got '$(sed -n '2p' "$BELL_STATE_DIR/$SLSID" 2>/dev/null)')"

rm -rf "$CCG_PENDING_DIR/$SLSID" "$BELL_STATE_DIR/$SLSID" "$CCG_SESSION_STATE_DIR/$SLSID"
: > "$BELL_CONFIG"

# ---------------------------------------------------------------------------
section "pre-bell state restore (bell must not clobber non-working idle-family state)"

# Regression guard: answering a bell used to always drop the tab into
# `working`, even when the state right before the bell fired was `agents` or
# `watching` — e.g. a backgrounded subagent raising its OWN permission prompt
# while the main session was sitting at `agents`. Once that prompt clears, the
# correct tab state is whatever was in force before the bell (re-derived
# live), not a blanket `working`.
printf '{"mode":"always-on"}\n' > "$BELL_CONFIG"
# CCG_PROJECTS_DIR was unset after the "agents-running state" section above;
# re-export it (same path, and _touch_subagent_transcript is still in scope)
# so this section's agents-restore case can create fresh transcripts again.
export CCG_PROJECTS_DIR="$TMPROOT/projects"

# --- agents -> bell -> agents (not working) ---
PBASID="pbA-$$"
rm -rf "$CCG_PENDING_DIR/$PBASID" "$BELL_STATE_DIR/$PBASID" "$CCG_SESSION_STATE_DIR/$PBASID"
_touch_subagent_transcript "$PBASID" ""
printf '{"session_id":"%s"}\n' "$PBASID" | "$HOOKS_DIR/tab-title.sh" idle "$PBASID" >/dev/null 2>&1
[ "$(sed -n '2p' "$BELL_STATE_DIR/$PBASID" 2>/dev/null)" = "agents" ] \
  && ok "prebell: session settled to agents before bell" \
  || ng "prebell: did not settle to agents (got '$(sed -n '2p' "$BELL_STATE_DIR/$PBASID" 2>/dev/null)')"
# A subagent (its own, still-live transcript) raises a permission prompt.
printf '{"session_id":"%s","agent_id":"fakehex%s"}\n' "$PBASID" "$$" | "$HOOKS_DIR/tab-title.sh" input "$PBASID" "fakehex$$" >/dev/null 2>&1
[ "$(sed -n '2p' "$BELL_STATE_DIR/$PBASID" 2>/dev/null)" = "input" ] \
  && ok "prebell: subagent bell shows input" || ng "prebell: bell did not show input"
# Permission granted -> PostToolUse(working) for the same actor. The
# transcript is still fresh (the subagent kept working), so the restore
# should land back on agents, not working.
printf '{"session_id":"%s","agent_id":"fakehex%s"}\n' "$PBASID" "$$" | "$HOOKS_DIR/tab-title.sh" working >/dev/null 2>&1
line2=$(sed -n '2p' "$BELL_STATE_DIR/$PBASID" 2>/dev/null)
[ "$line2" = "agents" ] && ok "prebell: bell resolved restores agents (not working)" \
  || ng "prebell: bell resolved wrongly landed on '$line2' instead of agents"
rm -rf "$CCG_PENDING_DIR/$PBASID" "$BELL_STATE_DIR/$PBASID" "$CCG_SESSION_STATE_DIR/$PBASID"

# --- watching -> bell -> watching (not working) ---
(exec -a "_fake-mon4 /tmp/claude-decade-cwd live" sleep 30) &
FAKE_MON4_PID=$!
FAKE_MONITOR_PIDS="$FAKE_MONITOR_PIDS $FAKE_MON4_PID"
sleep 0.2
PBWSID="pbW-$$"
rm -rf "$CCG_PENDING_DIR/$PBWSID" "$BELL_STATE_DIR/$PBWSID" "$CCG_SESSION_STATE_DIR/$PBWSID"
CCG_CLAUDE_PID="$$" bash -c "printf '{\"session_id\":\"%s\"}\n' '$PBWSID' | '$HOOKS_DIR/tab-title.sh' idle '$PBWSID'" >/dev/null 2>&1
[ "$(sed -n '2p' "$BELL_STATE_DIR/$PBWSID" 2>/dev/null)" = "watching" ] \
  && ok "prebell: session settled to watching before bell" \
  || ng "prebell: did not settle to watching (got '$(sed -n '2p' "$BELL_STATE_DIR/$PBWSID" 2>/dev/null)')"
printf '{"session_id":"%s"}\n' "$PBWSID" | "$HOOKS_DIR/tab-title.sh" input "$PBWSID" >/dev/null 2>&1
[ "$(sed -n '2p' "$BELL_STATE_DIR/$PBWSID" 2>/dev/null)" = "input" ] \
  && ok "prebell: main-agent bell shows input over watching" || ng "prebell: bell did not show input"
CCG_CLAUDE_PID="$$" bash -c "printf '{\"session_id\":\"%s\"}\n' '$PBWSID' | '$HOOKS_DIR/tab-title.sh' working" >/dev/null 2>&1
line2=$(sed -n '2p' "$BELL_STATE_DIR/$PBWSID" 2>/dev/null)
[ "$line2" = "watching" ] && ok "prebell: bell resolved restores watching (not working, monitor still live)" \
  || ng "prebell: bell resolved wrongly landed on '$line2' instead of watching"
rm -rf "$CCG_PENDING_DIR/$PBWSID" "$BELL_STATE_DIR/$PBWSID" "$CCG_SESSION_STATE_DIR/$PBWSID"
kill "$FAKE_MON4_PID" 2>/dev/null
wait "$FAKE_MON4_PID" 2>/dev/null

# --- genuine mid-turn bell: working -> bell -> working (baseline unaffected) ---
PBMSID="pbM-$$"
rm -rf "$CCG_PENDING_DIR/$PBMSID" "$BELL_STATE_DIR/$PBMSID" "$CCG_SESSION_STATE_DIR/$PBMSID"
# Establish a real logical `idle` first (SessionStart), THEN working — a bare
# working on a session with no prior logical state hits the stray-main-after-
# end guard (see "stray working after turn settled" section) and gets
# suppressed to idle, which isn't what this baseline is testing.
printf '{"session_id":"%s"}\n' "$PBMSID" | "$HOOKS_DIR/tab-title.sh" idle "$PBMSID" >/dev/null 2>&1
printf '{"session_id":"%s"}\n' "$PBMSID" | "$HOOKS_DIR/tab-title.sh" working "$PBMSID" >/dev/null 2>&1
[ "$(sed -n '2p' "$BELL_STATE_DIR/$PBMSID" 2>/dev/null)" = "working" ] \
  && ok "prebell: session mid-turn working before bell" || ng "prebell: did not settle to working"
printf '{"session_id":"%s"}\n' "$PBMSID" | "$HOOKS_DIR/tab-title.sh" input "$PBMSID" >/dev/null 2>&1
printf '{"session_id":"%s"}\n' "$PBMSID" | "$HOOKS_DIR/tab-title.sh" working >/dev/null 2>&1
[ "$(sed -n '2p' "$BELL_STATE_DIR/$PBMSID" 2>/dev/null)" = "working" ] \
  && ok "prebell: mid-turn bell still restores working (baseline unaffected)" \
  || ng "prebell: mid-turn bell restore regressed (got '$(sed -n '2p' "$BELL_STATE_DIR/$PBMSID" 2>/dev/null)')"
rm -rf "$CCG_PENDING_DIR/$PBMSID" "$BELL_STATE_DIR/$PBMSID" "$CCG_SESSION_STATE_DIR/$PBMSID"

# --- batch of bells: only the FIRST bell's snapshot wins ---
PBBSID="pbB-$$"
rm -rf "$CCG_PENDING_DIR/$PBBSID" "$BELL_STATE_DIR/$PBBSID" "$CCG_SESSION_STATE_DIR/$PBBSID"
_touch_subagent_transcript "$PBBSID" ""
printf '{"session_id":"%s"}\n' "$PBBSID" | "$HOOKS_DIR/tab-title.sh" idle "$PBBSID" >/dev/null 2>&1
[ "$(sed -n '2p' "$BELL_STATE_DIR/$PBBSID" 2>/dev/null)" = "agents" ] \
  && ok "prebell(batch): session settled to agents before batch" \
  || ng "prebell(batch): did not settle to agents"
# First bell (subagent A) snapshots "agents".
printf '{"session_id":"%s","agent_id":"AAAA"}\n' "$PBBSID" | "$HOOKS_DIR/tab-title.sh" input "$PBBSID" AAAA >/dev/null 2>&1
[ "$(cat "$CCG_PENDING_DIR/${PBBSID}.prebell" 2>/dev/null)" = "agents" ] \
  && ok "prebell(batch): first bell snapshots agents" \
  || ng "prebell(batch): snapshot missing/wrong (got '$(cat "$CCG_PENDING_DIR/${PBBSID}.prebell" 2>/dev/null)')"
# A second, sibling bell fires while A is still pending. The main logical
# state is now "input" (from A's bell) — the snapshot must NOT be overwritten
# with "input".
printf '{"session_id":"%s","agent_id":"BBBB"}\n' "$PBBSID" | "$HOOKS_DIR/tab-title.sh" input "$PBBSID" BBBB >/dev/null 2>&1
[ "$(cat "$CCG_PENDING_DIR/${PBBSID}.prebell" 2>/dev/null)" = "agents" ] \
  && ok "prebell(batch): second concurrent bell does not overwrite the snapshot" \
  || ng "prebell(batch): snapshot clobbered by second bell (got '$(cat "$CCG_PENDING_DIR/${PBBSID}.prebell" 2>/dev/null)')"
# A clears, B still pending -> held as input.
printf '{"session_id":"%s","agent_id":"AAAA"}\n' "$PBBSID" | "$HOOKS_DIR/tab-title.sh" working >/dev/null 2>&1
[ "$(sed -n '2p' "$BELL_STATE_DIR/$PBBSID" 2>/dev/null)" = "input" ] \
  && ok "prebell(batch): bell held while sibling still pending" \
  || ng "prebell(batch): bell cleared early (got '$(sed -n '2p' "$BELL_STATE_DIR/$PBBSID" 2>/dev/null)')"
# B clears too -> set empty -> restore the snapshotted agents state.
printf '{"session_id":"%s","agent_id":"BBBB"}\n' "$PBBSID" | "$HOOKS_DIR/tab-title.sh" working >/dev/null 2>&1
line2=$(sed -n '2p' "$BELL_STATE_DIR/$PBBSID" 2>/dev/null)
[ "$line2" = "agents" ] && ok "prebell(batch): last bell clears and restores agents" \
  || ng "prebell(batch): restore wrong after batch cleared (got '$line2')"
[ ! -f "$CCG_PENDING_DIR/${PBBSID}.prebell" ] \
  && ok "prebell(batch): snapshot file consumed after restore" \
  || ng "prebell(batch): snapshot file leaked after restore"
rm -rf "$CCG_PENDING_DIR/$PBBSID" "$BELL_STATE_DIR/$PBBSID" "$CCG_SESSION_STATE_DIR/$PBBSID"

# --- prebell snapshot is cleared on idle/end ---
PBCSID="pbC-$$"
rm -rf "$CCG_PENDING_DIR/$PBCSID" "$BELL_STATE_DIR/$PBCSID" "$CCG_SESSION_STATE_DIR/$PBCSID"
printf '{"session_id":"%s"}\n' "$PBCSID" | "$HOOKS_DIR/tab-title.sh" working "$PBCSID" >/dev/null 2>&1
printf '{"session_id":"%s"}\n' "$PBCSID" | "$HOOKS_DIR/tab-title.sh" input "$PBCSID" >/dev/null 2>&1
[ -f "$CCG_PENDING_DIR/${PBCSID}.prebell" ] \
  && ok "prebell: snapshot exists while bell pending" || ng "prebell: snapshot missing while bell pending"
printf '{"session_id":"%s"}\n' "$PBCSID" | "$HOOKS_DIR/tab-title.sh" idle "$PBCSID" >/dev/null 2>&1
[ ! -f "$CCG_PENDING_DIR/${PBCSID}.prebell" ] \
  && ok "prebell: idle clears a leftover snapshot" || ng "prebell: snapshot leaked past idle"
rm -rf "$CCG_PENDING_DIR/$PBCSID" "$BELL_STATE_DIR/$PBCSID" "$CCG_SESSION_STATE_DIR/$PBCSID"

: > "$BELL_CONFIG"

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

# working writes state file in always-on mode (precede with idle as in real sessions)
echo "{\"session_id\":\"${SID_AO}w\"}" | "$HOOKS_DIR/tab-title.sh" idle    > /dev/null 2>&1
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
section "notify.sh error mode (StopFailure)"

# Stub terminal-notifier so no real notification fires; capture its argv.
NOTIFY_BIN="$TMPROOT/bin"
mkdir -p "$NOTIFY_BIN"
TN_ARGS_FILE="$TMPROOT/tn-args.txt"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" > "%s"\n' "$TN_ARGS_FILE" > "$NOTIFY_BIN/terminal-notifier"
chmod +x "$NOTIFY_BIN/terminal-notifier"
_saved_path="$PATH"
export PATH="$NOTIFY_BIN:$PATH"
export CCG_DIR="$TMPROOT/ccg-err"

# (a) error mode extracts the latest API-error text from the transcript,
#     writes a readable log, surfaces the error as the message, and appends
#     `open -t <log>` to the execute command.
ERR_SID="errSID"
ERR_TRANSCRIPT="$TMPROOT/err-transcript.jsonl"
printf '%s\n' '{"type":"assistant","isApiErrorMessage":false,"message":{"content":[{"type":"text","text":"normal turn"}]}}' > "$ERR_TRANSCRIPT"
printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"API Error: 429 throttled"}]}}' >> "$ERR_TRANSCRIPT"
: > "$TN_ARGS_FILE"
echo "{\"session_id\":\"$ERR_SID\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"$ERR_TRANSCRIPT\"}" \
  | "$HOOKS_DIR/notify.sh" '❌' 'Claude stopped: API error' '' error > /dev/null 2>&1
ERR_LOG="$CCG_DIR/last-error-$ERR_SID.log"
tn=$(cat "$TN_ARGS_FILE" 2>/dev/null)

[ -f "$ERR_LOG" ] && ok "error mode writes readable log file" || ng "error log not written ($ERR_LOG)"
grep -qF "API Error: 429 throttled" "$ERR_LOG" 2>/dev/null \
  && ok "error log contains extracted API-error text" || ng "error log missing API-error text"
echo "$tn" | grep -qF -- "-message API Error: 429 throttled" \
  && ok "notification message is the extracted error" || ng "message not set to extracted error (got: $tn)"
echo "$tn" | grep -qF "open -t '$ERR_LOG'" \
  && ok "execute focuses tab AND opens the error log" || ng "execute missing 'open -t <log>' (got: $tn)"

# (a') the always-on debug log captures the invocation regardless of BELL_TRACE.
[ -f "$CCG_DIR/notify-debug.log" ] && grep -q "match_key=" "$CCG_DIR/notify-debug.log" \
  && ok "notify-debug.log records invocation (no BELL_TRACE needed)" \
  || ng "notify-debug.log not written or missing match_key line"

# (a'') subtitle dir basenames CLAUDE_PROJECT_DIR (project root), not the live
#       payload .cwd. Mirrors the tab-title.sh fix: a session that cd'd into a
#       subdir must still show its project name. match_key is built from the
#       summary/short_id, never dir_name, so tab focus is unaffected.
: > "$TN_ARGS_FILE"
PD_NOTIFY_ROOT="$TMPROOT/notify-proj-root"
echo "{\"session_id\":\"pdNotify\",\"cwd\":\"/tmp/some/deep-subdir\"}" \
  | CLAUDE_PROJECT_DIR="$PD_NOTIFY_ROOT" "$HOOKS_DIR/notify.sh" '🔔' 'Claude needs input' '' '' > /dev/null 2>&1
tn_pd=$(cat "$TN_ARGS_FILE" 2>/dev/null)
echo "$tn_pd" | grep -qF "notify-proj-root" \
  && ok "notification subtitle pins to CLAUDE_PROJECT_DIR basename" \
  || ng "subtitle missing project basename (got: $tn_pd)"
echo "$tn_pd" | grep -qF "deep-subdir" \
  && ng "subtitle leaked live cwd basename (got: $tn_pd)" \
  || ok "notification subtitle does not use live cwd basename"

# (b) no transcript → fall back to default message, write no log, no open -t.
: > "$TN_ARGS_FILE"
echo "{\"session_id\":\"noTrans\",\"cwd\":\"/tmp/proj\"}" \
  | "$HOOKS_DIR/notify.sh" '❌' 'Claude stopped: API error' '' error > /dev/null 2>&1
tn2=$(cat "$TN_ARGS_FILE" 2>/dev/null)
echo "$tn2" | grep -qF -- "-message Claude stopped: API error" \
  && ok "no transcript => falls back to default message" || ng "fallback message wrong (got: $tn2)"
echo "$tn2" | grep -q "open -t" \
  && ng "fallback appended 'open -t' with no log" || ok "no log => execute does not open anything"
[ -f "$CCG_DIR/last-error-noTrans.log" ] \
  && ng "wrote a log file with no error text" || ok "no error text => no log file written"

# (c) transcript_path ABSENT from payload but derivable from cwd + session_id.
#     This is the real StopFailure case: the hook JSON carries no
#     transcript_path, so notify.sh must reconstruct the deterministic path
#     ~/.claude/projects/<cwd-with-/-as-->/<sid>.jsonl. Sandbox HOME so the
#     derived path lands in our temp tree, not the real ~/.claude.
DERIVE_HOME="$TMPROOT/derive-home"
DERIVE_CWD="/tmp/derive proj"   # space in path → also guards the mangle/quoting
DERIVE_SID="derivedSID"
mangled=$(printf '%s' "$DERIVE_CWD" | sed 's#/#-#g')
mkdir -p "$DERIVE_HOME/.claude/projects/$mangled"
DERIVE_TRANSCRIPT="$DERIVE_HOME/.claude/projects/$mangled/$DERIVE_SID.jsonl"
printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"API Error: 529 overloaded"}]}}' > "$DERIVE_TRANSCRIPT"
: > "$TN_ARGS_FILE"
HOME="$DERIVE_HOME" CCG_DIR="$DERIVE_HOME/.claude/.ccg" \
  bash -c "echo '{\"session_id\":\"$DERIVE_SID\",\"cwd\":\"$DERIVE_CWD\"}' | '$HOOKS_DIR/notify.sh' '❌' 'Claude stopped: API error' '' error" > /dev/null 2>&1
tn3=$(cat "$TN_ARGS_FILE" 2>/dev/null)
echo "$tn3" | grep -qF -- "-message API Error: 529 overloaded" \
  && ok "missing transcript_path => derived from cwd+session_id" \
  || ng "derivation fallback failed (got: $tn3)"
[ -f "$DERIVE_HOME/.claude/.ccg/last-error-$DERIVE_SID.log" ] \
  && ok "derived transcript still writes error log" \
  || ng "derived transcript did not write error log"

# (d) flush race: StopFailure runs notify.sh concurrently with Claude Code
#     writing the API-error entry, so a single read misses it. notify.sh must
#     poll. Start with no error entry, append it ~0.4s in, and confirm the
#     poll picks it up rather than falling back to the generic message.
RACE_SID="raceSID"
RACE_TRANSCRIPT="$TMPROOT/race-transcript.jsonl"
printf '%s\n' '{"type":"assistant","isApiErrorMessage":false,"message":{"content":[{"type":"text","text":"pre-error turn"}]}}' > "$RACE_TRANSCRIPT"
( sleep 0.4; printf '%s\n' '{"type":"assistant","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"API Error: 503 flushed late"}]}}' >> "$RACE_TRANSCRIPT" ) &
RACE_WPID=$!
: > "$TN_ARGS_FILE"
echo "{\"session_id\":\"$RACE_SID\",\"cwd\":\"/tmp/proj\",\"transcript_path\":\"$RACE_TRANSCRIPT\"}" \
  | "$HOOKS_DIR/notify.sh" '❌' 'Claude stopped: API error' '' error > /dev/null 2>&1
wait "$RACE_WPID" 2>/dev/null
tn4=$(cat "$TN_ARGS_FILE" 2>/dev/null)
echo "$tn4" | grep -qF -- "-message API Error: 503 flushed late" \
  && ok "flush race: poll picks up late-written error entry" \
  || ng "flush race: did not pick up late error (got: $tn4)"

export PATH="$_saved_path"
unset CCG_DIR

# ---------------------------------------------------------------------------
section "notify.sh agents-gate (suppress premature 'Task completed' notification)"

# Stub terminal-notifier again for this section's own checks.
NOTIFY_BIN2="$TMPROOT/bin-agents-gate"
mkdir -p "$NOTIFY_BIN2"
TN_ARGS_FILE2="$TMPROOT/tn-args-agents.txt"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" > "%s"\n' "$TN_ARGS_FILE2" > "$NOTIFY_BIN2/terminal-notifier"
chmod +x "$NOTIFY_BIN2/terminal-notifier"
_saved_path2="$PATH"
export PATH="$NOTIFY_BIN2:$PATH"
export CCG_PROJECTS_DIR="$TMPROOT/agents-gate-projects"
mkdir -p "$CCG_PROJECTS_DIR"

# (a) a live (fresh) subagent transcript for this session -> notification is
#     suppressed entirely; this is the Stop-hook "Task completed" call site's
#     whole point (the main turn paused but a background agent is still
#     working, so the fleet isn't actually done).
AG_SID="agentsGateLive"
mkdir -p "$CCG_PROJECTS_DIR/fake-project/$AG_SID/subagents"
: > "$CCG_PROJECTS_DIR/fake-project/$AG_SID/subagents/agent-livehex.jsonl"
: > "$TN_ARGS_FILE2"
echo "{\"session_id\":\"$AG_SID\"}" | "$HOOKS_DIR/notify.sh" '✅' 'Task completed' '' '' agents > /dev/null 2>&1
[ ! -s "$TN_ARGS_FILE2" ] && ok "gate=agents: live subagent transcript suppresses notification" \
  || ng "gate=agents: notification fired despite live transcript (got: $(cat "$TN_ARGS_FILE2" 2>/dev/null))"

# (b) a stale transcript (past CCG_AGENTS_FRESH_SEC) -> notification passes
#     through normally; the background agent has actually finished.
AG_SID2="agentsGateStale"
mkdir -p "$CCG_PROJECTS_DIR/fake-project/$AG_SID2/subagents"
: > "$CCG_PROJECTS_DIR/fake-project/$AG_SID2/subagents/agent-stalehex.jsonl"
age_file "5 minutes ago" "$CCG_PROJECTS_DIR/fake-project/$AG_SID2/subagents/agent-stalehex.jsonl"
: > "$TN_ARGS_FILE2"
CCG_AGENTS_FRESH_SEC=5 bash -c "echo '{\"session_id\":\"$AG_SID2\"}' | '$HOOKS_DIR/notify.sh' '✅' 'Task completed' '' '' agents" > /dev/null 2>&1
grep -qF -- "-message Task completed" "$TN_ARGS_FILE2" 2>/dev/null \
  && ok "gate=agents: stale transcript lets notification through" \
  || ng "gate=agents: notification wrongly suppressed with stale transcript (got: $(cat "$TN_ARGS_FILE2" 2>/dev/null))"

# (c) no subagent transcript at all -> notification passes through normally.
AG_SID3="agentsGateNone"
: > "$TN_ARGS_FILE2"
echo "{\"session_id\":\"$AG_SID3\"}" | "$HOOKS_DIR/notify.sh" '✅' 'Task completed' '' '' agents > /dev/null 2>&1
grep -qF -- "-message Task completed" "$TN_ARGS_FILE2" 2>/dev/null \
  && ok "gate=agents: no subagent transcript lets notification through" \
  || ng "gate=agents: notification wrongly suppressed with no transcript (got: $(cat "$TN_ARGS_FILE2" 2>/dev/null))"

# (d) a call site that does NOT pass gate=agents (e.g. PermissionRequest) must
#     never suppress, even with a live transcript present — only the Stop
#     hook's "Task completed" call site opts into the gate.
AG_SID4="agentsGateUngated"
mkdir -p "$CCG_PROJECTS_DIR/fake-project/$AG_SID4/subagents"
: > "$CCG_PROJECTS_DIR/fake-project/$AG_SID4/subagents/agent-ungatedhex.jsonl"
: > "$TN_ARGS_FILE2"
echo "{\"session_id\":\"$AG_SID4\"}" | "$HOOKS_DIR/notify.sh" '🔔' 'Needs your input' input > /dev/null 2>&1
grep -qF -- "-message Needs your input" "$TN_ARGS_FILE2" 2>/dev/null \
  && ok "no gate arg: notification fires even with live transcript (ungated call site)" \
  || ng "no gate arg: notification wrongly suppressed (got: $(cat "$TN_ARGS_FILE2" 2>/dev/null))"

rm -rf "$CCG_PROJECTS_DIR"; unset CCG_PROJECTS_DIR
rm -rf "$BELL_STATE_DIR/$AG_SID4" "$CCG_SESSION_STATE_DIR/$AG_SID4" "$CCG_PENDING_DIR/$AG_SID4"
export PATH="$_saved_path2"

# ---------------------------------------------------------------------------
section "dashboard verdict logic"

# The verdict banner names the single highest-leverage action from the live
# levers. Its branch selection (verdictFor) is pure and lives in dashboard.html
# between the <verdictFor> markers; slice it out and exercise every branch +
# precedence boundary under Node so a regression in the advice can't slip past.
if command -v node >/dev/null 2>&1 && [ -f "$DASHBOARD_PATH" ]; then
  VERDICT_FN=$(awk '/\/\/ <verdictFor>/{f=1;next} /\/\/ <\/verdictFor>/{f=0} f' "$DASHBOARD_PATH")
  if [ -z "$VERDICT_FN" ]; then
    ng "could not extract verdictFor from $DASHBOARD_PATH (markers missing?)"
  else
    VERDICT_JS="$TMPROOT/verdict.js"
    {
      printf '%s\n' "$VERDICT_FN"
      cat <<'NODE'
const cases = [
  // [stall, conc, workingSecs, expectedKind]
  [null, null,  0,    'gated-quiet'],     // no signal at all
  [null, 0.10,  3600, 'gated-fanout'],    // gated but low conc + real work → nudge fan-out
  [null, 0.10,  600,  'gated-quiet'],     // gated, low conc, but barely any work → stay quiet
  [null, 0.50,  3600, 'gated-quiet'],     // gated, conc healthy → quiet
  [0.80, 0.90,  3600, 'stall-critical'],  // high stall dominates even with great conc
  [0.50, 0.90,  3600, 'stall-critical'],  // boundary: 0.5 is critical
  [0.49, 0.90,  3600, 'stall-high'],      // just below critical
  [0.25, 0.90,  3600, 'stall-high'],      // boundary: 0.25 is high
  [0.24, 0.10,  3600, 'fanout'],          // stall healthy, conc low → fan out
  [0.10, 0.29,  3600, 'fanout'],          // boundary: 0.29 still fan-out
  [0.10, 0.30,  3600, 'good'],            // boundary: 0.30 is healthy
  [0.05, 0.80,  3600, 'good'],            // both levers healthy
  [0.05, null,  3600, 'good'],            // stall healthy, no conc data → good (not fanout)
];
let bad = 0;
for (const [s, c, w, want] of cases) {
  const got = verdictFor(s, c, w).kind;
  if (got !== want) { bad++; console.log(`FAIL stall=${s} conc=${c} work=${w}: want ${want}, got ${got}`); }
}
process.exit(bad);
NODE
    } > "$VERDICT_JS"
    if node_out=$(node "$VERDICT_JS" 2>&1); then
      ok "verdictFor selects correct branch across all cases + boundaries"
    else
      ng "verdictFor branch mismatch: $node_out"
    fi
    # Sanity: every branch kind the renderer switches on must be one verdictFor
    # can actually return — guards against a renamed kind drifting out of sync.
    for kind in gated-fanout gated-quiet stall-critical stall-high fanout good; do
      grep -q "case '$kind'" "$DASHBOARD_PATH" \
        && ok "renderVerdict handles '$kind'" \
        || ng "renderVerdict missing case for '$kind'"
    done
  fi
else
  skip "dashboard verdict logic (node or dashboard.html absent)"
fi

# ---------------------------------------------------------------------------
section "dashboard event ordering (writer-precision + exact-tie regression)"

# Root cause of a real dashboard/menubar count mismatch: tab-title.sh stamps
# events.jsonl with fractional-second ts (gdate %s.%3N), but sweep-bell-
# state.sh's logical-state correction pass (the one that emits the true
# agents/watching/idle correction) used to stamp with bare-integer ts
# (date +%s). A same-second pair then numerically sorted with the LATER-
# written but integer-stamped correction (e.g. 1785244323) landing BEFORE
# the earlier fractional event (e.g. 1785244323.192) — no stable secondary
# sort can undo that, since the ts values genuinely differ. The only real
# fix is both writers using matching precision, so once that holds, write
# order and numeric ts order agree. Guard the writer directly.
if grep -q '_now_frac=\$(gdate' "$HOOKS_DIR/sweep-bell-state.sh" \
  && grep -q -- '--arg ts "\$_now_frac"' "$HOOKS_DIR/sweep-bell-state.sh"; then
  ok "sweep-bell-state.sh: logical-state correction pass uses fractional-second ts"
else
  ng "sweep-bell-state.sh: logical-state correction pass still stamps events.jsonl with integer-only ts"
fi

# Separately, parseEvents should still break literal ts ties (two events
# with the IDENTICAL numeric ts, e.g. a fast back-to-back append within the
# same millisecond) by file-append order rather than leaving the outcome to
# an unstable/engine-dependent sort — cheap insurance once precision is
# aligned, distinct from the precision-mismatch case above.
if command -v node >/dev/null 2>&1 && [ -f "$DASHBOARD_PATH" ]; then
  PARSE_FN=$(awk '/\/\/ <parseEvents>/{f=1;next} /\/\/ <\/parseEvents>/{f=0} f' "$DASHBOARD_PATH")
  if [ -z "$PARSE_FN" ]; then
    ng "could not extract parseEvents from $DASHBOARD_PATH (markers missing?)"
  else
    PARSE_JS="$TMPROOT/parse.js"
    {
      printf '%s\n' "$PARSE_FN"
      cat <<'NODE'
const text = [
  '{"ts":1785244323.192,"session_id":"s","state":"idle","title":"t","cwd":"c"}',
  '{"ts":1785244323.192,"session_id":"s","state":"agents","title":"t","cwd":"c"}',
].join('\n');
const evs = parseEvents(text);
let bad = 0;
if (evs.length !== 2) { bad++; console.log(`FAIL length: got ${evs.length}`); }
if (evs[evs.length - 1].state !== 'agents') {
  bad++; console.log(`FAIL last state: want agents, got ${evs[evs.length-1] && evs[evs.length-1].state} (order: ${evs.map(e=>e.state).join(',')})`);
}
process.exit(bad);
NODE
    } > "$PARSE_JS"
    if node_out=$(node "$PARSE_JS" 2>&1); then
      ok "parseEvents: exact-tie ts resolved by file-append order"
    else
      ng "parseEvents exact-tie mismatch: $node_out"
    fi
  fi
else
  skip "dashboard event ordering (node or dashboard.html absent)"
fi

# ---------------------------------------------------------------------------
section "dashboard straggler handling (end is terminal until resume)"

# `end` must be terminal: a working/input/watching event arriving after a
# session's `end` (a SubagentStop straggler firing during teardown, or a
# synthetic reconcile `end` that lost a same-second tie to a fractional
# straggler) must NOT resurrect the session and inflate the "working" card or
# paint a phantom open span. A fresh `idle` (SessionStart) DOES reopen it, so
# `claude --continue`/`--resume` (which reuse the session id) keep working.
# stripStragglers is pure and lives between markers in dashboard.html.
if command -v node >/dev/null 2>&1 && [ -f "$DASHBOARD_PATH" ]; then
  STRIP_FN=$(awk '/\/\/ <stripStragglers>/{f=1;next} /\/\/ <\/stripStragglers>/{f=0} f' "$DASHBOARD_PATH")
  if [ -z "$STRIP_FN" ]; then
    ng "could not extract stripStragglers from $DASHBOARD_PATH (markers missing?)"
  else
    STRIP_JS="$TMPROOT/strip.js"
    {
      printf '%s\n' "$STRIP_FN"
      cat <<'NODE'
const ev = (ts, state) => ({ ts, session_id: 's', state });
const last = (evs) => { const o = stripStragglers(evs); return o.length ? o[o.length - 1].state : '<empty>'; };
const states = (evs) => stripStragglers(evs).map(e => e.state).join(',');
const cases = [
  // [label, events, expected-last-after-strip]
  // straggler working after a real end, plus a synthetic end whose integer ts
  // lost the tie to the fractional straggler — last must read `end`, not working
  ['straggler+synthetic-end', [ev(1,'idle'),ev(2,'end'),ev(3,'end'),ev(3.1,'working')], 'end'],
  // pure graceful end, no straggler
  ['graceful-end', [ev(1,'idle'),ev(2,'working'),ev(3,'end')], 'end'],
  // crash reconciled where synthetic end ts < last working (same-second tie)
  ['synthetic-end-collide', [ev(5.0,'end'),ev(5.1,'working')], 'end'],
  // resume: end then a fresh idle (SessionStart) reopens; later work counts
  ['resume', [ev(1,'idle'),ev(2,'working'),ev(3,'end'),ev(10,'idle'),ev(11,'working')], 'working'],
  // genuinely live: no end at all
  ['live', [ev(1,'idle'),ev(2,'working')], 'working'],
];
let bad = 0;
for (const [label, evs, want] of cases) {
  const got = last(evs);
  if (got !== want) { bad++; console.log(`FAIL ${label}: want last=${want}, got ${got} (kept: ${states(evs)})`); }
}
// The straggler working itself must be dropped (not merely out-voted on ts).
if (states([ev(1,'idle'),ev(2,'end'),ev(3,'working')]) !== 'idle,end') {
  bad++; console.log('FAIL straggler not dropped from stream');
}
process.exit(bad);
NODE
    } > "$STRIP_JS"
    if node_out=$(node "$STRIP_JS" 2>&1); then
      ok "stripStragglers: end terminal until resume; stragglers dropped"
    else
      ng "stripStragglers mismatch: $node_out"
    fi
    # All three per-session consumers must run events through stripStragglers,
    # or a straggler leaks into the timeline/daily spans even if the cards are
    # clean. There are exactly three per-session loops; assert all are guarded.
    strip_uses=$(grep -c "stripStragglers(rawEvs)" "$DASHBOARD_PATH")
    [ "$strip_uses" = "3" ] && ok "all 3 per-session loops strip stragglers" \
      || ng "expected 3 stripStragglers(rawEvs) call sites, found $strip_uses"
  fi
else
  skip "dashboard straggler handling (node or dashboard.html absent)"
fi

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
