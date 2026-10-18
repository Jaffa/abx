# Claude Code's configuration: abx's base instructions, always appended to the system prompt, and the user's directory,
# mounted read-only in the sandbox and passed to Claude Code with --add-dir.

# A skill in the configuration directory, laid out as a .claude directory holds it.
claude_skill() {
  mkdir -p "$CONFIG/claude/skills/zebra"
  printf -- '---\nname: zebra\ndescription: Test skill\n---\nSay zebra.\n' > "$CONFIG/claude/skills/zebra/SKILL.md"
}

test_user_directory_is_mounted_read_only_and_passed_to_claude() {
  claude_skill
  printf '# My rules\n' > "$CONFIG/claude/CLAUDE.md"
  local source override=.agent-sandbox/compose/user.override.yml
  source="$(cd "$CONFIG/claude" && pwd -P)"
  run_abx -p hi
  assert_status 0
  assert_file_contains "$override" "target: /opt/abx/.claude  # abx: uid-remap"
  assert_file_contains "$override" "source: \"$source\"  # abx: uid-remap"
  assert_file_contains "$override" "target: /workspace/.abx  # abx: uid-remap"
  assert_file_contains "$override" "shell.d"
  assert_eq "$(exec_args | sed -n '/^--add-dir$/{n;p;}' | tr '\n' ' ')" "/opt/abx " "directories passed to --add-dir"
}

test_user_directory_argument_comes_before_settings() {
  # --add-dir takes several values, so a prompt after it would be read as a directory. Settings only follow it.
  claude_skill
  run_abx marker-prompt
  assert_status 0
  assert_eq "$(exec_args | grep -n -x -e '--add-dir' -e '--settings' | cut -d: -f2 | tr '\n' ' ')" "--add-dir --settings " "order of the flags"
  assert_eq "$(exec_args | tail -n1)" "marker-prompt" "the prompt is passed last"
}

# The instructions go inline: Claude Code counts --append-system-prompt-file as a restriction a restart can't carry over,
# which stops /tui switching renderers.
assert_instructions_appended() {
  local args
  args="$(exec_args)"
  assert_eq "$(printf '%s\n' "$args" | grep -c -x -e '--append-system-prompt-file' || true)" "0" "--append-system-prompt-file arguments"
  assert_eq "$(printf '%s\n' "$args" | grep -c -x -e '--append-system-prompt' || true)" "1" "--append-system-prompt arguments"
  [[ "$args" == *"$(cat "$REPO_DIR/resources/claude/CLAUDE.md")"* ]] || fail "the instructions are missing from the arguments"
}

test_abx_instructions_are_always_appended_to_the_system_prompt() {
  run_abx -p hi
  assert_status 0
  assert_file_lacks .agent-sandbox/compose/user.override.yml "/opt/abx-base"
  assert_instructions_appended
  assert_eq "$(exec_args | grep -c -x -e '--add-dir' || true)" "0" "--add-dir arguments"
}

test_user_claude_md_is_read_alongside_abx_instructions() {
  mkdir -p "$CONFIG/claude"
  printf '# My rules\n' > "$CONFIG/claude/CLAUDE.md"
  run_abx -p hi
  assert_status 0
  assert_instructions_appended
  assert_eq "$(exec_args | sed -n '/^--add-dir$/{n;p;}')" "/opt/abx" "directory passed to --add-dir"
  assert_eq "$(settings_json "d['env']['CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD']")" "1" "environment variable"
}

test_statusline_comes_from_the_claude_directory_and_is_not_copied() {
  mkdir -p "$CONFIG/claude"
  cp "$REPO_DIR/examples/statusline.sh" "$CONFIG/claude/statusline.sh"
  run_abx -p hi
  assert_status 0
  assert_no_file .abx/statusline.sh
  assert_eq "$(settings_json "d['statusLine']['command']")" "bash /opt/abx/.claude/statusline.sh" "statusLine command"

  rm "$CONFIG/claude/statusline.sh"
  run_abx -p hi
  assert_eq "$(settings_json "'statusLine' in d")" "False" "statusLine present after removal"
}

test_user_directory_off_keeps_abx_instructions() {
  claude_skill
  ABX_CLAUDE_DIR=off run_abx -p hi
  assert_status 0
  assert_file_lacks .agent-sandbox/compose/user.override.yml "/opt/abx/.claude"
  assert_eq "$(exec_args | grep -c -x -e '--add-dir' || true)" "0" "--add-dir arguments"
  assert_instructions_appended
}

test_user_directory_can_be_chosen_by_environment() {
  mkdir -p "$T/team/skills/zebra"
  printf -- '---\nname: zebra\ndescription: Test skill\n---\n' > "$T/team/skills/zebra/SKILL.md"
  ABX_CLAUDE_DIR="$T/team" run_abx -p hi
  assert_status 0
  local source
  source="$(cd "$T/team" && pwd -P)"
  assert_file_contains .agent-sandbox/compose/user.override.yml "source: \"$source\"  # abx: uid-remap"
}

test_missing_user_directory_is_reported_and_abx_instructions_still_apply() {
  ABX_CLAUDE_DIR="$T/nowhere" run_abx -p hi
  assert_status 0
  assert_out_contains "isn't a directory, so it isn't mounted"
  assert_file_lacks .agent-sandbox/compose/user.override.yml "target: /opt/abx/.claude  "
}

test_relative_user_directory_is_refused() {
  ABX_CLAUDE_DIR=claude run_abx -p hi
  assert_status 1
  assert_out_contains "ABX_CLAUDE_DIR must be an absolute path"
}

test_removing_user_directory_unmounts_it_and_recreates_containers() {
  claude_skill
  run_abx -p hi
  assert_file_contains .agent-sandbox/compose/user.override.yml "target: /opt/abx/.claude  # abx: uid-remap"
  rm -rf "$CONFIG/claude"
  reset_calls
  run_abx -p hi
  assert_status 0
  assert_file_lacks .agent-sandbox/compose/user.override.yml "target: /opt/abx/.claude  "
  assert_file_contains .agent-sandbox/compose/user.override.yml "target: /workspace/.abx  # abx: uid-remap"
  assert_file_contains .agent-sandbox/compose/user.override.yml "shell.d"
  assert_eq "$(exec_args | grep -c -x -e '--add-dir' || true)" "0" "--add-dir arguments"
  assert_file_contains "$ABX_TEST_STATE/events" "removed ctr-agent"
}

test_claude_configuration_is_kept_when_the_agent_gets_a_derived_image() {
  claude_skill
  state probe "501 dev 501 readonly"
  run_abx -p hi
  assert_status 0
  local override=.agent-sandbox/compose/user.override.yml
  assert_file_contains "$override" "image: abx/agent-sandbox-claude-uid1000:latest  # abx: uid-remap"
  assert_file_contains "$override" "target: /opt/abx/.claude  # abx: uid-remap"
  assert_file_contains "$override" "target: /workspace/.abx  # abx: uid-remap"
  assert_eq "$(exec_args | sed -n '/^--add-dir$/{n;p;}' | tr '\n' ' ')" "/opt/abx " "directories passed to --add-dir"
  assert_instructions_appended
}

test_editing_instructions_does_not_rebuild_the_image() {
  state probe "501 dev 501 readonly"
  run_abx -p hi
  mkdir -p "$CONFIG/claude"
  printf '# First version\n' > "$CONFIG/claude/CLAUDE.md"
  run_abx -p hi
  reset_calls
  printf '# Second version\n' > "$CONFIG/claude/CLAUDE.md"
  run_abx -p hi
  assert_status 0
  assert_calls_lack "docker build"
  assert_out_lacks "rebuilding"
}

test_agentbox_ignoring_the_claude_mount_is_reported_with_a_snippet() {
  claude_skill
  state override-ignored yes
  run_abx -p hi
  assert_status 1
  assert_out_contains "didn't pick up the new mount"
  assert_out_contains "target: /opt/abx/.claude"
  assert_file_lacks .agent-sandbox/compose/user.override.yml "abx: uid-remap"
}

# The proxy and allowlist are explained by the upstream skill, which every agentbox image ships. The instructions point
# to it and keep only what abx adds: the command that allows a host, and the published ports.
test_instructions_leave_the_proxy_detail_to_the_upstream_skill() {
  local file="$REPO_DIR/resources/claude/CLAUDE.md"
  assert_file_contains "$file" "operating-in-agent-sandbox"
  assert_file_contains "$file" "abx policy"
  assert_file_contains "$file" "ABX_PUBLISHED_PORTS"
  assert_file_lacks "$file" "/run/agentbox/policy.yaml"
  assert_file_lacks "$file" "HTTP 403"
}
