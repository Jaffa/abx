# Session-scoped port publishing. High port numbers avoid clashing with services on the test machine.

FORWARDER=abx-ports-proj

test_ports_published_on_localhost_and_reported_to_claude() {
  run_abx --ports=47100-47102 -p hi
  assert_status 0
  assert_out_contains "Publishing ports 47100-47102 on localhost"
  local args; args="$(tr '\n' ' ' < "$ABX_TEST_STATE/run-args/$FORWARDER")"
  case "$args" in *"-p 127.0.0.1:47100:47100 -p 127.0.0.1:47101:47101 -p 127.0.0.1:47102:47102"*) ;; *) fail "ports: $args" ;; esac
  case "$args" in *"--read-only"*) ;; *) fail "forwarder should have a read-only filesystem: $args" ;; esac
  case "$args" in *"--cap-drop ALL"*) ;; *) fail "forwarder should drop all capabilities: $args" ;; esac
  assert_eq "$(settings_json "d['env']['ABX_PUBLISHED_PORTS']")" "47100-47102" "ports told to Claude"
  assert_file_contains "$ABX_TEST_STATE/events" "removed $FORWARDER"
}

test_default_port_set() {
  ABX_PORTS=default run_abx -p hi
  case "$OUT" in *"Skipping ports already in use"*) skip "some default ports are in use on this machine" ;; esac
  assert_eq "$(settings_json "d['env']['ABX_PUBLISHED_PORTS']")" "3000-3010,4173,5170-5190,6006,8080-8090" "default ports"
}

test_lan_publishing_warns() {
  run_abx --ports-lan=47110 -p hi
  assert_out_contains "PORTS ARE OPEN TO THE NETWORK"
  assert_file_contains "$ABX_TEST_STATE/run-args/$FORWARDER" "0.0.0.0:47110:47110"
}

test_invalid_port_specs_refused() {
  run_abx --ports=80 -p hi;        assert_out_contains "must be within 1024-65535"
  run_abx --ports=50-abc -p hi;    assert_out_contains "Invalid port spec"
  run_abx --ports=20000-20300 -p hi; assert_out_contains "publish at most 200"
}

test_port_in_use_on_host_is_skipped() {
  listen_on 47121
  run_abx --ports=47120-47122 -p hi
  assert_out_contains "Skipping ports already in use on the host: 47121"
  assert_eq "$(settings_json "d['env']['ABX_PUBLISHED_PORTS']")" "47120,47122" "published ports"
}

test_port_reserved_by_docker_is_retried_without() {
  state busy-ports 47131
  run_abx --ports=47130-47132 -p hi
  assert_out_contains "Skipping ports already in use on the host: 47131"
  assert_eq "$(calls | grep -c "docker run -d --name $FORWARDER")" "2" "attempts"
  assert_eq "$(settings_json "d['env']['ABX_PUBLISHED_PORTS']")" "47130,47132" "published ports"
}

test_all_ports_busy_continues_without() {
  state busy-ports 47140
  run_abx --ports=47140 -p hi
  assert_status 0
  assert_out_contains "All the requested ports are already in use"
  assert_eq "$(settings_json "'env' in d")" "False" "no ports told to Claude"
}

test_other_docker_error_reported_and_session_continues() {
  state run-fails 'docker: invalid argument "x" for "-p, --publish" flag'
  run_abx --ports=47150 -p hi
  assert_status 0
  assert_out_contains "Docker said:"
  assert_out_contains 'invalid argument "x"'
  assert_file .abx/ports.log
  exec_args | grep -q claude || fail "the session should still start"
}

test_live_owner_shares_forwarder_and_its_ports() {
  mkdir -p "$ABX_TEST_STATE/running" "$ABX_TEST_STATE/labels"
  touch "$ABX_TEST_STATE/running/$FORWARDER"
  printf '%s' "$$" > "$ABX_TEST_STATE/labels/$FORWARDER.owner-pid"
  printf '47160-47161' > "$ABX_TEST_STATE/labels/$FORWARDER.ports-spec"
  run_abx --ports=47170 -p hi
  assert_out_contains "Ports 47160-47161 are already published by another abx session"
  assert_eq "$(settings_json "d['env']['ABX_PUBLISHED_PORTS']")" "47160-47161" "shared ports"
  assert_file_lacks "$ABX_TEST_STATE/events" "removed $FORWARDER"
}

test_forwarder_left_by_crashed_session_is_replaced() {
  mkdir -p "$ABX_TEST_STATE/running" "$ABX_TEST_STATE/labels"
  touch "$ABX_TEST_STATE/running/$FORWARDER"
  printf '999999' > "$ABX_TEST_STATE/labels/$FORWARDER.owner-pid"
  run_abx --ports=47180 -p hi
  assert_calls_contain "docker run -d --name $FORWARDER"
}

test_no_ports_overrides_environment() {
  ABX_PORTS=47190 run_abx --no-ports -p hi
  assert_calls_lack "docker run -d --name $FORWARDER"
}
