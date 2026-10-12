# Project setup: the project root, its sandbox and policy, git excludes, and the editor for
# agentbox's policy command.

ABX_INIT_ARGS=(--agent claude --mode cli)
BROAD_PATH_RE='^/(Users|home|mnt|Volumes)(/[^/]+)?$'

# An existing sandbox in this directory or any parent wins, so subdirectories share one sandbox
# whether or not the project is a git repository. The markers are checked before git so a
# nested repository (a vendored dependency, say) isn't mistaken for the project. The search
# stops below $HOME, which is never a valid project.
_find_project_root() {
  local d
  d="$(pwd -P)"
  while [ "$d" != "/" ] && [ "$d" != "$HOME_PHYSICAL" ]; do
    if [ -d "$d/.agent-sandbox" ] || [ -d "$d/.abx" ]; then
      printf '%s' "$d"
      return 0
    fi
    d="$(dirname "$d")"
  done
  git rev-parse --show-toplevel 2>/dev/null || pwd -P
}

_write_default_template() {
  mkdir -p "$TEMPLATE_DIR"
  cat > "$POLICY_TEMPLATE" <<'EOF'
# Personal default policy, copied into each project by abx on first use.
# Check docs/policy/schema.md for whether an entry also matches subdomains.
domains:
  - registry.npmjs.org
  - pypi.org
  - files.pythonhosted.org
  - api.osv.dev
  - docs.aws.amazon.com
  - developer.mozilla.org
  - docs.python.org
  - nodejs.org
EOF
  info "Created a default policy template at $POLICY_TEMPLATE; edit it to change future projects."
}

_exclude_path() {
  local exclude=".git/info/exclude"
  [ -d .git ] || return 0
  mkdir -p .git/info
  # Excluded locally, so the sandbox stays personal without changing the repository's .gitignore.
  if ! grep -qxF "$1" "$exclude" 2>/dev/null; then
    echo "$1" >> "$exclude"
    debug "added $1 to $exclude"
  fi
}

_exclude_from_git() { _exclude_path '.agent-sandbox/'; }

# The name this project's containers, volumes and sidecars carry. A project set up by this version is named for its
# directory and eight hex digits of a hash of its path, so two directories with the same name never share containers.
# A project keeps the name it has: the one recorded in its state directory, or else its directory's name, which the
# projects set up before this version have.
_project_name_init() {
  local stem
  if _state_file "$ABX_STATE/project-name"; then
    PROJECT_NAME="$(cat "$ABX_STATE/project-name")"
    if [[ "$PROJECT_NAME" =~ $DOCKER_PROJECT_RE ]]; then return 0; fi
    _refuse "$ABX_STATE/project-name" "the project name is not in the expected format"
  fi
  if [ -d "$PROJECT_DIR/.agent-sandbox" ]; then
    PROJECT_NAME="$PROJECT_DIR_NAME"
    return 0
  fi
  # Compose names must start with a letter or digit, so leading dashes and underscores are dropped.
  stem="$(printf '%s' "$PROJECT_DIR_NAME" | sed 's/^[-_]*//')"
  [ -n "$stem" ] || stem=project
  PROJECT_NAME="$stem-$(printf '%s' "$PROJECT_DIR" | _sha16 | cut -c1-8)"
}

_init_project() {
  info "First run in $PROJECT_DIR: initialising the sandbox..."
  mkdir -p "$ABX_DIR"
  # Recorded before agentbox runs, so a failed init still leaves the name: the next run must not take the
  # directory's name for a sandbox set up earlier.
  printf '%s\n' "$PROJECT_NAME" > "$ABX_STATE/project-name"
  agentbox init "${ABX_INIT_ARGS[@]}" --name "$PROJECT_NAME" \
    || die "agentbox init failed. Run 'abx check' to confirm the init flags."

  [ -f "$POLICY_TEMPLATE" ] || _write_default_template
  mkdir -p .agent-sandbox/policy
  if [ -f .agent-sandbox/policy/user.policy.yaml ]; then
    cp .agent-sandbox/policy/user.policy.yaml .agent-sandbox/policy/user.policy.yaml.generated
  fi
  cp "$POLICY_TEMPLATE" .agent-sandbox/policy/user.policy.yaml
  # An invalid policy stops the proxy, and with it the whole sandbox, so it's checked before use.
  if agentbox policy config > "$ABX_STATE/policy-check.log" 2>&1; then
    info "Applied $POLICY_TEMPLATE as this project's policy."
  else
    echo "[warning] agentbox rejected the policy template $POLICY_TEMPLATE:" >&2
    tail -n 5 "$ABX_STATE/policy-check.log" | sed 's/^/          /' >&2
    if [ -f .agent-sandbox/policy/user.policy.yaml.generated ]; then
      cp .agent-sandbox/policy/user.policy.yaml.generated .agent-sandbox/policy/user.policy.yaml
      echo "          Keeping agentbox's own policy for this project; fix the template, then 'abx policy'." >&2
    else
      die "No generated policy to fall back on. Fix the template, then rerun abx."
    fi
  fi

  _exclude_from_git
}

# agentbox opens files in $VISUAL or $EDITOR; with neither set it falls back to a desktop opener,
# which fails on headless machines.
_ensure_editor() {
  local e
  if [ -n "${VISUAL:-}${EDITOR:-}" ]; then return 0; fi
  for e in sensible-editor editor nano vim vi; do
    if command -v "$e" >/dev/null 2>&1; then
      export VISUAL="$e" EDITOR="$e"
      return 0
    fi
  done
  die "No text editor found. Install one (e.g. nano or vim) or set EDITOR."
}
