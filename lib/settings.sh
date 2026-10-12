# Settings for Claude Code: the statusline abx installs, and .abx/settings.json, which is passed with
# --settings. Also the project name the sandbox reads, and the clean-up of keys that earlier versions wrote.

CLAUDE_LOCAL_SETTINGS=".claude/settings.local.json"

# Earlier versions of abx kept their keys in .claude/settings.local.json; remove only those keys.
_remove_legacy_settings() {
  [ -f "$CLAUDE_LOCAL_SETTINGS" ] && grep -q '\.abx/' "$CLAUDE_LOCAL_SETTINGS" || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$CLAUDE_LOCAL_SETTINGS" <<'PY' || echo "[warning] Could not tidy abx's old keys from $CLAUDE_LOCAL_SETTINGS" >&2
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
if data.get("awsCredentialExport") == "cat .abx/aws-credentials.json":
    del data["awsCredentialExport"]
    env = data.get("env", {})
    for key in ("CLAUDE_CODE_USE_BEDROCK", "AWS_REGION"):
        env.pop(key, None)
    if not env:
        data.pop("env", None)
status = data.get("statusLine")
if isinstance(status, dict) and ".abx/statusline.sh" in str(status.get("command", "")):
    del data["statusLine"]
with open(path + ".tmp", "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(path + ".tmp", path)
PY
}

# Inside the sandbox the project is always /workspace; the statusline reads its real name from here.
_record_project_name() {
  mkdir -p "$ABX_DIR"
  _exclude_path "$ABX_DIR/"
  # pnpm keeps its store on the same filesystem as the project, which in the sandbox is /workspace.
  _exclude_path '.pnpm-store/'
  printf '%s\n' "$(basename "$PROJECT_DIR")" > "$ABX_DIR/project-name"
}

_statusline_template() {
  local candidate
  for candidate in "${ABX_STATUSLINE:-}" "$ABX_CONFIG_DIR/statusline.sh"; do
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then printf '%s' "$candidate"; return 0; fi
  done
}

STATUSLINE_ENABLED=false

_install_statusline() {
  local template tmp
  rm -f "$ABX_DIR/statusline.sh"
  STATUSLINE_ENABLED=false
  [ "${ABX_STATUSLINE:-}" = off ] && return 0
  template="$(_statusline_template)"
  if [ -z "$template" ]; then
    debug "no statusline template found"
    return 0
  fi
  tmp="$(mktemp "$ABX_DIR/.statusline.XXXXXX")"
  cp "$template" "$tmp"
  chmod 755 "$tmp"
  mv -f "$tmp" "$ABX_DIR/statusline.sh"
  STATUSLINE_ENABLED=true
  debug "statusline installed from $template"
}

# Derived from ABX_DIR, so this is set once the project is known rather than on sourcing.
_settings_init_vars() {
  ABX_SETTINGS="$ABX_DIR/settings.json"
}

# Rewritten on every run from abx's own state, so edits made inside the sandbox don't persist.
_write_abx_settings() {
  command -v python3 >/dev/null 2>&1 || die "python3 is needed to write $ABX_SETTINGS"
  local ports=""
  if [ "$PORTS_OWNED" = true ] || [ "$(docker inspect -f '{{.State.Running}}' "$PORTS_CONTAINER" 2>/dev/null)" = true ]; then
    ports="$PORTS_SPEC"
  fi
  python3 "$ABX_HOME/lib/write_settings.py" "$ABX_SETTINGS" "$SANDBOX_WORKSPACE" "$STATUSLINE_ENABLED" "$BEDROCK_ENABLED" "$BEDROCK_REGION" "$ports" \
    "http://$GATEWAY_ALIAS:$GATEWAY_PORT" "$GATEWAY_NO_PROXY"
}
