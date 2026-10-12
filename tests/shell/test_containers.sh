# Container ownership and selection, derived-image labels and recovery, and 'abx clean'. Containers are seeded in the
# docker stub's table (tests/stubs/docker); a project's own containers are the ones in its .agent-sandbox/.

AGENT_IMAGE=ghcr.io/mattolson/agent-sandbox-claude:latest
DERIVED=abx/agent-sandbox-claude-uid1000:latest

# A project whose sandbox has started, with its Bedrock gateway and port forwarder, which are both abx's own.
started_project() {
  ABX_CLAUDE_MD=off run_abx -p hi
  sidecar_add "$GATEWAY"
  sidecar_add "$FORWARDER"
  volume_add p_claude-state "$PROJ_NAME"
  volume_add p_proxy-ca "$PROJ_NAME"
}

# ── which containers abx uses ──────────────────────────────────────────────────

test_newest_running_agent_is_used_and_older_ones_are_reported() {
  container_add ctr-old agent "$DERIVED" 2026-01-01T00:00:00Z
  container_add ctr-new agent "$AGENT_IMAGE" 2026-06-01T00:00:00Z
  state probe "501 dev readonly"
  ABX_CLAUDE_MD=off run_abx -p hi
  assert_status 0
  assert_out_contains "ctr-old"
  assert_out_contains "abx clean"
  assert_calls_contain "docker inspect -f {{.Config.Image}} ctr-new"
  assert_calls_contain "--build-arg BASE=$AGENT_IMAGE"
  assert_calls_lack "--build-arg BASE=$DERIVED"
}

test_container_named_for_this_project_in_another_directory_stops_abx() {
  container_add ctr-foreign agent "$AGENT_IMAGE" 2026-06-01T00:00:00Z true "$HOME/src/other/.agent-sandbox"
  state probe "501 dev readonly"
  ABX_CLAUDE_MD=off run_abx -p hi
  assert_status 1
  assert_out_contains "$HOME/src/other/.agent-sandbox"
  assert_out_contains "share"
  assert_out_contains "Rename"
  assert_calls_lack "docker rm"
  assert_calls_lack "docker network connect"
  assert_calls_lack "docker run --rm"
  assert_calls_lack "docker build"
}

test_working_dir_that_only_starts_like_the_sandbox_is_not_owned() {
  container_add ctr-lookalike agent "$AGENT_IMAGE" 2026-06-01T00:00:00Z true "$(project_dir)/.agent-sandbox-old"
  run_abx -p hi
  assert_status 1
  assert_out_contains ".agent-sandbox-old"
  assert_file_lacks "$ABX_TEST_STATE/events" "ctr-lookalike"
}

test_owned_containers_are_touched_and_foreign_ones_are_not() {
  container_add ctr-owned agent "$AGENT_IMAGE" 2026-01-01T00:00:00Z
  container_add ctr-foreign agent "$AGENT_IMAGE" 2026-06-01T00:00:00Z true "$HOME/src/other/.agent-sandbox"
  state probe "501 dev readonly"
  ABX_CLAUDE_MD=off run_abx -p hi
  assert_status 0
  assert_out_contains "other/.agent-sandbox"
  assert_file_contains "$ABX_TEST_STATE/events" "removed ctr-owned"
  assert_file_lacks "$ABX_TEST_STATE/events" "ctr-foreign"
  # The volumes may be shared with the other directory's containers, so they're left as they are.
  assert_calls_lack "docker run --rm"
}

test_foreign_gateway_with_the_same_name_is_left_alone() {
  sidecar_add "$GATEWAY" "$HOME/src/other"
  run_abx --bedrock -p hi
  assert_status 1
  assert_out_contains "belongs to another directory"
  assert_calls_lack "docker rm -f $GATEWAY"
  assert_calls_lack "docker run -d --name $GATEWAY"
  assert_file_lacks "$ABX_TEST_STATE/events" "removed $GATEWAY"
}

test_foreign_port_forwarder_with_the_same_name_is_left_alone() {
  sidecar_add "$FORWARDER" "$HOME/src/other"
  run_abx --ports=47190 -p hi
  assert_status 0
  assert_out_contains "belongs to another directory"
  assert_calls_lack "docker rm -f $FORWARDER"
  assert_calls_lack "docker run -d --name $FORWARDER"
  assert_calls_lack "docker network connect"
  assert_eq "$(settings_json "'env' in d")" "False" "no ports told to Claude"
}

# ── derived-image labels ───────────────────────────────────────────────────────

test_derived_image_is_labelled_when_built() {
  state probe "501 dev readonly"
  ABX_CLAUDE_MD=off run_abx -p hi
  assert_status 0
  assert_calls_contain "--label abx.base=$AGENT_IMAGE"
  assert_calls_contain "--label abx.user=dev"
  assert_calls_contain "--label abx.orig-user=dev"
  assert_calls_contain "--label abx.old-uid=501"
  assert_calls_contain "--label abx.target-uid=1000"
  assert_file_contains "$ABX_TEST_STATE/image-labels/abx_agent-sandbox-claude-uid1000_latest" "abx.base=$AGENT_IMAGE"
}

test_missing_record_is_recovered_from_the_image_labels() {
  image_add "$DERIVED" "abx.base=$AGENT_IMAGE" abx.user=dev abx.orig-user=dev abx.old-uid=501 abx.target-uid=1000
  container_add ctr-agent agent "$DERIVED" 2026-01-01T00:00:00Z
  state probe "501 dev readonly"
  ABX_CLAUDE_MD=off run_abx -p hi
  assert_status 0
  assert_out_contains "Recovered the derived-image record"
  assert_calls_contain "--build-arg BASE=$AGENT_IMAGE"
  assert_file_contains "$(state_dir)/uid-remap.env" "BASE=$AGENT_IMAGE"
  assert_file_contains "$(state_dir)/uid-remap.env" "TARGET_UID=1000"
}

test_derived_image_without_labels_is_refused() {
  image_add "$DERIVED"
  container_add ctr-agent agent "$DERIVED" 2026-01-01T00:00:00Z
  state probe "501 dev readonly"
  ABX_CLAUDE_MD=off run_abx -p hi
  assert_status 1
  assert_out_contains "abx clean"
  assert_calls_lack "docker build"
  assert_no_file "$(state_dir)/uid-remap.env"
}

test_derived_image_with_an_invalid_label_is_refused() {
  image_add "$DERIVED" "abx.base=$AGENT_IMAGE;rm -rf /" abx.user=dev abx.orig-user=dev abx.old-uid=501 abx.target-uid=1000
  container_add ctr-agent agent "$DERIVED" 2026-01-01T00:00:00Z
  state probe "501 dev readonly"
  ABX_CLAUDE_MD=off run_abx -p hi
  assert_status 1
  assert_out_contains "abx clean"
  assert_out_lacks "rm -rf"
  assert_calls_lack "docker build"
  assert_no_file "$(state_dir)/uid-remap.env"
}

# ── abx clean ──────────────────────────────────────────────────────────────────

test_clean_removes_owned_containers_and_sidecars_but_keeps_volumes() {
  started_project
  reset_calls
  ABX_CLAUDE_MD=off run_abx clean --yes
  assert_status 0
  assert_file_contains "$ABX_TEST_STATE/events" "removed ctr-agent"
  assert_file_contains "$ABX_TEST_STATE/events" "removed ctr-proxy"
  assert_file_contains "$ABX_TEST_STATE/events" "removed $GATEWAY"
  assert_file_contains "$ABX_TEST_STATE/events" "removed $FORWARDER"
  assert_file_contains "$ABX_TEST_STATE/events" "removed network p_default"
  assert_file_lacks "$ABX_TEST_STATE/events" "removed volume"
  assert_file "$PROJECT/.agent-sandbox/compose/user.override.yml"
  assert_file "$PROJECT/.abx/settings.json"
  assert_file "$(state_dir)"
}

test_clean_volumes_removes_the_project_volumes() {
  started_project
  reset_calls
  ABX_CLAUDE_MD=off run_abx clean --yes --volumes
  assert_status 0
  assert_file_contains "$ABX_TEST_STATE/events" "removed volume p_claude-state"
  assert_file_contains "$ABX_TEST_STATE/events" "removed volume p_proxy-ca"
}

test_clean_volumes_refuses_with_a_foreign_container_present() {
  started_project
  container_add ctr-foreign agent "$AGENT_IMAGE" 2026-06-01T00:00:00Z true "$HOME/src/other/.agent-sandbox"
  reset_calls
  ABX_CLAUDE_MD=off run_abx clean --yes --volumes
  assert_status 1
  assert_out_contains "other/.agent-sandbox"
  assert_eq "$(cat "$ABX_TEST_STATE/events")" "" "nothing removed"
}

test_clean_leaves_a_foreign_container_with_the_same_project_name_alone() {
  started_project
  container_add ctr-foreign agent "$AGENT_IMAGE" 2026-06-01T00:00:00Z true "$HOME/src/other/.agent-sandbox"
  reset_calls
  ABX_CLAUDE_MD=off run_abx clean --yes
  assert_status 0
  assert_file_contains "$ABX_TEST_STATE/events" "removed ctr-agent"
  assert_file_lacks "$ABX_TEST_STATE/events" "ctr-foreign"
}

test_clean_leaves_a_sidecar_that_belongs_to_another_directory() {
  ABX_CLAUDE_MD=off run_abx -p hi
  sidecar_add "$FORWARDER" "$HOME/src/other"
  reset_calls
  ABX_CLAUDE_MD=off run_abx clean --yes
  assert_status 0
  assert_file_contains "$ABX_TEST_STATE/events" "removed ctr-agent"
  assert_file_lacks "$ABX_TEST_STATE/events" "removed $FORWARDER"
}

test_clean_all_covers_every_agentbox_project() {
  started_project
  container_add other-agent agent ghcr.io/mattolson/agent-sandbox-claude:0.9.0 2025-01-01T00:00:00Z true \
    "$HOME/src/other/.agent-sandbox" other
  container_add legacy-agent agent "$DERIVED" 2025-06-01T00:00:00Z true "$HOME/src/legacy/.agent-sandbox" legacy
  container_add webapp web nginx:latest 2026-01-01T00:00:00Z true "$HOME/src/webapp" webapp
  sidecar_add abx-ports-legacy "$HOME/src/legacy"
  network_add legacy_default legacy
  volume_add other_claude-state other
  volume_add legacy_proxy-ca legacy
  volume_add webapp_data webapp
  image_add "$DERIVED"
  image_add "$AGENT_IMAGE"
  reset_calls
  ABX_CLAUDE_MD=off run_abx clean --all --yes --volumes --images
  assert_status 0
  assert_file_contains "$ABX_TEST_STATE/events" "removed other-agent"
  assert_file_contains "$ABX_TEST_STATE/events" "removed legacy-agent"
  assert_file_contains "$ABX_TEST_STATE/events" "removed abx-ports-legacy"
  assert_file_contains "$ABX_TEST_STATE/events" "removed network legacy_default"
  assert_file_contains "$ABX_TEST_STATE/events" "removed volume other_claude-state"
  assert_file_contains "$ABX_TEST_STATE/events" "removed volume legacy_proxy-ca"
  assert_file_contains "$ABX_TEST_STATE/events" "removed image $DERIVED"
  assert_file_contains "$ABX_TEST_STATE/events" "pruned images"
  assert_file_lacks "$ABX_TEST_STATE/events" "removed webapp"
  assert_file_lacks "$ABX_TEST_STATE/events" "removed volume webapp_data"
  assert_file_lacks "$ABX_TEST_STATE/events" "removed image $AGENT_IMAGE"
  assert_calls_lack "ancestor="
}

test_clean_dry_run_removes_nothing() {
  started_project
  reset_calls
  ABX_CLAUDE_MD=off run_abx clean --dry-run --all --volumes --images
  assert_status 0
  assert_out_contains "ctr-agent"
  assert_out_contains "Dry run"
  assert_eq "$(cat "$ABX_TEST_STATE/events")" "" "nothing removed"
}

test_clean_without_yes_on_non_interactive_input_removes_nothing() {
  started_project
  reset_calls
  ABX_CLAUDE_MD=off run_abx clean
  assert_status 1
  assert_out_contains "ctr-agent"
  assert_out_contains "--yes"
  assert_eq "$(cat "$ABX_TEST_STATE/events")" "" "nothing removed"
}

test_clean_images_needs_all() {
  started_project
  ABX_CLAUDE_MD=off run_abx clean --images --yes
  assert_status 1
  assert_out_contains "needs --all"
}

test_clean_warns_about_a_running_session() {
  started_project
  mkdir -p "$XDG_RUNTIME_DIR/abx/$PROJ_NAME/sessions" && touch "$XDG_RUNTIME_DIR/abx/$PROJ_NAME/sessions/$$"
  ABX_CLAUDE_MD=off run_abx clean --dry-run
  assert_status 0
  assert_out_contains "session"
}
