# Outbound TCP: a relay on the sandbox's network forwards each named endpoint, and nothing else.

relay() { printf 'abx-outbound-%s' "$PROJ_NAME"; }
sessions_dir() { printf '%s/abx/%s/sessions' "$XDG_RUNTIME_DIR" "$PROJ_NAME"; }

# Another session of this project, registered as a running abx would be: this test's own process stands in for it.
other_session() { mkdir -p "$(sessions_dir)" && touch "$(sessions_dir)/$$"; }

# A relay a live session started, relaying the comma-separated endpoints SPEC.
live_relay() {
  sidecar_add "$(relay)"
  printf '%s' "$$" > "$ABX_TEST_STATE/labels/$(relay).abx.owner-pid"
  printf '%s' "$1" > "$ABX_TEST_STATE/labels/$(relay).abx.outbound-spec"
  other_session
}

test_endpoint_is_relayed_and_reported_to_claude() {
  run_abx --outbound-tcp 192.168.1.50:5555 -p hi
  assert_status 0
  assert_out_contains "Relaying TCP to 192.168.1.50:5555"
  local args; args="$(tr '\n' ' ' < "$ABX_TEST_STATE/run-args/$(relay)")"
  case "$args" in *"-e OUTBOUND=192.168.1.50:5555 "*) ;; *) fail "relay endpoints: $args" ;; esac
  case "$args" in *"--network bridge"*) ;; *) fail "relay should be on the bridge, to reach the LAN: $args" ;; esac
  case "$args" in *"--read-only"*) ;; *) fail "relay should have a read-only filesystem: $args" ;; esac
  case "$args" in *"--cap-drop ALL"*) ;; *) fail "relay should drop all capabilities: $args" ;; esac
  assert_calls_contain "docker network connect --alias abx-outbound p_default $(relay)"
  assert_eq "$(settings_json "d['env']['ABX_OUTBOUND_TCP']")" "192.168.1.50:5555" "endpoints told to Claude"
  assert_file_contains "$ABX_TEST_STATE/events" "removed $(relay)"
}

test_several_endpoints_share_one_relay() {
  run_abx --outbound-tcp 192.168.1.50:5555 --outbound-tcp=10.0.0.9:8080 -p hi
  assert_status 0
  local args; args="$(tr '\n' ' ' < "$ABX_TEST_STATE/run-args/$(relay)")"
  case "$args" in *"-e OUTBOUND=192.168.1.50:5555,10.0.0.9:8080 "*) ;; *) fail "relay endpoints: $args" ;; esac
  assert_eq "$(settings_json "d['env']['ABX_OUTBOUND_TCP']")" "192.168.1.50:5555,10.0.0.9:8080" "endpoints told to Claude"
}

test_no_relay_without_the_flag() {
  run_abx -p hi
  assert_status 0
  assert_calls_lack "docker run -d --name $(relay)"
  assert_eq "$(settings_json "'ABX_OUTBOUND_TCP' in d['env']")" "False" "no endpoints told to Claude"
}

test_invalid_endpoints_are_refused_before_anything_starts() {
  run_abx --outbound-tcp 192.168.1.50 -p hi;          assert_status 1; assert_out_contains "isn't IP:PORT"
  run_abx --outbound-tcp tv.local:5555 -p hi;         assert_status 1; assert_out_contains "Names aren't looked up"
  run_abx --outbound-tcp 192.168.1.300:5555 -p hi;    assert_status 1; assert_out_contains "isn't IP:PORT"
  run_abx --outbound-tcp 127.0.0.1:5555 -p hi;        assert_status 1; assert_out_contains "can't be relayed"
  run_abx --outbound-tcp 169.254.9.9:5555 -p hi;      assert_status 1; assert_out_contains "can't be relayed"
  run_abx --outbound-tcp 224.0.0.1:5555 -p hi;        assert_status 1; assert_out_contains "can't be relayed"
  run_abx --outbound-tcp 192.168.1.50:80 -p hi;       assert_status 1; assert_out_contains "must be within 1024-65535"
  run_abx --outbound-tcp 192.168.1.50:70000 -p hi;    assert_status 1; assert_out_contains "must be within 1024-65535"
  run_abx --outbound-tcp 192.168.1.50:5555 --outbound-tcp 192.168.1.60:5555 -p hi
  assert_status 1; assert_out_contains "the ports must differ"
  run_abx --outbound-tcp; assert_status 1; assert_out_contains "needs IP:PORT"
  assert_calls_lack "docker run -d --name $(relay)"
}

test_host_gateway_address_is_refused() {
  # The bridge's gateway is the host itself: relaying to it would reach the host's own services, such as an adb server.
  mkdir -p "$ABX_TEST_STATE/gateways"; printf '172.17.0.1 ' > "$ABX_TEST_STATE/gateways/bridge"
  run_abx --outbound-tcp 172.17.0.1:5037 -p hi
  assert_status 1
  assert_out_contains "this machine's address on Docker network bridge"
  assert_calls_lack "docker run -d --name $(relay)"
}

test_public_address_is_flagged_and_relayed() {
  run_abx --outbound-tcp 8.8.8.8:8443 -p hi
  assert_status 0
  assert_out_contains "isn't on a private network"
  assert_out_contains "whatever the domain allowlist says"
}

test_other_session_relaying_other_endpoints_is_refused() {
  run_abx -p hi
  live_relay "10.0.0.9:8080"
  run_abx --outbound-tcp 192.168.1.50:5555 -p hi
  assert_status 1
  assert_out_contains "is relaying 10.0.0.9:8080, which doesn't include 192.168.1.50:5555"
  assert_file_lacks "$ABX_TEST_STATE/events" "removed $(relay)"
}

test_live_session_relay_is_shared_when_it_has_the_endpoints() {
  run_abx -p hi
  live_relay "192.168.1.50:5555,10.0.0.9:8080"
  reset_calls
  run_abx --outbound-tcp 10.0.0.9:8080 -p hi
  assert_status 0
  assert_out_contains "already set up by another abx session"
  assert_calls_lack "docker run -d --name $(relay)"
  assert_eq "$(settings_json "d['env']['ABX_OUTBOUND_TCP']")" "192.168.1.50:5555,10.0.0.9:8080" "the shared endpoints"
  assert_file_lacks "$ABX_TEST_STATE/events" "removed $(relay)"
}

test_stale_relay_is_replaced() {
  sidecar_add "$(relay)"
  printf '999999' > "$ABX_TEST_STATE/labels/$(relay).abx.owner-pid"
  printf '%s' "10.0.0.9:8080" > "$ABX_TEST_STATE/labels/$(relay).abx.outbound-spec"
  run_abx --outbound-tcp 192.168.1.50:5555 -p hi
  assert_status 0
  assert_calls_contain "docker run -d --name $(relay)"
}

test_relay_is_kept_while_another_session_is_live() {
  run_abx -p hi
  other_session
  reset_calls
  run_abx --outbound-tcp 192.168.1.50:5555 -p hi
  assert_status 0
  assert_calls_contain "docker run -d --name $(relay)"
  assert_file_lacks "$ABX_TEST_STATE/events" "removed $(relay)"
}

test_relay_serves_a_shell_session() {
  run_abx --outbound-tcp 192.168.1.50:5555 shell
  assert_status 0
  assert_calls_contain "docker run -d --name $(relay)"
  assert_file_contains "$ABX_TEST_STATE/events" "removed $(relay)"
}

test_clean_removes_the_relay() {
  run_abx -p hi
  sidecar_add "$(relay)"
  run_abx clean --yes
  assert_status 0
  assert_file_contains "$ABX_TEST_STATE/events" "removed $(relay)"
}
