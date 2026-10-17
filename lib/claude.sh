# Claude Code's configuration, which abx passes into the sandbox. A host directory, ~/.config/agent-sandbox/abx/claude by
# default, is laid out as a .claude/ directory is: CLAUDE.md, statusline.sh and skills/<name>/SKILL.md. It's mounted
# read-only at $CLAUDE_DIR_TARGET, and --add-dir passes Claude Code the directory above it, since that's where Claude
# Code looks for .claude/. The sandbox path keeps the .claude name for the same reason.
#
# Claude Code reads CLAUDE.md from an added directory only when CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD is set, and
# .abx/settings.json sets it. Without a CLAUDE.md of the user's, abx's own instructions are mounted the same way, from
# the installation, so the image never carries instructions.
CLAUDE_ROOT_TARGET=/opt/abx
CLAUDE_DIR_TARGET="$CLAUDE_ROOT_TARGET/.claude"
DEFAULT_CLAUDE_ROOT_TARGET=/opt/abx-default
DEFAULT_CLAUDE_DIR_TARGET="$DEFAULT_CLAUDE_ROOT_TARGET/.claude"

# Derived from ABX_CONFIG_DIR, so this is set once the project is known rather than on sourcing. ABX_CLAUDE_DIR=off turns
# off all of it, the instructions included.
_claude_init_vars() {
  local dir="${ABX_CLAUDE_DIR:-$ABX_CONFIG_DIR/claude}"
  CLAUDE_HOST=""
  DEFAULT_CLAUDE_HOST=""
  STATUSLINE_COMMAND=""
  CLAUDE_ADD_DIR_ARGS=()
  [ "$dir" = off ] && return 0
  # Docker needs an absolute source, and abx has already changed to the project directory, so a relative path is wrong.
  [[ "$dir" = /* ]] || die "ABX_CLAUDE_DIR must be an absolute path, not '$dir'."
  if [ -d "$dir" ]; then
    CLAUDE_HOST="$(cd -P "$dir" && pwd -P)"
    CLAUDE_ADD_DIR_ARGS+=(--add-dir "$CLAUDE_ROOT_TARGET")
    if [ -f "$CLAUDE_HOST/statusline.sh" ]; then STATUSLINE_COMMAND="bash $CLAUDE_DIR_TARGET/statusline.sh"; fi
  elif [ -n "${ABX_CLAUDE_DIR:-}" ]; then
    echo "[warning] ABX_CLAUDE_DIR is $dir, which isn't a directory, so it isn't mounted." >&2
  fi

  if [ -z "$CLAUDE_HOST" ] || [ ! -f "$CLAUDE_HOST/CLAUDE.md" ]; then
    DEFAULT_CLAUDE_HOST="$(_resources_dir)/claude"
    if [ -f "$DEFAULT_CLAUDE_HOST/CLAUDE.md" ]; then
      CLAUDE_ADD_DIR_ARGS+=(--add-dir "$DEFAULT_CLAUDE_ROOT_TARGET")
    else
      echo "[warning] $DEFAULT_CLAUDE_HOST/CLAUDE.md is missing, so the sandbox has no abx instructions. Is the installation complete?" >&2
      DEFAULT_CLAUDE_HOST=""
    fi
  fi
}
