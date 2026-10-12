# abx's own settings file, the statusline, sandbox instructions and legacy clean-up.

test_settings_empty_without_statusline_or_bedrock() {
  run_abx -p hi
  assert_eq "$(settings_json 'd')" "{}" "settings"
}

test_statusline_installed_only_from_config_directory() {
  run_abx -p hi
  assert_no_file .abx/statusline.sh
  assert_eq "$(settings_json "'statusLine' in d")" "False" "statusLine present"

  cp "$REPO_DIR/examples/statusline.sh" "$CONFIG/statusline.sh"
  run_abx -p hi
  cmp -s .abx/statusline.sh "$CONFIG/statusline.sh" || fail "statusline should be installed from the config directory"
  assert_eq "$(settings_json "d['statusLine']['command']")" "bash /workspace/.abx/statusline.sh" "statusLine command"

  rm "$CONFIG/statusline.sh"
  run_abx -p hi
  assert_no_file .abx/statusline.sh
  assert_eq "$(settings_json "'statusLine' in d")" "False" "statusLine present after removal"
}

test_statusline_changes_inside_sandbox_are_discarded() {
  cp "$REPO_DIR/examples/statusline.sh" "$CONFIG/statusline.sh"
  run_abx -p hi
  echo "echo tampered" >> .abx/statusline.sh
  run_abx -p hi
  assert_file_lacks .abx/statusline.sh "tampered"
}

test_settings_file_rewritten_every_run() {
  run_abx -p hi
  printf '{"hooks":{"PreToolUse":[]}}\n' > .abx/settings.json
  run_abx -p hi
  assert_eq "$(settings_json "'hooks' in d")" "False" "hooks survived"
}

test_legacy_keys_removed_from_project_settings() {
  mkdir -p .claude
  cat > .claude/settings.local.json <<'JSON'
{"permissions": {"allow": ["Bash(npm test)"]},
 "env": {"CLAUDE_CODE_USE_BEDROCK": "1", "AWS_REGION": "eu-west-1", "MY_VAR": "keep"},
 "awsCredentialExport": "cat .abx/aws-credentials.json",
 "statusLine": {"type": "command", "command": "sh -c 'exec bash .abx/statusline.sh'"}}
JSON
  run_abx -p hi
  local result
  result="$(python3 -c "import json; d=json.load(open('.claude/settings.local.json')); print(sorted(d), d['env'])")"
  assert_eq "$result" "['env', 'permissions'] {'MY_VAR': 'keep'}" "settings.local.json"
}

test_missing_instructions_file_is_reported() {
  mkdir -p "$T/partial"
  cp "$REPO_DIR/abx.sh" "$T/partial/abx.sh"
  cp -R "$REPO_DIR/lib" "$T/partial/lib"
  ln -sf "$T/partial/abx.sh" "$HOME/.local/bin/abx"
  run_abx -p hi
  assert_out_contains "resources/abx-CLAUDE.md is missing"
  ABX_CLAUDE_MD=off run_abx -p hi
  assert_out_lacks "is missing"
}

test_policy_command_supplies_an_editor() {
  run_abx -p hi
  if command -v sensible-editor >/dev/null || command -v editor >/dev/null || command -v nano >/dev/null \
     || command -v vim >/dev/null || command -v vi >/dev/null; then
    run_abx policy
    assert_status 0
    grep -q '^VISUAL=[^ ]' "$ABX_TEST_STATE/edit-policy" || fail "abx policy should set an editor"
  fi
  EDITOR=micro run_abx policy
  assert_eq "$(cat "$ABX_TEST_STATE/edit-policy")" "VISUAL= EDITOR=micro" "a configured editor is respected"
}
