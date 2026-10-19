# Terminal state: restored when a session ends, and interactive commands run through
# _run_interactive so that it always is.

SAVED_TTY=""

# Claude's TUI switches on modes (colours, hidden cursor, bracketed paste, mouse and focus
# reporting) that are not always switched off when its output is cut short by the container
# exec ending, so they are reset here rather than relying on the inner process.
_restore_terminal() {
  _stop_port_forwarder
  _stop_bedrock_gateway
  _unregister_session
  if [ -n "$REFRESHER_PID" ]; then
    kill "$REFRESHER_PID" 2>/dev/null || true
    if [ -s "$REFRESH_LOG" ]; then
      echo "[warning] Credential refresh failed during the session; see $REFRESH_LOG" >&2
    fi
  fi
  if [ -t 1 ]; then
    printf '\033[0m\033[?25h\033[?2004l\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1004l'
  fi
  if [ -n "$SAVED_TTY" ] && [ -t 0 ]; then
    stty "$SAVED_TTY" 2>/dev/null || true
  fi
}

_run_interactive() {
  local rc
  _register_session
  if [ -t 0 ]; then SAVED_TTY="$(stty -g 2>/dev/null || true)"; fi
  trap _restore_terminal EXIT
  set +e
  "$@"
  rc=$?
  set -e
  exit "$rc"
}
