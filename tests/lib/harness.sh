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
  printf '%s/abx/%s-%s' "${XDG_STATE_HOME:-$HOME/.local/state}" "$key" "$(printf '%s' "$dir" | sha256sum | cut -c1-8)"
}
settings_json() { python3 -c "import json,sys; d=json.load(open('$PROJECT/.abx/settings.json')); print(eval(sys.argv[1]))" "$1"; }

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
