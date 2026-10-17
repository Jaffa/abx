# Project discovery, initialisation, safety refusals and argument handling.

test_refuses_home_directory() {
  cd "$HOME" && run_abx -p hi
  assert_status 1
  assert_out_contains "Refusing to sandbox"
}

test_refuses_root_unless_allowed() {
  state uid 0
  run_abx -p hi
  assert_status 1
  assert_out_contains "Don't run abx as root"
  ABX_ALLOW_ROOT=true run_abx -p hi
  assert_status 0
}

test_reports_docker_permission_problem() {
  state docker-info permission
  run_abx -p hi
  assert_status 1
  assert_out_contains "No permission to use the Docker socket"
  assert_out_contains "don't run abx with sudo"
}

test_reports_docker_daemon_down() {
  state docker-info down
  run_abx -p hi
  assert_status 1
  assert_out_contains "The Docker daemon is not reachable"
}

test_first_run_initialises_with_template_policy() {
  run_abx -p hi
  assert_status 0
  assert_calls_contain "agentbox init --agent claude --mode cli --name $PROJ_NAME"
  assert_out_contains "Applied $ABX_TEMPLATE_DIR/user.policy.yaml"
  assert_file_contains .agent-sandbox/policy/user.policy.yaml "docs.example.com"
  assert_file_contains .agent-sandbox/policy/user.policy.yaml.generated "generated.example.com"
}

test_invalid_template_keeps_generated_policy() {
  printf 'services:\n  - name: github\n  - INVALID\n' > "$ABX_TEMPLATE_DIR/user.policy.yaml"
  run_abx -p hi
  assert_status 0
  assert_out_contains "agentbox rejected the policy template"
  assert_out_contains "must contain 'name'"
  assert_file_contains .agent-sandbox/policy/user.policy.yaml "generated.example.com"
}

test_without_template_keeps_agentbox_policy() {
  rm -f "$ABX_TEMPLATE_DIR/user.policy.yaml"
  run_abx -p hi
  assert_status 0
  assert_no_file "$ABX_TEMPLATE_DIR/user.policy.yaml"
  assert_file_contains .agent-sandbox/policy/user.policy.yaml "generated.example.com"
  assert_no_file .agent-sandbox/policy/user.policy.yaml.generated
}

test_excludes_abx_files_from_git_without_gitignore() {
  run_abx -p hi
  assert_file_contains .git/info/exclude ".agent-sandbox/"
  assert_file_contains .git/info/exclude ".abx/"
  assert_file_contains .git/info/exclude ".pnpm-store/"
  assert_no_file .gitignore
}

test_subdirectory_of_plain_project_reuses_its_sandbox() {
  new_project plainproj plain
  run_abx -p hi
  mkdir -p foo && cd foo && reset_calls
  run_abx -p hi
  assert_status 0
  assert_calls_lack "agentbox init"
  assert_out_contains "Project: $PROJECT (starting in foo)"
  exec_args | grep -qx "/workspace/foo" || fail "Claude should start in /workspace/foo"
}

test_nested_git_repository_uses_outer_sandbox() {
  run_abx -p hi
  mkdir -p vendor/dep && (cd vendor/dep && git init -q .) && cd vendor/dep
  run_abx -p hi
  assert_out_contains "Project: $PROJECT (starting in vendor/dep)"
}

test_git_subdirectory_initialises_at_repository_root() {
  mkdir -p src && cd src
  run_abx -p hi
  assert_file "$PROJECT/.agent-sandbox"
  assert_no_file "$PROJECT/src/.agent-sandbox"
}

test_claude_arguments_pass_through_unchanged() {
  run_abx --continue -p 'make it "retro" for $5'
  local expected
  expected="$(printf '%s\n' sh -c 'cd "$1" && shift && exec claude "$@"' abx /workspace --append-system-prompt-file /opt/abx-base/CLAUDE.md --settings /workspace/.abx/settings.json --continue -p 'make it "retro" for $5')"
  assert_eq "$(exec_args)" "$expected" "agentbox exec arguments"
}

test_double_dash_passes_subcommand_names_to_claude() {
  run_abx -- shell
  exec_args | tail -n1 | grep -qx shell || fail "'shell' should reach claude as an argument"
}

test_shell_starts_in_subdirectory() {
  run_abx -p hi
  mkdir -p sub && cd sub
  run_abx shell
  local expected
  expected="$(printf '%s\n' sh -c 'cd "$1" && exec "${SHELL:-/bin/sh}" -l' abx /workspace/sub)"
  assert_eq "$(exec_args)" "$expected" "shell arguments"
}

test_records_project_name_for_statusline() {
  run_abx -p hi
  assert_eq "$(cat .abx/project-name)" "proj" "project name"
}

test_new_project_name_is_its_directory_name_and_a_hash_of_its_path() {
  run_abx -p hi
  assert_status 0
  local shape='^proj-[0-9a-f]{8}$'
  [[ "$PROJ_NAME" =~ $shape ]] || fail "name should be proj- and eight hex digits: $PROJ_NAME"
  assert_calls_contain "--name $PROJ_NAME"
  assert_file_contains "$(state_dir)/project-name" "$PROJ_NAME"
}

test_same_named_directories_get_different_names() {
  run_abx -p hi
  local first="$PROJ_NAME" elsewhere="$HOME/elsewhere/proj" second
  mkdir -p "$elsewhere" && cd "$elsewhere" && git init -q .
  second="$(compose_name "$elsewhere")"
  reset_calls
  run_abx -p hi
  assert_status 0
  [ "$first" != "$second" ] || fail "two directories named proj got the same name"
  assert_calls_contain "agentbox init --agent claude --mode cli --name $second"
}

test_existing_sandbox_keeps_its_directory_name() {
  mkdir -p .agent-sandbox
  run_abx --ports=47210 -p hi
  assert_status 0
  assert_calls_contain "docker run -d --name abx-ports-proj "
}

test_recorded_project_name_is_kept() {
  mkdir -p "$(state_dir)" && printf 'proj-cafe0000\n' > "$(state_dir)/project-name"
  run_abx -p hi
  assert_status 0
  assert_calls_contain "agentbox init --agent claude --mode cli --name proj-cafe0000"
}
