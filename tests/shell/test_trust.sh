# The host never runs, imports or sources a file the agent can write. Each test plants a payload that
# creates $ABX_TEST_STATE/pwned if it ever runs, and asserts that the marker doesn't appear.

# Creates the marker when imported, so importing a planted json.py would show up.
plant_json_payload() {
  mkdir -p "$1"
  printf '%s\n' 'import os' 'open(os.path.join(os.environ["ABX_TEST_STATE"], "pwned"), "w").close()' > "$1/json.py"
}

# Writes a state file whose first line would run a command if it were sourced.
plant_uid_remap() {
  printf '%s\n' 'BASE=x; touch "$ABX_TEST_STATE/pwned"' 'USER_NAME=dev' 'ORIG_USER=' 'OLD_UID=501' \
    'TARGET_UID=1000' 'EXTRAS_HASH=none' > "$1"
}

# Every abx run that starts Python, with a project whose .abx/ may hold planted files.
run_python_commands() {
  run_abx -p hi
  run_abx --bedrock -p hi
  run_abx --ports=47200 -p hi
  state probe "501 dev readonly"
  run_abx -p hi
}

test_json_planted_in_project_is_not_imported() {
  plant_json_payload "$PROJECT"
  run_python_commands
  assert_no_file "$ABX_TEST_STATE/pwned"
}

test_json_planted_on_pythonpath_is_not_imported() {
  plant_json_payload "$T/pypath"
  export PYTHONPATH="$T/pypath"
  run_python_commands
  assert_no_file "$ABX_TEST_STATE/pwned"
}

test_usercustomize_in_user_site_is_not_loaded() {
  local site
  site="$(python3 -c 'import site; print(site.getusersitepackages())')"
  mkdir -p "$site"
  printf '%s\n' 'import os' 'open(os.path.join(os.environ["ABX_TEST_STATE"], "pwned"), "w").close()' > "$site/usercustomize.py"
  run_python_commands
  assert_no_file "$ABX_TEST_STATE/pwned"
}

test_uid_remap_in_project_is_not_sourced_on_rebuild() {
  run_abx -p hi
  plant_uid_remap .abx/uid-remap.env
  run_abx rebuild
  assert_no_file "$ABX_TEST_STATE/pwned"
}

test_uid_remap_in_project_is_not_sourced_on_extras_change() {
  run_abx -p hi
  plant_uid_remap .abx/uid-remap.env
  printf 'RUN echo extra\n' > "$CONFIG/Dockerfile.extra"
  run_abx -p hi
  assert_no_file "$ABX_TEST_STATE/pwned"
}

test_uid_remap_in_state_dir_is_validated_on_rebuild() {
  run_abx -p hi
  mkdir -p "$(state_dir)"
  plant_uid_remap "$(state_dir)/uid-remap.env"
  run_abx rebuild
  assert_no_file "$ABX_TEST_STATE/pwned"
}

test_uid_remap_in_state_dir_is_validated_on_extras_change() {
  run_abx -p hi
  mkdir -p "$(state_dir)"
  plant_uid_remap "$(state_dir)/uid-remap.env"
  printf 'RUN echo extra\n' > "$CONFIG/Dockerfile.extra"
  run_abx -p hi
  assert_no_file "$ABX_TEST_STATE/pwned"
}

test_bedrock_profile_in_project_is_not_run() {
  run_abx -p hi
  printf '%s\n' 'x;touch "$ABX_TEST_STATE/pwned"' > .abx/bedrock-profile
  run_abx -p hi
  assert_no_file "$ABX_TEST_STATE/pwned"
  assert_calls_lack "x;touch"
}

test_bedrock_profile_in_state_dir_is_validated() {
  run_abx -p hi
  mkdir -p "$(state_dir)"
  printf '%s\n' 'x;touch "$ABX_TEST_STATE/pwned"' > "$(state_dir)/bedrock-profile"
  run_abx -p hi
  assert_no_file "$ABX_TEST_STATE/pwned"
  assert_calls_lack "x;touch"
}

test_uid_ok_in_project_is_not_trusted() {
  mkdir -p .abx && printf '1000\n' > .abx/uid-ok
  state probe "501 dev readonly"
  reset_calls
  ABX_CLAUDE_MD=off run_abx -p hi
  assert_calls_contain "docker build"
}

# The state directory: host-only, private, and the home of everything abx reads back.

test_state_dir_is_private() {
  run_abx -p hi
  assert_eq "$(ls -ld "$(state_dir)" | cut -c1-10)" "drwx------" "state directory mode"
}

test_logs_and_host_state_are_kept_in_state_dir() {
  state probe "501 dev readonly"
  ABX_CLAUDE_MD=off run_abx -p hi
  assert_file "$(state_dir)/probe.log"
  assert_file "$(state_dir)/uid-ok"
  assert_no_file .abx/probe.log
  assert_no_file .abx/uid-ok
}

test_old_uid_remap_is_migrated_when_valid() {
  mkdir -p .abx
  printf '%s\n' 'BASE=ghcr.io/mattolson/agent-sandbox-claude:latest' 'USER_NAME=dev' 'ORIG_USER=' \
    'OLD_UID=501' 'TARGET_UID=1000' 'EXTRAS_HASH=none' > .abx/uid-remap.env
  ABX_CLAUDE_MD=off run_abx -p hi
  assert_out_contains "Moved the derived-image state from .abx/"
  assert_file_contains "$(state_dir)/uid-remap.env" "OLD_UID=501"
  assert_no_file .abx/uid-remap.env
}

test_invalid_old_uid_remap_is_discarded() {
  mkdir -p .abx
  printf '%s\n' 'BASE=x; touch "$ABX_TEST_STATE/pwned"' 'USER_NAME=dev' 'OLD_UID=501' > .abx/uid-remap.env
  ABX_CLAUDE_MD=off run_abx -p hi
  assert_out_contains "Discarded .abx/uid-remap.env"
  assert_no_file .abx/uid-remap.env
  assert_no_file "$(state_dir)/uid-remap.env"
  assert_no_file "$ABX_TEST_STATE/pwned"
}

test_invalid_state_dir_uid_remap_is_discarded_on_rebuild() {
  run_abx -p hi
  mkdir -p "$(state_dir)"
  printf '%s\n' 'BASE=x; touch "$ABX_TEST_STATE/pwned"' 'USER_NAME=dev' 'OLD_UID=501' > "$(state_dir)/uid-remap.env"
  run_abx rebuild
  assert_out_contains "Discarded $(state_dir)/uid-remap.env"
  assert_no_file "$(state_dir)/uid-remap.env"
  assert_no_file "$ABX_TEST_STATE/pwned"
}

test_old_bedrock_profile_is_migrated_when_valid() {
  mkdir -p .abx && printf 'prof-1\n' > .abx/bedrock-profile
  run_abx -p hi
  assert_eq "$(cat "$(state_dir)/bedrock-profile")" "prof-1" "migrated profile"
  assert_no_file .abx/bedrock-profile
  assert_calls_contain "export-credentials --profile prof-1"
  assert_eq "$(settings_json "d['env']['CLAUDE_CODE_USE_BEDROCK']")" "1" "Bedrock stays on"
}

test_old_bedrock_profile_is_discarded_when_invalid() {
  mkdir -p .abx && printf '%s\n' 'x;touch "$ABX_TEST_STATE/pwned"' > .abx/bedrock-profile
  run_abx -p hi
  assert_out_contains "Discarded .abx/bedrock-profile"
  assert_no_file .abx/bedrock-profile
  assert_no_file "$(state_dir)/bedrock-profile"
  assert_eq "$(settings_json "'CLAUDE_CODE_USE_BEDROCK' in d.get('env', {})")" "False" "Bedrock stays off"
  assert_no_file "$ABX_TEST_STATE/pwned"
}

test_no_bedrock_also_removes_old_profile() {
  mkdir -p .abx && printf 'prof-1\n' > .abx/bedrock-profile
  run_abx --no-bedrock -p hi
  assert_no_file .abx/bedrock-profile
  assert_no_file "$(state_dir)/bedrock-profile"
}

test_existing_state_copy_wins_over_old_file() {
  mkdir -p .abx "$(state_dir)" && printf 'prof-1\n' > .abx/bedrock-profile && printf 'prof-2\n' > "$(state_dir)/bedrock-profile"
  run_abx -p hi
  assert_eq "$(cat "$(state_dir)/bedrock-profile")" "prof-2" "state copy kept"
  assert_no_file .abx/bedrock-profile
}

test_old_uid_ok_is_deleted_without_migration() {
  mkdir -p .abx && printf '1000\n' > .abx/uid-ok
  ABX_CLAUDE_MD=off run_abx -p hi
  assert_no_file .abx/uid-ok
  assert_file "$(state_dir)/uid-ok"
}

# The read-only .abx/ mount, so the agent can't write what the host reads or runs at container start.

abx_mount_lines() {
  grep -c 'target: /workspace/.abx  # abx: uid-remap' .agent-sandbox/compose/user.override.yml
}

test_abx_mount_is_added_to_agentbox_scaffold() {
  ABX_CLAUDE_MD=off run_abx -p hi
  assert_status 0
  local override=.agent-sandbox/compose/user.override.yml
  assert_file_contains "$override" "source: \"$(pwd -P)/.abx\"  # abx: uid-remap"
  assert_file_contains "$override" "target: /workspace/.abx  # abx: uid-remap"
  assert_file_contains "$override" "read_only: true  # abx: uid-remap"
  assert_file_contains "$override" "shell.d"
  assert_eq "$(abx_mount_lines)" "1" "one mount"
}

test_abx_mount_is_applied_again_without_duplicating() {
  ABX_CLAUDE_MD=off run_abx -p hi
  reset_calls
  ABX_CLAUDE_MD=off run_abx -p hi
  assert_eq "$(abx_mount_lines)" "1" "one mount after a second run"
  assert_calls_lack "docker rm -f"
}

test_abx_mount_is_added_to_override_without_volumes() {
  printf '%s\n' 'services:' '  agent:' '    environment:' '      FOO: bar' > "$ABX_TEST_STATE/override-scaffold"
  ABX_CLAUDE_MD=off run_abx -p hi
  assert_status 0
  assert_file_contains .agent-sandbox/compose/user.override.yml "    volumes:"
  assert_file_contains .agent-sandbox/compose/user.override.yml "FOO: bar"
  assert_eq "$(abx_mount_lines)" "1" "one mount"
}

test_abx_mount_is_restored_when_agentbox_ignores_it() {
  state override-ignored yes
  ABX_CLAUDE_MD=off run_abx -p hi
  assert_status 1
  assert_out_contains "didn't pick up the new mount"
  assert_file_lacks .agent-sandbox/compose/user.override.yml "abx: uid-remap"
  assert_file_contains .agent-sandbox/compose/user.override.yml "shell.d"
}

test_abx_mount_recreates_containers_only_when_added() {
  ABX_CLAUDE_MD=off run_abx -p hi
  printf '%s\n' 'services:' '  agent:' '    environment:' '      FOO: bar' > .agent-sandbox/compose/user.override.yml
  state agent-running yes
  reset_calls
  ABX_CLAUDE_MD=off run_abx -p hi
  assert_file_contains "$ABX_TEST_STATE/events" "removed ctr-agent"
  reset_calls
  ABX_CLAUDE_MD=off run_abx -p hi
  assert_eq "$(wc -l < "$ABX_TEST_STATE/events" | tr -d ' ')" "0" "no containers removed when nothing changed"
}
