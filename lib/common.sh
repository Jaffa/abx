# Output helpers and small utilities shared by every module.

die()   { echo "[error] $*" >&2; exit 1; }
info()  { if [ "${ABX_QUIET:-false}" != "true" ]; then echo "[abx] $*" >&2; fi; }
debug() { if [ "${ABX_DEBUG:-false}" = "true" ]; then echo "[debug] $*" >&2; fi; }

_sha16() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | cut -c1-16
}

# Files abx itself depends on live in resources/ beside the script; examples/ holds templates a user
# copies into ~/.config/agent-sandbox/abx/ and that abx never picks up on its own.
_resources_dir() {
  printf '%s/resources' "$(_abx_dir)"
}

_abx_dir() {
  printf '%s' "$ABX_HOME"
}

# Build contexts abx generates. They're rewritten whenever they're needed, so they're a cache, not configuration the
# user edits, and they stay out of the configuration directory.
_cache_dir() {
  printf '%s/abx' "${XDG_CACHE_HOME:-$HOME/.cache}"
}
