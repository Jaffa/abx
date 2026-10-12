# Test harness for abx: each test runs in a subshell with its own home directory, runtime directory,
# stub commands and project, so tests are independent and need neither Docker nor a network.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd -P)"

setup() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/abx-test.XXXXXX")"
  export HOME="$T/home" XDG_RUNTIME_DIR="$T/run" ABX_TEST_STATE="$T/state"
  export ABX_TEMPLATE_DIR="$HOME/.config/agent-sandbox/templates"
  CONFIG="$HOME/.config/agent-sandbox/abx"
  mkdir -p "$T/bin" "$HOME/.local/bin" "$HOME/src" "$XDG_RUNTIME_DIR" "$ABX_TEST_STATE" "$ABX_TEMPLATE_DIR" "$CONFIG"
  chmod 700 "$XDG_RUNTIME_DIR"
  # Copied so they're executable whatever the checkout preserved.
  cp "$TESTS_DIR/stubs/"* "$T/bin/" && chmod +x "$T/bin/"*
  export PATH="$T/bin:$PATH"
  ln -s "$REPO_DIR/abx.sh" "$HOME/.local/bin/abx"
  printf 'domains:\n  - docs.example.com\n' > "$ABX_TEMPLATE_DIR/user.policy.yaml"
  unset ABX_PORTS ABX_STATUSLINE ABX_CLAUDE_MD ABX_IMAGE_EXTRAS ABX_BEDROCK_PROFILE ABX_BEDROCK_REFRESH \
        ABX_ALLOW_ROOT ABX_SKIP_UID_CHECK ABX_DEBUG ABX_QUIET ABX_CONFIG_DIR XDG_STATE_HOME VISUAL EDITOR TZ
  export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=t@example.com
  state probe "1000 dev writable"
  new_project proj
}

teardown() {
  local pid
  for pid in ${LISTENERS:-}; do kill "$pid" 2>/dev/null; done
  cd / && rm -rf "$T"
}

# new_project NAME [git|plain]
new_project() {
  PROJECT="$HOME/src/$1"
  mkdir -p "$PROJECT" && cd "$PROJECT" || return 1
  if [ "${2:-git}" = git ]; then git init -q .; fi
}

state() { printf '%s\n' "$2" > "$ABX_TEST_STATE/$1"; }
state_has() { [ -e "$ABX_TEST_STATE/$1" ]; }
calls() { cat "$ABX_TEST_STATE/calls.log" 2>/dev/null; }
reset_calls() { : > "$ABX_TEST_STATE/calls.log"; : > "$ABX_TEST_STATE/events"; }
exec_args() { cat "$ABX_TEST_STATE/exec.args" 2>/dev/null; }
# state_dir: the host-only state directory abx keeps for the current project (see lib/project.sh).
state_dir() {
  local dir key
  dir="$(cd "$PROJECT" && pwd -P)"
  key="$(printf '%s' "$(basename "$dir")" | LC_ALL=C tr -c 'A-Za-z0-9_-' '-' | LC_ALL=C tr 'A-Z' 'a-z')"
  printf '%s/abx/%s-%s' "${XDG_STATE_HOME:-$HOME/.local/state}" "$key" "$(printf '%s' "$dir" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-8)"
}
settings_json() { python3 -c "import json,sys; d=json.load(open('$PROJECT/.abx/settings.json')); print(eval(sys.argv[1]))" "$1"; }

# The physical path abx uses for this test's project.
project_dir() { (cd "$PROJECT" && pwd -P); }

# The docker stub's container table (see tests/stubs/docker). A row with the same name is replaced.
# container_add NAME [SERVICE [IMAGE [CREATED [RUNNING [WORKDIR [PROJECT]]]]]]: a Compose container. Defaults: an agent
# on the upstream image, created in January 2026, running, in this project's .agent-sandbox/.
container_add() {
  local name="$1" service="${2:-agent}" image="${3:-ghcr.io/mattolson/agent-sandbox-claude:latest}" \
        created="${4:-2026-01-01T00:00:00Z}" running="${5:-true}" wd="${6:-$(project_dir)/.agent-sandbox}" \
        project="${7:-proj}"
  container_drop "$name"
  printf '%s %s %s %s %s %s %s %s\n' "$name" "$name" "$image" "$project" "$service" "$wd" "$created" "$running" \
    >> "$ABX_TEST_STATE/containers"
}
# sidecar_add NAME [OWNER_DIR [RUNNING]]: one of abx's own containers, with no Compose labels, carrying abx.project-dir.
sidecar_add() {
  local name="$1" dir="${2:-$(project_dir)}" running="${3:-true}"
  container_drop "$name"
  mkdir -p "$ABX_TEST_STATE/labels"
  printf '%s %s - - - - 2026-01-01T00:00:00Z %s\n' "$name" "$name" "$running" >> "$ABX_TEST_STATE/containers"
  printf '%s' "$dir" > "$ABX_TEST_STATE/labels/$name.abx.project-dir"
}
container_drop() {
  [ -f "$ABX_TEST_STATE/containers" ] || return 0
  awk -v k="$1" '$1 != k' "$ABX_TEST_STATE/containers" > "$ABX_TEST_STATE/containers.tmp"
  mv "$ABX_TEST_STATE/containers.tmp" "$ABX_TEST_STATE/containers"
}
containers_none() { : > "$ABX_TEST_STATE/containers"; }
# image_add TAG [KEY=VALUE...]: an image, with labels.
image_add() {
  local tag="$1" kv file
  shift
  file="$(printf '%s' "$tag" | tr '/:' '__')"
  mkdir -p "$ABX_TEST_STATE/images" "$ABX_TEST_STATE/image-labels"
  echo "$tag" > "$ABX_TEST_STATE/images/$file"
  : > "$ABX_TEST_STATE/image-labels/$file"
  for kv in "$@"; do printf '%s\n' "$kv" >> "$ABX_TEST_STATE/image-labels/$file"; done
}
# network_add NAME PROJECT and volume_add NAME PROJECT: Compose networks and volumes.
network_add() { printf '%s %s\n' "$1" "$2" >> "$ABX_TEST_STATE/networks"; }
volume_add() { printf '%s %s\n' "$1" "$2" >> "$ABX_TEST_STATE/volumes"; }

# run_abx ARGS... : runs abx, capturing combined output in $OUT and the exit status in $STATUS.
run_abx() {
  OUT="$(bash "$HOME/.local/bin/abx" "$@" 2>&1 </dev/null)"
  STATUS=$?
}

# Holds a TCP port open on the host, as another service would.
listen_on() {
  python3 -c "
import socket, time
s = socket.socket(); s.bind(('0.0.0.0', $1)); s.listen(); time.sleep(60)" &
  LISTENERS="${LISTENERS:-} $!"
  sleep 0.3
}

# ── assertions ────────────────────────────────────────────────────────────────

fail() {
  echo "    FAILED: $*"
  [ -n "${OUT:-}" ] && printf '%s\n' "$OUT" | sed 's/^/      | /' | tail -n 15
  exit 1
}
assert_status() { [ "$STATUS" = "$1" ] || fail "expected exit status $1, got $STATUS"; }
assert_out_contains() { printf '%s' "$OUT" | grep -qF -- "$1" || fail "output should contain: $1"; }
assert_out_lacks() { ! printf '%s' "$OUT" | grep -qF -- "$1" || fail "output should not contain: $1"; }
assert_eq() { [ "$1" = "$2" ] || fail "${3:-values differ}: expected [$2], got [$1]"; }
assert_file() { [ -e "$1" ] || fail "expected file $1"; }
assert_no_file() { [ ! -e "$1" ] || fail "expected no file $1"; }
assert_file_contains() { grep -qF -- "$2" "$1" 2>/dev/null || fail "$1 should contain: $2"; }
assert_file_lacks() { ! grep -qF -- "$2" "$1" 2>/dev/null || fail "$1 should not contain: $2"; }
assert_calls_contain() { calls | grep -qF -- "$1" || fail "expected a call matching: $1"; }
assert_calls_lack() { ! calls | grep -qF -- "$1" || fail "expected no call matching: $1"; }
skip() { echo "    SKIPPED: $*"; exit 77; }
