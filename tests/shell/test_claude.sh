# Claude Code's configuration: the directory of skills, instructions and statusline mounted read-only in the sandbox and
# passed to Claude Code with --add-dir, and abx's own instructions used when the directory has no CLAUDE.md.

# A skill in the configuration directory, laid out as a .claude directory holds it.
claude_skill() {
  mkdir -p "$CONFIG/claude/skills/zebra"
  printf -- '---\nname: zebra\ndescription: Test skill\n---\nSay zebra.\n' > "$CONFIG/claude/skills/zebra/SKILL.md"
}

test_claude_directory_is_mounted_read_only_and_passed_to_claude() {
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
  assert_file_lacks "$override" "/opt/abx-default"
  assert_eq "$(exec_args | sed -n '/^--add-dir$/{n;p;}' | tr '\n' ' ')" "/opt/abx " "directories passed to --add-dir"
}

test_claude_directory_argument_comes_before_settings() {
  # --add-dir takes several values, so a prompt after it would be read as a directory. Settings only follow it.
  claude_skill
  run_abx marker-prompt
  assert_status 0
  assert_eq "$(exec_args | grep -n -x -e '--add-dir' -e '--settings' | cut -d: -f2 | tr '\n' ' ')" "--add-dir --add-dir --settings " "order of the flags"
  assert_eq "$(exec_args | tail -n1)" "marker-prompt" "the prompt is passed last"
}

test_abx_instructions_are_mounted_when_there_is_no_claude_md() {
  claude_skill
  local default override=.agent-sandbox/compose/user.override.yml
  default="$(cd "$REPO_DIR/resources/claude" && pwd -P)"
  run_abx -p hi
  assert_status 0
  assert_file_contains "$override" "target: /opt/abx-default/.claude  # abx: uid-remap"
  assert_file_contains "$override" "source: \"$default\"  # abx: uid-remap"
  assert_eq "$(exec_args | sed -n '/^--add-dir$/{n;p;}' | tr '\n' ' ')" "/opt/abx /opt/abx-default " "directories passed to --add-dir"
}

test_users_claude_md_replaces_abx_instructions() {
  mkdir -p "$CONFIG/claude"
  printf '# My rules\n' > "$CONFIG/claude/CLAUDE.md"
  run_abx -p hi
  assert_status 0
  assert_file_lacks .agent-sandbox/compose/user.override.yml "/opt/abx-default"
  assert_eq "$(exec_args | grep -c -x -e '--add-dir' || true)" "1" "--add-dir arguments"
}

test_settings_let_claude_read_claude_md_from_added_directories() {
  run_abx -p hi
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

test_claude_directory_off_mounts_nothing() {
  claude_skill
  ABX_CLAUDE_DIR=off run_abx -p hi
  assert_status 0
  assert_file_lacks .agent-sandbox/compose/user.override.yml "/opt/abx"
  assert_eq "$(exec_args | grep -c -x -e '--add-dir' || true)" "0" "--add-dir arguments"
}

test_claude_directory_can_be_chosen_by_environment() {
  mkdir -p "$T/team/skills/zebra"
  printf -- '---\nname: zebra\ndescription: Test skill\n---\n' > "$T/team/skills/zebra/SKILL.md"
  ABX_CLAUDE_DIR="$T/team" run_abx -p hi
  assert_status 0
  local source
  source="$(cd "$T/team" && pwd -P)"
  assert_file_contains .agent-sandbox/compose/user.override.yml "source: \"$source\"  # abx: uid-remap"
}

test_missing_claude_directory_is_reported_and_abx_instructions_still_apply() {
  ABX_CLAUDE_DIR="$T/nowhere" run_abx -p hi
  assert_status 0
  assert_out_contains "isn't a directory, so it isn't mounted"
  assert_file_contains .agent-sandbox/compose/user.override.yml "target: /opt/abx-default/.claude  # abx: uid-remap"
  assert_file_lacks .agent-sandbox/compose/user.override.yml "target: /opt/abx/.claude  "
}

test_relative_claude_directory_is_refused() {
  ABX_CLAUDE_DIR=claude run_abx -p hi
  assert_status 1
  assert_out_contains "ABX_CLAUDE_DIR must be an absolute path"
}

test_removing_claude_directory_unmounts_it_and_recreates_containers() {
  claude_skill
  run_abx -p hi
  assert_file_contains .agent-sandbox/compose/user.override.yml "target: /opt/abx/.claude  # abx: uid-remap"
  rm -rf "$CONFIG/claude"
  reset_calls
  run_abx -p hi
  assert_status 0
  assert_file_lacks .agent-sandbox/compose/user.override.yml "target: /opt/abx/.claude  "
  assert_file_contains .agent-sandbox/compose/user.override.yml "target: /opt/abx-default/.claude  # abx: uid-remap"
  assert_file_contains .agent-sandbox/compose/user.override.yml "target: /workspace/.abx  # abx: uid-remap"
  assert_file_contains .agent-sandbox/compose/user.override.yml "shell.d"
  assert_file_contains "$ABX_TEST_STATE/events" "removed ctr-agent"
}

test_claude_directory_is_kept_when_the_agent_gets_a_derived_image() {
  claude_skill
  state probe "501 dev readonly"
  run_abx -p hi
  assert_status 0
  local override=.agent-sandbox/compose/user.override.yml
  assert_file_contains "$override" "image: abx/agent-sandbox-claude-uid1000:latest  # abx: uid-remap"
  assert_file_contains "$override" "target: /opt/abx/.claude  # abx: uid-remap"
  assert_file_contains "$override" "target: /opt/abx-default/.claude  # abx: uid-remap"
  assert_file_contains "$override" "target: /workspace/.abx  # abx: uid-remap"
  assert_eq "$(exec_args | sed -n '/^--add-dir$/{n;p;}' | tr '\n' ' ')" "/opt/abx /opt/abx-default " "directories passed to --add-dir"
}

test_editing_instructions_does_not_rebuild_the_image() {
  state probe "501 dev readonly"
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
