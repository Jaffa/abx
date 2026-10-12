# Bedrock mode: the signing gateway, credential handling and session sharing.

GATEWAY=abx-gateway-proj

test_bedrock_routes_through_gateway() {
  run_abx --bedrock -p hi
  assert_status 0
  assert_eq "$(settings_json "d['env']['ANTHROPIC_BEDROCK_BASE_URL']")" "http://abx-gateway:8787" "gateway URL"
  assert_eq "$(settings_json "d['env']['CLAUDE_CODE_SKIP_BEDROCK_AUTH']")" "1" "skip auth"
  assert_eq "$(settings_json "d['env']['CLAUDE_CODE_USE_BEDROCK']")" "1" "use Bedrock"
  assert_eq "$(settings_json "d['env']['NO_PROXY']")" "localhost,127.0.0.1,proxy,abx-gateway" "NO_PROXY extends the container's own"
  assert_eq "$(settings_json "'awsCredentialExport' in d")" "False" "no credential export"
  assert_calls_contain "docker network connect --alias abx-gateway p_default $GATEWAY"
}

test_gateway_container_is_hardened() {
  run_abx --bedrock -p hi
  local args; args="$(tr '\n' ' ' < "$ABX_TEST_STATE/run-args/$GATEWAY")"
  case "$args" in *"--user 1000:100"*) ;; *) fail "gateway should run as the host user: $args" ;; esac
  case "$args" in *"--read-only"*) ;; *) fail "gateway should have a read-only filesystem: $args" ;; esac
  case "$args" in *"--cap-drop ALL"*) ;; *) fail "gateway should drop all capabilities: $args" ;; esac
  case "$args" in *"no-new-privileges"*) ;; *) fail "gateway should forbid privilege escalation: $args" ;; esac
  case "$args" in *"-v $XDG_RUNTIME_DIR/abx/proj/creds:/run/abx-credentials:ro"*) ;; *) fail "credentials should be mounted read-only: $args" ;; esac
  case "$args" in *"-p "*) fail "the gateway must not publish ports: $args" ;; esac
}

test_credentials_stay_out_of_project_and_are_private() {
  mkdir -p .abx && printf '{"old":"credentials"}' > .abx/aws-credentials.json
  cat > "$ABX_TEST_STATE/exec-hook" <<'HOOK'
stat -c '%a %n' "$XDG_RUNTIME_DIR/abx" "$XDG_RUNTIME_DIR/abx/proj" "$XDG_RUNTIME_DIR/abx/proj/creds" \
  "$XDG_RUNTIME_DIR/abx/proj/creds/aws-credentials.json" > "$ABX_TEST_STATE/perms" 2>&1 \
  || ls -ld "$XDG_RUNTIME_DIR/abx/proj/creds/aws-credentials.json" > "$ABX_TEST_STATE/perms"
HOOK
  run_abx --bedrock -p hi
  assert_no_file .abx/aws-credentials.json
  ! grep -rq "ASIATEST" "$PROJECT" || fail "credentials found inside the project"
  assert_eq "$(awk '{print $1}' "$ABX_TEST_STATE/perms" | tr '\n' ' ')" "700 700 700 600 " "permissions while running"
  assert_no_file "$XDG_RUNTIME_DIR/abx/proj/creds/aws-credentials.json"
  assert_file_contains "$ABX_TEST_STATE/events" "removed $GATEWAY"
}

test_bedrock_mode_is_remembered_and_can_be_turned_off() {
  run_abx --bedrock -p hi
  run_abx -p hi
  assert_eq "$(settings_json "d['env']['CLAUDE_CODE_USE_BEDROCK']")" "1" "remembered"
  run_abx --no-bedrock -p hi
  assert_out_contains "Bedrock mode is off"
  assert_eq "$(settings_json "'env' in d")" "False" "Bedrock settings removed"
  assert_no_file "$(state_dir)/bedrock-profile"
}

test_expired_login_is_reported() {
  state aws-fail yes
  run_abx --bedrock -p hi
  assert_status 1
  assert_out_contains "Token has expired"
  assert_out_contains "aws sso login"
}

test_live_concurrent_session_shares_gateway() {
  mkdir -p "$XDG_RUNTIME_DIR/abx/proj/sessions" "$ABX_TEST_STATE/running"
  touch "$XDG_RUNTIME_DIR/abx/proj/sessions/$$" "$ABX_TEST_STATE/running/$GATEWAY"
  run_abx --bedrock -p hi
  assert_calls_lack "docker run -d --name $GATEWAY"
  assert_file_lacks "$ABX_TEST_STATE/events" "removed $GATEWAY"
}

test_dead_session_does_not_hold_gateway() {
  mkdir -p "$XDG_RUNTIME_DIR/abx/proj/sessions" "$ABX_TEST_STATE/running"
  touch "$XDG_RUNTIME_DIR/abx/proj/sessions/999999" "$ABX_TEST_STATE/running/$GATEWAY"
  run_abx --bedrock -p hi
  assert_calls_contain "docker run -d --name $GATEWAY"
  assert_no_file "$XDG_RUNTIME_DIR/abx/proj/sessions/999999"
  assert_file_contains "$ABX_TEST_STATE/events" "removed $GATEWAY"
}

test_signer_built_from_resources() {
  run_abx --bedrock -p hi
  local built; built="$(ls "$ABX_TEST_STATE"/built/abx_bedrock-signer_*.signer.py)"
  cmp -s "$built" "$REPO_DIR/resources/abx-bedrock-signer.py" || fail "signer image should contain resources/abx-bedrock-signer.py"
}

test_sandbox_that_will_not_start_is_explained() {
  printf 'dependency failed to start: container proj-proxy-1 exited (1)\n' > "$ABX_TEST_STATE/stack-fails"
  state exited proj-proxy-1
  printf '          proj-agent-1  Created\n          proj-proxy-1  Exited (1)\n' > "$ABX_TEST_STATE/ps-list"
  mkdir -p "$ABX_TEST_STATE/logs" && echo "user.policy.yaml.services[1] must contain 'name'" > "$ABX_TEST_STATE/logs/proj-proxy-1"
  ABX_SKIP_UID_CHECK=true run_abx --bedrock -p hi
  assert_status 1
  assert_out_contains "dependency failed to start"
  assert_out_contains "Last lines from proj-proxy-1"
  assert_out_contains "must contain 'name'"
}
