# Settings for Claude Code: .abx/settings.json, which is passed with --settings. Also the project name the sandbox reads,
# and the clean-up of files and keys that earlier versions wrote.

CLAUDE_LOCAL_SETTINGS=".claude/settings.local.json"

# Earlier versions copied the statusline into .abx/, and kept their keys in .claude/settings.local.json. Remove only what
# they wrote: the copy, and those keys.
_remove_legacy_files() {
  rm -f "$ABX_DIR/statusline.sh"
  [ -f "$CLAUDE_LOCAL_SETTINGS" ] && grep -q '\.abx/' "$CLAUDE_LOCAL_SETTINGS" || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -I "$ABX_HOME/lib/clean_legacy_settings.py" "$CLAUDE_LOCAL_SETTINGS" || echo "[warning] Could not tidy abx's old keys from $CLAUDE_LOCAL_SETTINGS" >&2
}

# Inside the sandbox the project is always /workspace; the statusline reads its real name from here.
_record_project_name() {
  mkdir -p "$ABX_DIR"
  _exclude_path "$ABX_DIR/"
  # pnpm keeps its store on the same filesystem as the project, which in the sandbox is /workspace.
  _exclude_path '.pnpm-store/'
  printf '%s\n' "$(basename "$PROJECT_DIR")" > "$ABX_DIR/project-name"
}

# Derived from ABX_DIR, so this is set once the project is known rather than on sourcing.
_settings_init_vars() {
  ABX_SETTINGS="$ABX_DIR/settings.json"
}

# Rewritten on every run from abx's own state, so edits made inside the sandbox don't persist.
_write_abx_settings() {
  command -v python3 >/dev/null 2>&1 || die "python3 is needed to write $ABX_SETTINGS"
  local ports="" outbound=""
  if [ "$PORTS_OWNED" = true ] || _owned_sidecar_running "$PORTS_CONTAINER"; then
    ports="$PORTS_SPEC"
  fi
  if [ -n "$OUTBOUND_SPECS" ] && { [ "$OUTBOUND_OWNED" = true ] || _owned_sidecar_running "$OUTBOUND_CONTAINER"; }; then
    outbound="$OUTBOUND_SPECS"
  fi
  python3 -I "$ABX_HOME/lib/write_settings.py" "$ABX_SETTINGS" "$STATUSLINE_COMMAND" "$BEDROCK_ENABLED" "$BEDROCK_REGION" "$ports" \
    "http://$GATEWAY_ALIAS:$GATEWAY_PORT" "$GATEWAY_NO_PROXY" "$outbound"
}
