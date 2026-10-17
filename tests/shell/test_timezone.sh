# The sandbox's clock uses the host's time zone, not agentbox's America/Los_Angeles default.

# The zone this machine's system names, as abx should find it: /etc/localtime's link, else /etc/timezone, else UTC.
host_zone() {
  local zone=""
  if [ -L /etc/localtime ]; then zone="$(readlink /etc/localtime | sed 's#.*zoneinfo/##')"; fi
  [ -n "$zone" ] || zone="$(head -n 1 /etc/timezone 2>/dev/null | tr -d '[:space:]' || true)"
  printf '%s' "${zone:-UTC}"
}

test_host_TZ_is_passed_to_the_sandbox() {
  export TZ=Asia/Tokyo
  run_abx -p hi
  assert_eq "$(cat "$ABX_TEST_STATE/agent-tz")" Asia/Tokyo "the agent should start in the host's zone"
}

test_system_zone_is_used_when_TZ_is_unset() {
  unset TZ
  run_abx -p hi
  assert_eq "$(cat "$ABX_TEST_STATE/agent-tz")" "$(host_zone)" "with TZ unset, the agent should use the system's zone"
}

test_sandbox_made_for_another_zone_is_recreated() {
  export TZ=Europe/London
  state agent-tz America/Los_Angeles
  container_add ctr-agent
  run_abx -p hi
  assert_out_contains "Recreating the sandbox containers so their clock uses Europe/London"
  assert_eq "$(cat "$ABX_TEST_STATE/agent-tz")" Europe/London "the recreated agent should use the host's zone"
}

test_sandbox_in_the_host_zone_is_kept() {
  export TZ=Europe/London
  state agent-tz Europe/London
  container_add ctr-agent
  run_abx -p hi
  assert_out_lacks "Recreating the sandbox containers"
}
