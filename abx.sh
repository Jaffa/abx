#!/bin/bash
# abx: start Claude Code in a mattolson/agent-sandbox (agentbox) sandbox for the current project,
# initialising the project's sandbox and applying a personal default policy on first use.
#
# Install: ln -s /path/to/abx.sh ~/.local/bin/abx
#
# 'agentbox exec <command> [args]' passes its arguments through to the container verbatim, so no
# '--' separator is used. Init flags are set in ABX_INIT_ARGS; confirm them with 'abx check'.
#
# Bedrock mode (--bedrock) runs a signing gateway beside the sandbox: it holds short-lived credentials
# from a host AWS profile, refreshed in the background while the session runs, and signs Claude
# Code's Bedrock requests, so no AWS credentials ever enter the agent container.
#
# abx's own Claude Code settings live in .abx/settings.json and are passed with --settings, so they
# apply whichever directory Claude starts in and never touch the project's .claude/ files.

set -euo pipefail

# Resolved through symlinks, so the 'abx' link can live anywhere: lib/ and resources/ sit beside the real script.
ABX_HOME="$(
  src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" == /* ]] || src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
)"
if [ ! -d "$ABX_HOME/lib" ]; then
  echo "[error] abx's installation is incomplete: $ABX_HOME/lib is missing. Reinstall abx so that lib/ sits beside abx.sh." >&2
  exit 1
fi
for lib in "$ABX_HOME"/lib/*.sh; do . "$lib"; done

TEMPLATE_DIR="${ABX_TEMPLATE_DIR:-$HOME/.config/agent-sandbox/templates}"
POLICY_TEMPLATE="$TEMPLATE_DIR/user.policy.yaml"

usage() {
  cat <<'EOF'
Usage:
  abx [claude args...]   start Claude Code in this project's sandbox (initialising it if needed)
  abx shell              open a shell in the sandbox instead
  abx policy             edit this project's network policy (hot-reloads a running proxy)
  abx logs               follow the proxy log, e.g. to see refused domains
  abx reload             reload the proxy after editing policy files directly
  abx status             show the effective policy and compose configuration
  abx rebuild            rebuild the derived agent image from the latest upstream image
  abx check              show agentbox's version and help, to confirm the flags this script uses
  abx help

Options (before any claude args):
  --bedrock              use Amazon Bedrock via a host AWS profile; remembered for this project
  --ports[=SPEC]         publish ports from the sandbox on localhost for this session
                         (default 3000-3010,4173,5170-5190,6006,8080-8090)
  --ports-lan[=SPEC]     as --ports, but on all network interfaces
  --no-ports             don't publish ports, even if ABX_PORTS is set
  --no-bedrock           stop using Bedrock for this project and remove its credentials file
  --debug                verbose output
  --quiet                suppress abx's own messages
  --                     pass everything after this to claude, even words like 'shell'

Anything else is passed to claude, e.g. 'abx --continue' or 'abx -p "..."'.

Environment:
  ABX_TEMPLATE_DIR       where the default policy template lives (default ~/.config/agent-sandbox/templates)
  ABX_BEDROCK_PROFILE    host AWS profile for Bedrock mode (default claude-bedrock)
  ABX_PORTS              publish these ports in every session, e.g. '5170-5190,8080-8090' or 'default'
  ABX_BEDROCK_REFRESH    seconds between credential refreshes (default 600)
  ABX_ALLOW_ROOT         set to true to bypass the refusal to run as root
  ABX_SKIP_UID_CHECK     set to true to skip checking that the agent can write to the project
  ABX_IMAGE_EXTRAS       Dockerfile fragment layered into the agent image, run as root
                         (default ~/.config/agent-sandbox/abx/Dockerfile.extra)
  ABX_STATUSLINE         statusline script to install, or 'off'. Default: ~/.config/agent-sandbox/abx/statusline.sh
                         if present (examples/statusline.sh is a starting point); otherwise none
  ABX_CLAUDE_MD          instructions added to the sandbox image, or 'off'. Default: ~/.config/agent-sandbox/abx/CLAUDE.md
                         if present, otherwise resources/abx-CLAUDE.md
EOF
}

# ── arguments ─────────────────────────────────────────────────────────────────

COMMAND=claude
PASSTHROUGH_ARGS=()
BEDROCK_MODE=""
PORTS_MODE=""
PORTS_ARG=""
PORTS_LAN=false

while [ $# -gt 0 ]; do
  case "$1" in
    --bedrock) BEDROCK_MODE=on; shift ;;
    --ports) PORTS_MODE=on; shift ;;
    --ports=*) PORTS_MODE=on; PORTS_ARG="${1#--ports=}"; shift ;;
    --ports-lan) PORTS_MODE=on; PORTS_LAN=true; shift ;;
    --ports-lan=*) PORTS_MODE=on; PORTS_LAN=true; PORTS_ARG="${1#--ports-lan=}"; shift ;;
    --no-ports) PORTS_MODE=off; shift ;;
    --no-bedrock) BEDROCK_MODE=off; shift ;;
    --debug) ABX_DEBUG=true; shift ;;
    --quiet) ABX_QUIET=true; shift ;;
    --) shift; PASSTHROUGH_ARGS+=("$@"); break ;;
    *) break ;;
  esac
done

if [ ${#PASSTHROUGH_ARGS[@]} -eq 0 ] && [ $# -gt 0 ]; then
  case "$1" in
    shell|policy|logs|reload|status|check|rebuild) COMMAND="$1"; shift ;;
    help|-h|--help) usage; exit 0 ;;
  esac
  PASSTHROUGH_ARGS+=("$@")
fi

# ── prerequisites ─────────────────────────────────────────────────────────────

# Running as root would leave root-owned files in the project and put state under /root.
if [ "$(id -u)" = 0 ] && [ "${ABX_ALLOW_ROOT:-false}" != "true" ]; then
  die "Don't run abx as root or with sudo. Use rootless Docker or join the docker group instead."
fi

command -v agentbox >/dev/null 2>&1 \
  || die "agentbox is not on PATH. Install it from https://github.com/mattolson/agent-sandbox/releases"

if [ "$COMMAND" = check ]; then
  agentbox --version 2>/dev/null || agentbox version 2>/dev/null || true
  echo ""; echo "── agentbox init --help ──"; agentbox init --help 2>&1 || true
  echo ""; echo "── agentbox exec --help ──"; agentbox exec --help 2>&1 || true
  exit 0
fi

command -v docker >/dev/null 2>&1 || die "docker was not found on PATH."
if ! docker_err="$(docker info 2>&1 >/dev/null)"; then
  case "$docker_err" in
    *"permission denied"*)
      die "No permission to use the Docker socket. Join the docker group (then start a new login session) or use rootless Docker; don't run abx with sudo." ;;
    *) die "The Docker daemon is not reachable. Start Docker or Rancher Desktop and try again." ;;
  esac
fi

# ── project ───────────────────────────────────────────────────────────────────

HOME_PHYSICAL="$(cd "$HOME" && pwd -P)"

PROJECT_DIR="$(_find_project_root)"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd -P)"

if [[ "$PROJECT_DIR" = "/" || "$PROJECT_DIR" = "$HOME_PHYSICAL" || "$PROJECT_DIR" =~ $BROAD_PATH_RE ]]; then
  die "Refusing to sandbox '$PROJECT_DIR': run abx from inside a project directory."
fi

PROJECT_NAME="$(printf '%s' "$(basename "$PROJECT_DIR")" | LC_ALL=C tr -c 'A-Za-z0-9_-' '-' | LC_ALL=C tr 'A-Z' 'a-z')"
debug "project: $PROJECT_DIR (name: $PROJECT_NAME)"

# Claude starts in the same subdirectory inside the container, as if '/cd' had been run there.
START_DIR="$(pwd -P)"
SANDBOX_WORKSPACE="${ABX_SANDBOX_WORKSPACE:-/workspace}"
START_REL=""
case "$START_DIR" in "$PROJECT_DIR"/*) START_REL="${START_DIR#"$PROJECT_DIR"}" ;; esac

cd "$PROJECT_DIR"

ABX_DIR=".abx"

# Host-only state lives outside the project, under the project's name and a hash of its path, so projects
# with the same name in different places don't share it. See lib/state.sh.
ABX_STATE_KEY="$(printf '%s' "$PROJECT_DIR" | _sha16 | cut -c1-8 || true)"
[ -n "$ABX_STATE_KEY" ] || die "Couldn't hash the project path, so there's no state directory. Install sha256sum or shasum."
ABX_STATE="${XDG_STATE_HOME:-$HOME/.local/state}/abx/$PROJECT_NAME-$ABX_STATE_KEY"
mkdir -p "$ABX_STATE"
chmod 700 "$ABX_STATE"

if [ ! -d .agent-sandbox ]; then
  case "$COMMAND" in
    claude|shell) _init_project ;;
    *) die "No sandbox in $PROJECT_DIR yet. Run 'abx' first to initialise it." ;;
  esac
else
  _exclude_from_git
fi

_migrate_state

_bedrock_init_vars

_image_init_vars

_ports_init_vars

_settings_init_vars

# ── dispatch ──────────────────────────────────────────────────────────────────

case "$COMMAND" in
  claude|shell|rebuild) _check_containers ;;
esac

case "$COMMAND" in
  claude)
    info "Project: $PROJECT_DIR${START_REL:+ (starting in ${START_REL#/})}"
    if [ "${ABX_CLAUDE_MD:-}" != off ] && [ -z "$(_claude_md_template)" ]; then
      echo "[warning] $(_resources_dir)/abx-CLAUDE.md is missing, so the sandbox has no abx instructions. Is the installation complete?" >&2
    fi
    _record_project_name
    _remove_legacy_settings
    _install_statusline
    _ensure_uid_match
    _ensure_abx_mount
    if [ "$BEDROCK_ENABLED" = true ]; then
      _prepare_bedrock
      _start_refresher
      _start_bedrock_gateway
    fi
    case "$PORTS_MODE" in
      on) PORTS_ENABLED=true ;;
      off) PORTS_ENABLED=false ;;
      *) if [ -n "${ABX_PORTS:-}" ]; then PORTS_ENABLED=true; fi ;;
    esac
    if [ "$PORTS_ENABLED" = true ]; then
      PORTS_SPEC="${PORTS_ARG:-${ABX_PORTS:-default}}"
      [ "$PORTS_SPEC" = default ] && PORTS_SPEC="$DEFAULT_PORTS"
      [ "$PORTS_LAN" = true ] && PORTS_BIND="0.0.0.0"
      _start_port_forwarder
    fi
    _write_abx_settings
    # 'agentbox exec' passes its arguments through verbatim, so a small shell sets the directory.
    _run_interactive agentbox exec sh -c 'cd "$1" && shift && exec claude "$@"' abx \
      "$SANDBOX_WORKSPACE$START_REL" --settings "$SANDBOX_WORKSPACE/$ABX_SETTINGS" \
      ${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}
    ;;
  shell)
    _record_project_name
    _ensure_uid_match
    _ensure_abx_mount
    if [ -n "$START_REL" ]; then
      _run_interactive agentbox exec sh -c 'cd "$1" && exec "${SHELL:-/bin/sh}" -l' abx "$SANDBOX_WORKSPACE$START_REL"
    else
      _run_interactive agentbox exec
    fi
    ;;
  rebuild) _cmd_rebuild ;;
  policy) _ensure_editor; exec agentbox edit policy ;;
  logs)   exec agentbox proxy logs ;;
  reload) exec agentbox proxy reload ;;
  status)
    echo "── effective policy ──"; agentbox policy config
    echo ""; echo "── compose ──"; agentbox compose config
    ;;
esac
