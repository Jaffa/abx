# Claude Code's configuration, which abx passes into the sandbox. Two sources:
#
# - abx's base instructions, resources/claude/CLAUDE.md, are always appended to the system prompt with
#   --append-system-prompt-file, so the sandbox always carries the context of how abx works. The installation is mounted
#   read-only at $BASE_CLAUDE_TARGET for that.
# - The user's directory, ~/.config/agent-sandbox/abx/claude by default, is laid out as a .claude directory is:
#   CLAUDE.md, statusline.sh and skills/<name>/SKILL.md. It's mounted read-only at $CLAUDE_DIR_TARGET, and --add-dir
#   passes Claude Code the directory above it, since that's where it looks for .claude/. Its CLAUDE.md is loaded as
#   memory, which needs CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD, set in .abx/settings.json (see write_settings.py).
#
# The sandbox paths keep the .claude name, since that's the name Claude Code looks for.
CLAUDE_ROOT_TARGET=/opt/abx
CLAUDE_DIR_TARGET="$CLAUDE_ROOT_TARGET/.claude"
BASE_CLAUDE_TARGET=/opt/abx-base

# Derived from ABX_CONFIG_DIR, so this is set once the project is known rather than on sourcing. ABX_CLAUDE_DIR=off leaves
# out the user's directory only; abx's own instructions are always present. CLAUDE_ARGS holds the arguments for Claude
# Code, placed before --settings.
_claude_init_vars() {
  local dir="${ABX_CLAUDE_DIR:-$ABX_CONFIG_DIR/claude}"
  CLAUDE_HOST=""
  BASE_CLAUDE_HOST="$(_resources_dir)/claude"
  STATUSLINE_COMMAND=""
  CLAUDE_ARGS=()
  if [ "$dir" != off ]; then
    # Docker needs an absolute source, and abx has already changed to the project directory, so a relative path is wrong.
    [[ "$dir" = /* ]] || die "ABX_CLAUDE_DIR must be an absolute path, not '$dir'."
    if [ -d "$dir" ]; then
      CLAUDE_HOST="$(cd -P "$dir" && pwd -P)"
      CLAUDE_ARGS+=(--add-dir "$CLAUDE_ROOT_TARGET")
      if [ -f "$CLAUDE_HOST/statusline.sh" ]; then STATUSLINE_COMMAND="bash $CLAUDE_DIR_TARGET/statusline.sh"; fi
    elif [ -n "${ABX_CLAUDE_DIR:-}" ]; then
      echo "[warning] ABX_CLAUDE_DIR is $dir, which isn't a directory, so it isn't mounted." >&2
    fi
  fi

  if [ -f "$BASE_CLAUDE_HOST/CLAUDE.md" ]; then
    CLAUDE_ARGS+=(--append-system-prompt-file "$BASE_CLAUDE_TARGET/CLAUDE.md")
  else
    echo "[warning] $BASE_CLAUDE_HOST/CLAUDE.md is missing, so the sandbox has no abx instructions. Is the installation complete?" >&2
    BASE_CLAUDE_HOST=""
  fi
}
