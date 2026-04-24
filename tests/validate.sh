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
#   ./tests/validate.sh            # concise output (failures + summary)
#   ./tests/validate.sh --verbose  # show passes too
#   ./tests/validate.sh -v
#
# Exit code: 0 if all non-skipped checks pass, non-zero equal to fail count.

set -u

VERBOSE=0
case "${1:-}" in -v|--verbose) VERBOSE=1 ;; esac

HOOKS_DIR="$HOME/.claude/hooks"
SWIFTBAR_APP="/Applications/SwiftBar.app"
SWIFTBAR_PLUGIN_DIR="$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)"
PLUGIN_PATH=""
[ -n "$SWIFTBAR_PLUGIN_DIR" ] && PLUGIN_PATH="$SWIFTBAR_PLUGIN_DIR/ghostty-bells.30s.sh"

TMPROOT="$(mktemp -d -t bell-validate.XXXXXX)"
export BELL_STATE_DIR="$TMPROOT/state"
export BELL_TRACE_LOG="$TMPROOT/trace.log"
mkdir -p "$BELL_STATE_DIR"
touch "$BELL_TRACE_LOG"

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
  unset BELL_STATE_DIR BELL_TRACE BELL_TRACE_LOG
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

for f in tab-title.sh notify.sh refresh-menubar.sh focus-ghostty-tab.sh sweep-bell-state.sh; do
  if [ -x "$HOOKS_DIR/$f" ]; then ok "$HOOKS_DIR/$f executable"; else ng "$HOOKS_DIR/$f missing or not executable"; fi
done

swiftbar=0
if [ -d "$SWIFTBAR_APP" ]; then swiftbar=1; ok "SwiftBar installed"; else skip "SwiftBar not installed"; fi

plugin=0
if [ "$swiftbar" = "1" ]; then
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
section "sweep-bell-state.sh"

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
