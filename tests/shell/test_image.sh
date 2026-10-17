# The write probe, UID remapping, derived image, override merging and recovery paths.

test_writable_project_without_additions_builds_nothing() {
  ABX_CLAUDE_DIR=off run_abx -p hi
  assert_status 0
  assert_calls_lack "docker build"
  assert_eq "$(cat "$(state_dir)/uid-ok")" "1000 100" "uid marker"
}

test_uid_mismatch_remaps_user_and_reowns_agent_only_volumes() {
  state probe "501 dev 501 readonly"
  ABX_CLAUDE_DIR=off run_abx -p hi
  assert_status 0
  assert_out_contains "The agent runs as UID 501 but your files belong to UID 1000"
  assert_out_contains "Done: the agent will run as UID 1000"
  assert_calls_contain "HOST_UID=1000"
  assert_file_contains .agent-sandbox/compose/user.override.yml "image: abx/agent-sandbox-claude-uid1000:latest  # abx: uid-remap"
  assert_file_contains .agent-sandbox/compose/user.override.yml "pull_policy: never  # abx: uid-remap"
  assert_file_contains .agent-sandbox/compose/user.override.yml "shell.d"
  assert_eq "$(sort "$ABX_TEST_STATE/reowned" | tr '\n' ' ')" "p_claude-history p_claude-state " "re-owned volumes"
  assert_file_contains "$(state_dir)/uid-remap.env" "OLD_UID=501"
  assert_file_contains "$(state_dir)/uid-remap.env" "TARGET_UID=1000"
}

test_remapped_dockerfile_restores_original_user() {
  state probe "501 dev 501 readonly"
  state image-user dev
  ABX_CLAUDE_DIR=off run_abx -p hi
  local dockerfile="$ABX_TEST_STATE/built/abx_agent-sandbox-claude-uid1000_latest.Dockerfile"
  assert_file_contains "$dockerfile" 'usermod -u "${HOST_UID}" "${USER_NAME}"'
  [ "$(tail -n1 "$dockerfile")" = 'USER ${ORIG_USER}' ] || fail "the Dockerfile should end by restoring the original user"
  assert_calls_contain "ORIG_USER=dev"
}

test_override_with_users_own_image_is_left_alone() {
  printf 'services:\n  agent:\n    image: my/own:image\n' > "$ABX_TEST_STATE/override-scaffold"
  state probe "501 dev 501 readonly"
  ABX_CLAUDE_DIR=off run_abx -p hi
  assert_status 1
  assert_out_contains "already sets the agent's image or build"
  assert_eq "$(cat .agent-sandbox/compose/user.override.yml)" "$(cat "$ABX_TEST_STATE/override-scaffold")" "override"
}

test_override_restored_when_agentbox_ignores_it() {
  state probe "501 dev 501 readonly"
  state override-ignored yes
  ABX_CLAUDE_DIR=off run_abx -p hi
  assert_status 1
  assert_out_contains "didn't pick up the new image"
  assert_file_lacks .agent-sandbox/compose/user.override.yml "abx: uid-remap"
  assert_file_contains .agent-sandbox/compose/user.override.yml "shell.d"
}

test_instructions_are_mounted_not_baked_into_the_image() {
  state probe "501 dev 501 readonly"
  run_abx -p hi
  assert_out_contains "Building abx/agent-sandbox-claude-uid1000:latest"
  local built="$ABX_TEST_STATE/built/abx_agent-sandbox-claude-uid1000_latest"
  assert_file_lacks "$built.Dockerfile" "/etc/claude-code"

  mkdir -p "$CONFIG/claude"
  printf '# My own sandbox rules\n' > "$CONFIG/claude/CLAUDE.md"
  reset_calls; run_abx -p hi
  assert_status 0
  assert_calls_lack "docker build"
  assert_file_contains .agent-sandbox/compose/user.override.yml "target: /opt/abx/.claude  # abx: uid-remap"
}

test_generated_build_contexts_are_cached_outside_the_configuration() {
  state probe "501 dev 501 readonly"
  ABX_CLAUDE_DIR=off run_abx -p hi
  assert_file "$XDG_CACHE_HOME/abx/uid-remap/Dockerfile"
  assert_no_file "$CONFIG/uid-remap"
}

test_image_extras_can_be_turned_off() {
  printf 'RUN echo extra-marker\n' > "$CONFIG/Dockerfile.extra"
  state probe "501 dev 501 readonly"
  ABX_IMAGE_EXTRAS=off run_abx -p hi
  assert_status 0
  local dockerfile="$ABX_TEST_STATE/built/abx_agent-sandbox-claude-uid1000_latest.Dockerfile"
  assert_file_lacks "$dockerfile" "extra-marker"
}

test_image_extras_come_only_from_config_directory() {
  run_abx -p hi
  local dockerfile="$ABX_TEST_STATE/built/abx_agent-sandbox-claude-uid1000_latest.Dockerfile"
  assert_file_lacks "$dockerfile" "Image extras"
  printf 'RUN echo extra-marker\n' > "$CONFIG/Dockerfile.extra"
  run_abx -p hi
  assert_out_contains "with abx additions"
  assert_file_contains "$dockerfile" "RUN echo extra-marker"
  [ "$(tail -n1 "$dockerfile")" = 'USER ${ORIG_USER}' ] || fail "extras must come before the user is restored"

  printf 'RUN echo second-marker\n' > "$CONFIG/Dockerfile.extra"
  run_abx -p hi
  assert_out_contains "record of the image extras is out of date; rebuilding"
  assert_file_contains "$dockerfile" "RUN echo second-marker"
}

test_old_state_file_does_not_trigger_rebuild() {
  ABX_CLAUDE_DIR=off run_abx -p hi
  printf 'BASE=ghcr.io/mattolson/agent-sandbox-claude:latest\nUSER_NAME=dev\nORIG_USER=\nOLD_UID=501\n' > .abx/uid-remap.env
  reset_calls
  ABX_CLAUDE_DIR=off run_abx -p hi
  assert_calls_lack "docker build"
}

test_rebuild_pulls_and_keeps_uid_fix() {
  state probe "501 dev 501 readonly"
  ABX_CLAUDE_DIR=off run_abx -p hi
  reset_calls
  ABX_CLAUDE_DIR=off run_abx rebuild
  assert_status 0
  assert_calls_contain "docker build --pull"
  assert_calls_contain "HOST_UID=1000"
}

test_stale_containers_are_recreated() {
  container_add ctr-agent
  state stale yes
  run_abx -p hi
  assert_status 0
  assert_out_contains "predate this directory"
  assert_file_contains "$ABX_TEST_STATE/events" "removed ctr-agent"
}

test_unexpected_probe_output_is_reported() {
  state probe "something unexpected"
  run_abx -p hi
  assert_status 1
  assert_out_contains "Couldn't check whether the agent can write"
  assert_out_contains "something unexpected"
  assert_file "$(state_dir)/probe.log"
}

test_build_failure_is_reported_with_log() {
  state probe "501 dev 501 readonly"
  state build-fails yes
  ABX_CLAUDE_DIR=off run_abx -p hi
  assert_status 1
  assert_out_contains "build failed: example"
  assert_out_contains "$(state_dir)/build.log"
}

test_uid_remap_also_renumbers_the_agent_group() {
  state probe "501 dev 501 readonly"
  ABX_CLAUDE_DIR=off run_abx -p hi
  assert_status 0
  local dockerfile="$ABX_TEST_STATE/built/abx_agent-sandbox-claude-uid1000_latest.Dockerfile"
  assert_calls_contain "HOST_GID=100"
  assert_file_contains "$dockerfile" 'groupmod -g "${HOST_GID}" "$group"'
  assert_file_contains "$dockerfile" 'usermod -g "$group" "${USER_NAME}"'
  assert_file_contains "$dockerfile" 'find / -xdev -gid "${old_gid}" -exec chgrp -h "${HOST_GID}" {} +'
  assert_file_contains "$(state_dir)/uid-remap.env" "OLD_GID=501"
  assert_file_contains "$(state_dir)/uid-remap.env" "TARGET_GID=100"
  assert_eq "$(cat "$(state_dir)/uid-ok")" "1000 100" "uid marker"
  # The volumes are re-owned from the old UID and group to the new ones.
  assert_calls_contain "sh 501 1000 501 100"
}

test_group_colliding_with_the_host_gid_is_moved_aside() {
  state probe "501 dev 501 readonly"
  ABX_CLAUDE_DIR=off run_abx -p hi
  local dockerfile="$ABX_TEST_STATE/built/abx_agent-sandbox-claude-uid1000_latest.Dockerfile"
  assert_file_contains "$dockerfile" 'groupmod -g 59999 "$other"'
  assert_file_contains "$dockerfile" 'usermod -g "$other" "$u"'
}

test_group_is_left_alone_when_the_uid_already_matches() {
  # A macOS host: its UID matches and its group isn't 501, but the file sharing hides that, so nothing is renumbered.
  state uid 501
  state probe "501 dev 20 writable"
  run_abx -p hi
  assert_status 0
  assert_calls_lack "docker build"
  assert_eq "$(cat "$(state_dir)/uid-ok")" "501 100" "uid marker"
}

test_derived_image_from_before_the_group_was_renumbered_is_realigned() {
  state probe "501 dev 501 readonly"
  ABX_CLAUDE_DIR=off run_abx -p hi
  assert_file_contains .agent-sandbox/compose/user.override.yml "image: abx/agent-sandbox-claude-uid1000:latest  # abx: uid-remap"
  # The record from before the group was renumbered has no group keys, and the agent runs the derived image.
  printf 'BASE=ghcr.io/mattolson/agent-sandbox-claude:latest\nUSER_NAME=dev\nORIG_USER=\nOLD_UID=501\nTARGET_UID=1000\nEXTRAS_HASH=none\n' \
    > "$(state_dir)/uid-remap.env"
  printf '1000\n' > "$(state_dir)/uid-ok"
  state probe-remapped "1000 dev 501 writable"
  reset_calls
  ABX_CLAUDE_DIR=off run_abx -p hi
  assert_status 0
  assert_calls_contain "docker build"
  assert_calls_contain "sh 1000 1000 501 100"
  assert_file_contains "$(state_dir)/uid-remap.env" "OLD_GID=501"
  assert_file_contains "$(state_dir)/uid-remap.env" "TARGET_GID=100"
  assert_eq "$(cat "$(state_dir)/uid-ok")" "1000 100" "uid marker"
}
