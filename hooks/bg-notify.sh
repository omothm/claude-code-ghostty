#!/bin/bash
# Deferred "Background task completed" notification.
# Usage: bg-notify.sh arm <session_id> <edge_ts> [cwd]
#        bg-notify.sh fire <session_id> <token>   (internal: the detached checker)
#
# `arm` is called by tab-title.sh and sweep-bell-state.sh on a logical
# `agents -> idle` edge, with <edge_ts> = the ts they just wrote to line 3 of
# the session's logical-state file. It writes a per-session marker with a
# fresh token and spawns a fully detached checker, then returns at once.
# After CCG_BG_NOTIFY_DELAY_SEC (default 30) the checker sends the
# notification only if:
#   - the marker still holds its token (a newer edge re-armed, or notify.sh
#     sent/skipped another notification for the session and cleared it), and
#   - the logical state is still `idle` with the same line-3 ts as the edge
#     (no transition at all since the edge).
#
# Marker: $CCG_BG_NOTIFY_DIR/<session_id> (default ~/.claude/.ccg/bgnotify)
#   line 1: token   line 2: edge ts   line 3: cwd (notification subtitle)
#
# Debug: set BELL_TRACE=1 to append diagnostics to $BELL_TRACE_LOG.

__N=bg-notify.sh
__trace() {
  [ -n "$BELL_TRACE" ] || return 0
  printf '%s [%s pid=%s ppid=%s] %s\n' \
    "$(gdate +%s.%3N 2>/dev/null || date +%s)" "$__N" "$$" "$PPID" "$*" \
    >> "${BELL_TRACE_LOG:-/tmp/bell-trace.log}"
}

BG_DIR="${CCG_BG_NOTIFY_DIR:-$HOME/.claude/.ccg/bgnotify}"
SESSION_STATE_DIR="${CCG_SESSION_STATE_DIR:-$HOME/.claude/.ccg/sessions}"
cmd="$1"
sid="$2"
[ -n "$sid" ] || exit 0
marker="$BG_DIR/$sid"

case "$cmd" in
  arm)
    edge_ts="$3"
    cwd="${4-}"
    token="$(date +%s)-$$-$RANDOM"
    mkdir -p "$BG_DIR" 2>/dev/null
    # Write-then-rename so a checker never reads a half-written marker.
    printf '%s\n%s\n%s\n' "$token" "$edge_ts" "$cwd" > "$marker.$$" 2>/dev/null \
      && mv -f "$marker.$$" "$marker" 2>/dev/null
    # Detached: Claude Code waits for a hook's stdio to close, so every fd must
    # be redirected or the hook would block for the whole delay.
    nohup "$0" fire "$sid" "$token" < /dev/null > /dev/null 2>&1 &
    __trace "armed sid=$sid token=$token edge_ts=$edge_ts delay=${CCG_BG_NOTIFY_DELAY_SEC:-30}"
    ;;
  fire)
    token="$3"
    sleep "${CCG_BG_NOTIFY_DELAY_SEC:-30}"
    [ -f "$marker" ] || { __trace "fire-skip sid=$sid reason=marker-cleared"; exit 0; }
    m_token=$(sed -n '1p' "$marker" 2>/dev/null)
    m_ts=$(sed -n '2p' "$marker" 2>/dev/null)
    m_cwd=$(sed -n '3p' "$marker" 2>/dev/null)
    if [ "$m_token" != "$token" ]; then
      __trace "fire-skip sid=$sid reason=superseded token=$token current=$m_token"
      exit 0
    fi
    st=$(sed -n '1p' "$SESSION_STATE_DIR/$sid" 2>/dev/null | tr -d ' ')
    st_ts=$(sed -n '3p' "$SESSION_STATE_DIR/$sid" 2>/dev/null | tr -d ' ')
    rm -f "$marker" 2>/dev/null
    if [ "$st" != "idle" ] || [ "$st_ts" != "$m_ts" ]; then
      __trace "fire-skip sid=$sid reason=state-moved state=${st:-<none>} ts=$st_ts edge_ts=$m_ts"
      exit 0
    fi
    __trace "fire sid=$sid"
    jq -nc --arg sid "$sid" --arg cwd "$m_cwd" '{session_id: $sid, cwd: $cwd}' \
      | "$(dirname "$0")/notify.sh" '✅' 'Background task completed' > /dev/null 2>&1
    ;;
esac
exit 0
