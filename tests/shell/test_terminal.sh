# Exit status and terminal restoration around the Claude session.

test_exit_status_of_session_is_returned() {
  state exec-exit 3
  run_abx -p hi
  assert_status 3
}

test_no_escape_sequences_when_not_a_terminal() {
  run_abx -p hi
  case "$OUT" in *$'\033'*) fail "escape sequences written to a non-terminal" ;; esac
}

test_terminal_modes_reset_after_session() {
  script -qec true /dev/null >/dev/null 2>&1 || skip "needs util-linux script"
  local out
  out="$(script -qec "bash '$HOME/.local/bin/abx' -p hi" /dev/null 2>&1 | cat -v)"
  case "$out" in *'^[[0m^[[?25h^[[?2004l'*) ;; *) OUT="$out"; fail "terminal reset sequence missing" ;; esac
}
