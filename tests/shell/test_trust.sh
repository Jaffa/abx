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
