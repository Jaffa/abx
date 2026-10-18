# 'abx policy' and 'abx reload' when the proxy's view of a policy file is out of date, as after an editor replaced the
# file that Docker had bind-mounted. The docker stub models the proxy's view with proxy-view (tests/stubs/docker).

POLICY=.agent-sandbox/policy/user.policy.yaml
AGENT_POLICY=.agent-sandbox/policy/user.agent.claude.policy.yaml

# A project whose proxy is running, with a policy edited since the proxy last saw it.
edited_project() {
  ABX_CLAUDE_DIR=off run_abx -p hi
  printf 'domains:\n  - docs.example.com\n' > "$POLICY"
  proxy_sees user.policy.yaml $'domains:\n  - old.example.com'
  reset_calls
}

test_reload_restarts_a_proxy_that_reads_a_replaced_file() {
  edited_project
  run_abx reload
  assert_status 0
  assert_out_contains "restarting the proxy"
  assert_out_contains "Restarted ctr-proxy"
  assert_file_contains "$ABX_TEST_STATE/events" "restarted ctr-proxy"
  assert_calls_lack "agentbox proxy reload"
}

test_reload_sends_sighup_when_the_proxy_sees_the_current_file() {
  ABX_CLAUDE_DIR=off run_abx -p hi
  reset_calls
  run_abx reload
  assert_status 0
  assert_calls_contain "agentbox proxy reload"
  assert_calls_lack "docker restart"
}

test_reload_restarts_for_a_replaced_agent_policy_file() {
  ABX_CLAUDE_DIR=off run_abx -p hi
  printf 'domains:\n  - agent.example.com\n' > "$AGENT_POLICY"
  proxy_sees user.agent.policy.yaml $'domains:\n  - old.example.com'
  reset_calls
  run_abx reload
  assert_status 0
  assert_out_contains "user.agent.claude.policy.yaml"
  assert_file_contains "$ABX_TEST_STATE/events" "restarted ctr-proxy"
}

test_reload_notices_a_file_that_differs_only_in_its_final_newline() {
  ABX_CLAUDE_DIR=off run_abx -p hi
  printf 'domains:\n  - docs.example.com' > "$POLICY"
  printf 'domains:\n  - docs.example.com\n' > "$ABX_TEST_STATE/old"
  mkdir -p "$ABX_TEST_STATE/proxy-view" && cp "$ABX_TEST_STATE/old" "$ABX_TEST_STATE/proxy-view/user.policy.yaml"
  reset_calls
  run_abx reload
  assert_file_contains "$ABX_TEST_STATE/events" "restarted ctr-proxy"
}

test_reload_does_not_restart_a_proxy_when_the_policy_is_invalid() {
  edited_project
  printf 'services:\n  - INVALID\n' > "$POLICY"
  run_abx reload
  assert_status 1
  assert_out_contains "invalid"
  assert_out_contains "abx policy"
  assert_calls_lack "docker restart"
}

test_reload_reports_a_proxy_that_does_not_come_back() {
  edited_project
  state restart-crashes ""
  run_abx reload
  assert_status 1
  assert_out_contains "didn't come back up"
  assert_out_contains "abx logs"
}

test_reload_reports_a_failed_restart() {
  edited_project
  echo "Error response from daemon: cannot restart" > "$ABX_TEST_STATE/restart-fails"
  run_abx reload
  assert_status 1
  assert_out_contains "Couldn't restart the proxy"
  assert_out_contains "proxy-restart.log"
  assert_file_contains "$(state_dir)/proxy-restart.log" "cannot restart"
}

test_reload_leaves_another_directorys_proxy_alone() {
  ABX_CLAUDE_DIR=off run_abx -p hi
  container_drop ctr-proxy
  container_add ctr-foreign-proxy proxy ghcr.io/mattolson/agent-sandbox-proxy:latest 2026-01-01T00:00:00Z true "$HOME/src/other/.agent-sandbox"
  proxy_sees user.policy.yaml $'domains:\n  - old.example.com'
  reset_calls
  run_abx reload
  assert_calls_lack "docker exec"
  assert_calls_lack "docker restart"
  assert_calls_contain "agentbox proxy reload"
}

test_policy_restarts_a_proxy_that_reads_a_replaced_file_after_editing() {
  edited_project
  run_abx policy
  assert_status 0
  assert_file_contains "$ABX_TEST_STATE/edit-policy" "VISUAL="
  assert_file_contains "$ABX_TEST_STATE/events" "restarted ctr-proxy"
}

test_policy_leaves_a_current_proxy_alone() {
  ABX_CLAUDE_DIR=off run_abx -p hi
  reset_calls
  run_abx policy
  assert_status 0
  assert_calls_lack "docker restart"
}

test_policy_does_not_check_the_proxy_when_editing_fails() {
  edited_project
  state edit-fails ""
  run_abx policy
  assert_status 1
  assert_calls_lack "docker exec"
  assert_calls_lack "docker restart"
}
