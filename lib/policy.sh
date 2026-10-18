# 'abx policy' and 'abx reload', and keeping the proxy's view of the policy files current.
#
# agentbox mounts each policy file into the proxy as a single-file bind mount. Docker pins such a mount to the file's
# inode as it was when the container started, so an editor that saves by writing a new file and renaming it over the
# old one (vim by default, most atomic-save editors) leaves the proxy reading the old content. SIGHUP re-renders the
# policy from those same mounts, so it reports 'applied' while changing nothing. Only a restart re-resolves the path.

POLICY_MOUNT_DIR=/etc/agent-sandbox/policy
# HOST_NAME:CONTAINER_NAME for each file agentbox mounts, under .agent-sandbox/policy/ and POLICY_MOUNT_DIR.
POLICY_MOUNT_PAIRS="user.policy.yaml:user.policy.yaml user.agent.claude.policy.yaml:user.agent.policy.yaml"
PROXY_START_TRIES=30

# The host names, one per line, of the policy files whose content the proxy container ID reads differently from the
# project's. A file the container can't read is skipped: it isn't mounted there, and a restart wouldn't help. The
# trailing 'x' keeps the final newline, which command substitution would otherwise drop from one side only.
_stale_policy_files() {
  local id="$1" pair file ours theirs
  for pair in $POLICY_MOUNT_PAIRS; do
    file="$PROJECT_DIR/.agent-sandbox/policy/${pair%%:*}"
    [ -f "$file" ] || continue
    ours="$(cat "$file" && echo x)" || continue
    theirs="$(docker exec "$id" cat "$POLICY_MOUNT_DIR/${pair#*:}" 2>/dev/null && echo x)" || true
    [ -n "$theirs" ] || continue
    if [ "$ours" != "$theirs" ]; then echo "${pair%%:*}"; fi
  done
  return 0
}

# Waits for the proxy container ID, just restarted, to pass its health check. A proxy whose policy fails to render
# exits at startup, which shows up here as it no longer running.
_wait_for_proxy() {
  local id="$1" name="$2" tries=0 running health
  while [ "$tries" -lt "$PROXY_START_TRIES" ]; do
    running="$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null || true)"
    health="$(docker inspect -f '{{.State.Health.Status}}' "$id" 2>/dev/null || true)"
    if [ "$running" = true ] && { [ "$health" = healthy ] || [ -z "$health" ]; }; then return 0; fi
    if [ "$running" != true ]; then break; fi
    tries=$((tries + 1))
    sleep 1
  done
  die "The proxy $name didn't come back up after the restart. Run 'abx logs' to see why; the sandbox has no network until it does."
}

# Restarts each running proxy this project owns that still reads an out-of-date policy file, then sets
# PROXY_RESTARTED. The policy is rendered on the host first: a proxy restarted with a policy that doesn't validate
# exits at startup, whereas SIGHUP would keep the last good policy, so an invalid file is left for the user to fix.
_sync_proxy_policy() {
  PROXY_RESTARTED=false
  local id name stale out
  while read -r id name; do
    [ -n "$id" ] || continue
    stale="$(_stale_policy_files "$id" | tr '\n' ' ' || true)"
    [ -n "$stale" ] || continue
    if ! out="$(agentbox policy config 2>&1)"; then
      die "The proxy $name is still running the previous policy, because an editor replaced ${stale% } and Docker keeps showing it the old file. abx didn't restart it, since the policy on disk is invalid: $(printf '%s' "$out" | LC_ALL=C tr -d '\000-\010\013-\037\177' | tail -n 3). Fix it with 'abx policy'."
    fi
    info "The proxy $name still reads the old ${stale% }: your editor replaced the file, and Docker keeps showing a running container the original. A reload can't fix that, so restarting the proxy."
    docker restart "$id" > "$ABX_STATE/proxy-restart.log" 2>&1 \
      || die "Couldn't restart the proxy $name, so it is still running the previous policy. See $ABX_STATE/proxy-restart.log."
    _wait_for_proxy "$id" "$name"
    if [ -n "$(_stale_policy_files "$id" || true)" ]; then
      die "The proxy $name restarted but still reads a different ${stale% } from the one in $PROJECT_DIR/.agent-sandbox/policy/. Check that the file is mounted from there with 'abx status'."
    fi
    info "Restarted $name; it is running the policy on disk."
    PROXY_RESTARTED=true
  done <<EOF
$(_owned_containers proxy running)
EOF
  return 0
}

# agentbox sends SIGHUP itself when the editor changed the file, so a stale mount is all that is left to fix.
_cmd_policy() {
  local status=0
  _ensure_editor
  agentbox edit policy || status=$?
  if [ "$status" -eq 0 ]; then _sync_proxy_policy; fi
  return "$status"
}

_cmd_reload() {
  _sync_proxy_policy
  if [ "$PROXY_RESTARTED" = true ]; then return 0; fi
  exec agentbox proxy reload
}
