#!/bin/bash
# Manage the metrics dashboard HTTP server.
#
# Usage: dashboard-server.sh <start|stop|status|toggle>
#
# - start  : launch `python3 -m http.server $PORT` from ~/.claude/.ccg/ in the
#            background, write its PID to ~/.claude/.ccg/server.pid, then open
#            http://localhost:$PORT/dashboard.html in the default browser.
#            If a server is already running, just opens the URL.
# - stop   : kill the tracked PID and remove the PID file.
# - status : prints "running" or "stopped" (exit 0 either way).
# - toggle : stop if running, start if not.
#
# The server has to be served (not opened as file://) because the dashboard
# fetches events.jsonl over HTTP. See ~/.claude/.ccg/dashboard.html.
#
# Debug: set BELL_TRACE=1 to append diagnostics to $BELL_TRACE_LOG.

__N=dashboard-server.sh
__trace() {
  [ -n "$BELL_TRACE" ] || return 0
  printf '%s [%s pid=%s ppid=%s] %s\n' \
    "$(gdate +%s.%3N 2>/dev/null || date +%s)" "$__N" "$$" "$PPID" "$*" \
    >> "${BELL_TRACE_LOG:-/tmp/bell-trace.log}"
}

CCG_DIR="${CCG_DIR:-$HOME/.claude/.ccg}"
PORT="${CCG_DASHBOARD_PORT:-8765}"
PID_FILE="$CCG_DIR/server.pid"
LOG_FILE="$CCG_DIR/server.log"
URL="http://localhost:$PORT/dashboard.html"

is_running() {
  [ -f "$PID_FILE" ] || return 1
  local pid
  pid=$(cat "$PID_FILE" 2>/dev/null)
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

start_server() {
  __trace "start invoked, running=$(is_running && echo y || echo n)"
  if is_running; then
    __trace "already running pid=$(cat "$PID_FILE")"
    open "$URL" 2>/dev/null
    return 0
  fi

  mkdir -p "$CCG_DIR"
  # Stale PID file from a previous run that died — drop it.
  rm -f "$PID_FILE"

  # Detach from the controlling shell so SwiftBar's invocation doesn't keep
  # the server tied to a short-lived process group.
  (
    cd "$CCG_DIR" || exit 1
    nohup python3 -m http.server "$PORT" --bind 127.0.0.1 \
      >"$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    disown 2>/dev/null || true
  )

  # Wait briefly for the bind to succeed before opening the browser.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sf -o /dev/null "$URL" 2>/dev/null; then
      __trace "server up, opening browser"
      open "$URL" 2>/dev/null
      return 0
    fi
    sleep 0.2
  done

  __trace "server did not respond within 2s; opening anyway"
  open "$URL" 2>/dev/null
}

stop_server() {
  __trace "stop invoked, running=$(is_running && echo y || echo n)"
  if ! is_running; then
    rm -f "$PID_FILE"
    return 0
  fi
  local pid
  pid=$(cat "$PID_FILE")
  kill "$pid" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  # If still alive, escalate.
  if kill -0 "$pid" 2>/dev/null; then
    __trace "graceful kill timed out, sending SIGKILL"
    kill -9 "$pid" 2>/dev/null
  fi
  rm -f "$PID_FILE"
  __trace "stopped"
}

case "${1:-}" in
  start)  start_server ;;
  stop)   stop_server  ;;
  status) is_running && echo running || echo stopped ;;
  toggle) is_running && stop_server || start_server ;;
  *)
    printf 'Usage: %s start|stop|status|toggle\n' "$0" >&2
    exit 2
    ;;
esac
