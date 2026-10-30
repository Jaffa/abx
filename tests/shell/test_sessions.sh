# Two sessions in one project: a session never removes the containers another is running in.

sessions_dir() { printf '%s/abx/%s/sessions' "$XDG_RUNTIME_DIR" "$PROJ_NAME"; }

# Another session of this project, as one registered by a running abx: this test's own process stands in for it.
other_session() { mkdir -p "$(sessions_dir)" && touch "$(sessions_dir)/$$"; }
no_other_session() { rm -f "$(sessions_dir)/$$"; }

test_session_is_registered_while_it_runs_and_removed_after() {
  printf 'ls "%s" > "$ABX_TEST_STATE/during"; echo $PPID > "$ABX_TEST_STATE/abx-pid"\n' "$(sessions_dir)" \
    > "$ABX_TEST_STATE/exec-hook"
  ABX_CLAUDE_DIR=off run_abx -p hi
  assert_status 0
  assert_eq "$(cat "$ABX_TEST_STATE/during")" "$(cat "$ABX_TEST_STATE/abx-pid")" "the session's file, named by abx's PID"
  assert_eq "$(ls "$(sessions_dir)")" "" "no session files after exit"
}

test_changed_configuration_does_not_kill_a_live_session() {
  ABX_CLAUDE_DIR=off run_abx -p hi
  other_session
  mkdir -p "$HOME/claude"
  reset_calls
  ABX_CLAUDE_DIR="$HOME/claude" run_abx -p hi
  assert_status 1
  assert_out_contains "would kill the abx session already running"
  assert_file_lacks "$ABX_TEST_STATE/events" "removed"
  assert_file_lacks .agent-sandbox/compose/user.override.yml "/opt/abx/.claude"

  # With the other session gone, the same change goes through, which it couldn't if the refusal had kept it.
  no_other_session
  ABX_CLAUDE_DIR="$HOME/claude" run_abx -p hi
  assert_status 0
  assert_out_contains "containers are being recreated"
  assert_file_contains .agent-sandbox/compose/user.override.yml "target: /opt/abx/.claude  # abx: uid-remap"
  assert_file_contains "$ABX_TEST_STATE/events" "removed"
}

test_changed_configuration_recreates_containers_when_no_session_is_live() {
  ABX_CLAUDE_DIR=off run_abx -p hi
  mkdir -p "$HOME/claude"
  ABX_CLAUDE_DIR="$HOME/claude" run_abx -p hi
  assert_status 0
  assert_out_contains "The sandbox's configuration changed, so its containers are being recreated."
}

test_dead_session_does_not_block_recreation() {
  ABX_CLAUDE_DIR=off run_abx -p hi
  mkdir -p "$(sessions_dir)" "$HOME/claude"
  touch "$(sessions_dir)/999999"
  ABX_CLAUDE_DIR="$HOME/claude" run_abx -p hi
  assert_status 0
  assert_no_file "$(sessions_dir)/999999"
}

test_wrong_time_zone_does_not_kill_a_live_session() {
  export TZ=Europe/London
  state agent-tz America/Los_Angeles
  container_add ctr-agent
  other_session
  run_abx -p hi
  assert_status 1
  assert_out_contains "would kill the abx session already running"
  assert_out_lacks "Recreating the sandbox containers"
  assert_file_lacks "$ABX_TEST_STATE/events" "removed"
}

test_rebuild_does_not_kill_a_live_session() {
  state probe "501 dev 501 readonly"
  ABX_CLAUDE_DIR=off run_abx -p hi
  assert_status 0
  other_session
  reset_calls
  ABX_CLAUDE_DIR=off run_abx rebuild
  assert_status 1
  assert_out_contains "would kill the abx session already running"
  assert_calls_lack "docker build"
}
