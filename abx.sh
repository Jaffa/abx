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

ABX_INIT_ARGS=(--agent claude --mode cli)
TEMPLATE_DIR="${ABX_TEMPLATE_DIR:-$HOME/.config/agent-sandbox/templates}"
POLICY_TEMPLATE="$TEMPLATE_DIR/user.policy.yaml"
BROAD_PATH_RE='^/(Users|home|mnt|Volumes)(/[^/]+)?$'

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

_init_project() {
  info "First run in $PROJECT_DIR: initialising the sandbox..."
  mkdir -p "$ABX_DIR"
  agentbox init "${ABX_INIT_ARGS[@]}" --name "$PROJECT_NAME" \
    || die "agentbox init failed. Run 'abx check' to confirm the init flags."

  [ -f "$POLICY_TEMPLATE" ] || _write_default_template
  mkdir -p .agent-sandbox/policy
  if [ -f .agent-sandbox/policy/user.policy.yaml ]; then
    cp .agent-sandbox/policy/user.policy.yaml .agent-sandbox/policy/user.policy.yaml.generated
  fi
  cp "$POLICY_TEMPLATE" .agent-sandbox/policy/user.policy.yaml
  # An invalid policy stops the proxy, and with it the whole sandbox, so it's checked before use.
  if agentbox policy config > "$ABX_DIR/policy-check.log" 2>&1; then
    info "Applied $POLICY_TEMPLATE as this project's policy."
  else
    echo "[warning] agentbox rejected the policy template $POLICY_TEMPLATE:" >&2
    tail -n 5 "$ABX_DIR/policy-check.log" | sed 's/^/          /' >&2
    if [ -f .agent-sandbox/policy/user.policy.yaml.generated ]; then
      cp .agent-sandbox/policy/user.policy.yaml.generated .agent-sandbox/policy/user.policy.yaml
      echo "          Keeping agentbox's own policy for this project; fix the template, then 'abx policy'." >&2
    else
      die "No generated policy to fall back on. Fix the template, then rerun abx."
    fi
  fi

  _exclude_from_git
}

ABX_DIR=".abx"

if [ ! -d .agent-sandbox ]; then
  case "$COMMAND" in
    claude|shell) _init_project ;;
    *) die "No sandbox in $PROJECT_DIR yet. Run 'abx' first to initialise it." ;;
  esac
else
  _exclude_from_git
fi

_bedrock_init_vars

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

# ── UID alignment ─────────────────────────────────────────────────────────────

# agentbox's image user has a fixed UID (501, the macOS default). macOS file sharing hides the
# mismatch, but Linux bind mounts don't, leaving the project read-only to the agent. abx probes
# for that, and on a mismatch rebuilds the image with the user renumbered to the host UID.

ABX_CONFIG_DIR="${ABX_CONFIG_DIR:-$HOME/.config/agent-sandbox/abx}"
UID_MARKER="$ABX_DIR/uid-ok"
UID_STATE="$ABX_DIR/uid-remap.env"
OVERRIDE_MARKER="# abx: uid-remap"
HOST_UID="$(id -u)"

_agent_container() {
  docker ps -q --filter "label=com.docker.compose.project=$PROJECT_NAME" \
    --filter "label=com.docker.compose.service=agent" | head -n1
}

PROBE_LOG="$ABX_DIR/probe.log"

# Everything agentbox prints is kept in the probe log, since a failure here is otherwise opaque.
_probe_container() {
  local raw
  raw="$(agentbox exec sh -c 'printf "%s %s " "$(id -u)" "$(id -un 2>/dev/null || echo unknown)"; if touch .abx-write-probe 2>/dev/null; then rm -f .abx-write-probe; echo writable; else echo readonly; fi' 2>&1)" || true
  printf '%s\n' "$raw" > "$PROBE_LOG"
  printf '%s\n' "$raw" | tr -d '\r' | grep -E '^[0-9]+ [^ ]+ (writable|readonly)$' | tail -n1 || true
}

# agentbox edit compose opens the user override in $EDITOR; a stand-in editor reports its path.
_override_path() {
  local helper out path
  helper="$(mktemp)"; out="$(mktemp)"
  printf '#!/bin/sh\nfor a in "$@"; do last="$a"; done\nprintf "%%s" "$last" > "%s"\n' "$out" > "$helper"
  chmod +x "$helper"
  EDITOR="$helper" VISUAL="$helper" agentbox edit compose >/dev/null 2>&1 </dev/null || true
  path="$(cat "$out")"
  rm -f "$helper" "$out"
  if [ -n "$path" ] && [[ "$path" != /* ]]; then path="$PROJECT_DIR/$path"; fi
  printf '%s' "$path"
}

_override_snippet() {
  printf 'services:\n  agent:\n    image: %s  %s\n    pull_policy: never  %s\n' "$1" "$OVERRIDE_MARKER" "$OVERRIDE_MARKER"
}

# agentbox seeds the override with its own content, so abx merges two keys into the agent service
# rather than replacing the file, then checks the result through agentbox's merged configuration.
_merge_override() {
  python3 - "$1" "$2" <<'PY'
import re, sys

MARK = "# abx: uid-remap"

MARK = "# abx: uid-remap"

def merge(text, tag):
    """Return (new_text, status). status: 'updated' | 'merged' | 'conflict'."""
    lines = text.split("\n")

    # Already managed by abx: refresh the tag in place.
    if any(MARK in l for l in lines):
        out = [re.sub(r"^(\s*image:\s*)\S+(.*%s.*)$" % re.escape(MARK), r"\g<1>%s\g<2>" % tag, l) for l in lines]
        return "\n".join(out), "updated"

    def is_content(l):
        s = l.strip()
        return s and not s.startswith("#")

    svc = next((i for i, l in enumerate(lines) if re.match(r"^services:\s*(\{\s*\})?\s*(#.*)?$", l)), None)
    if svc is None:
        block = ["services:", "  agent:", "    image: %s  %s" % (tag, MARK), "    pull_policy: never  %s" % MARK]
        body = text.rstrip("\n")
        return (body + "\n" if body else "") + "\n".join(block) + "\n", "merged"
    if re.match(r"^services:\s*\{\s*\}", lines[svc]):
        lines[svc] = "services:"

    # Indentation of services' children, from the first content line below 'services:'.
    end = len(lines)
    for j in range(svc + 1, len(lines)):
        if is_content(lines[j]) and not lines[j].startswith((" ", "\t")):
            end = j
            break
    child_indent = None
    for j in range(svc + 1, end):
        if is_content(lines[j]):
            child_indent = re.match(r"^(\s*)", lines[j]).group(1)
            break
    child_indent = child_indent or "  "
    step = child_indent

    agent = None
    for j in range(svc + 1, end):
        m = re.match(r"^%sagent:\s*(\{\s*\})?\s*(#.*)?$" % re.escape(child_indent), lines[j])
        if m:
            agent = j
            if m.group(1):
                lines[j] = "%sagent:" % child_indent
            break

    if agent is None:
        insert = ["%sagent:" % child_indent,
                  "%s%simage: %s  %s" % (child_indent, step, tag, MARK),
                  "%s%spull_policy: never  %s" % (child_indent, step, MARK)]
        lines[svc + 1:svc + 1] = insert
        return "\n".join(lines), "merged"

    # Inside the agent block: find its key indentation and refuse if the user already set an image.
    a_end = end
    for j in range(agent + 1, end):
        if is_content(lines[j]) and len(re.match(r"^(\s*)", lines[j]).group(1)) <= len(child_indent):
            a_end = j
            break
    key_indent = None
    for j in range(agent + 1, a_end):
        if is_content(lines[j]):
            key_indent = re.match(r"^(\s*)", lines[j]).group(1)
            break
    key_indent = key_indent or child_indent + step
    for j in range(agent + 1, a_end):
        if re.match(r"^%s(image|build|pull_policy):" % re.escape(key_indent), lines[j]):
            return text, "conflict"
    lines[agent + 1:agent + 1] = ["%simage: %s  %s" % (key_indent, tag, MARK),
                                  "%spull_policy: never  %s" % (key_indent, MARK)]
    return "\n".join(lines), "merged"

path, tag = sys.argv[1], sys.argv[2]
try:
    text = open(path).read()
except FileNotFoundError:
    text = ""
new, status = merge(text, tag)
if status != "conflict":
    with open(path, "w") as f:
        f.write(new if new.endswith("\n") else new + "\n")
print(status)
PY
}

_write_override() {
  local tag="$1" file status backup=""
  command -v python3 >/dev/null 2>&1 || die "python3 is needed to update agentbox's compose override."
  file="$(_override_path)"
  if [ -z "$file" ]; then
    echo "[error] Couldn't find agentbox's compose override file. Add this with 'agentbox edit compose':" >&2
    _override_snippet "$tag" >&2
    exit 1
  fi
  if [ -f "$file" ]; then
    backup="$file.abx-backup"
    cp "$file" "$backup"
  fi
  mkdir -p "$(dirname "$file")"
  status="$(_merge_override "$file" "$tag")" || die "Could not update $file"
  if [ "$status" = conflict ]; then
    rm -f "$backup"
    echo "[error] $file already sets the agent's image or build, so abx won't change it. Merge this in yourself, then rerun abx:" >&2
    _override_snippet "$tag" >&2
    exit 1
  fi
  if ! agentbox compose config 2>/dev/null | grep -F "$tag" >/dev/null; then
    if [ -n "$backup" ]; then mv -f "$backup" "$file"; else rm -f "$file"; fi
    echo "[error] agentbox's merged configuration didn't pick up the new image, so $file has been restored. Add this with 'agentbox edit compose':" >&2
    _override_snippet "$tag" >&2
    exit 1
  fi
  rm -f "$backup"
  debug "override $status in $file"
}

IMAGE_EXTRAS="${ABX_IMAGE_EXTRAS:-$ABX_CONFIG_DIR/Dockerfile.extra}"

_claude_md_template() {
  local candidate
  [ "${ABX_CLAUDE_MD:-}" = off ] && return 0
  for candidate in "${ABX_CLAUDE_MD:-}" "$ABX_CONFIG_DIR/CLAUDE.md" "$(_resources_dir)/abx-CLAUDE.md"; do
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then printf '%s' "$candidate"; return 0; fi
  done
}

_has_image_additions() {
  [ -f "$IMAGE_EXTRAS" ] || [ -n "$(_claude_md_template)" ]
}

# Changes to either addition trigger a rebuild, so both feed the stored hash.
_extras_hash() {
  local md
  md="$(_claude_md_template)"
  if ! _has_image_additions; then echo none; return 0; fi
  { [ -f "$IMAGE_EXTRAS" ] && cat "$IMAGE_EXTRAS"; printf '\n--abx-claude-md--\n'; [ -n "$md" ] && cat "$md"; true; } | _sha16
}

# Builds the image abx points the agent service at: the upstream image with the agent user
# renumbered to target_uid (a no-op when it already matches), plus any image extras.
_build_derived_image() {
  local base="$1" user="$2" orig_user="$3" target_uid="$4" pull="${5:-false}" name repo tag dir md flags=()
  md="$(_claude_md_template)"
  name="${base##*/}"; name="${name%%@*}"
  repo="${name%%:*}"
  tag="latest"
  case "$name" in *:*) tag="${name#*:}" ;; esac
  REMAPPED_IMAGE="abx/${repo}-uid${target_uid}:${tag}"

  dir="$ABX_CONFIG_DIR/uid-remap"
  mkdir -p "$dir"
  {
    cat <<'EOF'
ARG BASE
FROM ${BASE}
ARG HOST_UID
ARG USER_NAME
ARG ORIG_USER=root
USER root
# Another account already holding the host UID (e.g. 'node') is moved out of the way first.
RUN other="$(getent passwd "${HOST_UID}" | cut -d: -f1)" \
 && if [ -n "$other" ] && [ "$other" != "${USER_NAME}" ]; then usermod -u 59999 "$other"; fi \
 && old_uid="$(id -u "${USER_NAME}")" \
 && usermod -u "${HOST_UID}" "${USER_NAME}" \
 && (find / -xdev -uid "${old_uid}" -exec chown -h "${HOST_UID}" {} + 2>/dev/null || true)
EOF
    if [ -f "$IMAGE_EXTRAS" ]; then
      printf '\n# Image extras from %s (run as root)\n' "$IMAGE_EXTRAS"
      cat "$IMAGE_EXTRAS"
      printf '\nUSER root\n'
    fi
    if [ -n "$md" ]; then
      # Appended to Claude Code's managed instructions, which the agent can read but not change.
      printf '%s\n' 'COPY abx-CLAUDE.md /tmp/abx-CLAUDE.md' \
        'RUN mkdir -p /etc/claude-code && { printf "\\n"; cat /tmp/abx-CLAUDE.md; } >> /etc/claude-code/CLAUDE.md && rm /tmp/abx-CLAUDE.md'
    fi
    printf '%s\n' 'USER ${ORIG_USER}'
  } > "$dir/Dockerfile"
  rm -f "$dir/abx-CLAUDE.md"
  if [ -n "$md" ]; then cp "$md" "$dir/abx-CLAUDE.md"; fi

  if [ "$pull" = true ]; then flags=(--pull); fi
  info "Building $REMAPPED_IMAGE$( _has_image_additions && printf ' with abx additions')..."
  if ! docker build ${flags[@]+"${flags[@]}"} -t "$REMAPPED_IMAGE" \
      --build-arg "BASE=$base" --build-arg "HOST_UID=$target_uid" \
      --build-arg "USER_NAME=$user" --build-arg "ORIG_USER=${orig_user:-root}" \
      "$dir" > "$ABX_DIR/build.log" 2>&1; then
    tail -n 20 "$ABX_DIR/build.log" >&2
    die "Building $REMAPPED_IMAGE failed; the full log is in $PROJECT_DIR/$ABX_DIR/build.log"
  fi
}

_write_image_state() {
  printf 'BASE=%s\nUSER_NAME=%s\nORIG_USER=%s\nOLD_UID=%s\nTARGET_UID=%s\nEXTRAS_HASH=%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$(_extras_hash)" > "$UID_STATE"
}

_stop_project_containers() {
  local ids
  ids="$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME")"
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    docker rm -f $ids >/dev/null
  fi
}

_reown_volumes() {
  local old_uid="$1" vol
  shift
  for vol in "$@"; do
    debug "re-owning files in volume $vol from UID $old_uid to $HOST_UID"
    docker run --rm --network none -u 0 --entrypoint find -v "$vol:/v" "$REMAPPED_IMAGE" \
      /v -xdev -uid "$old_uid" -exec chown -h "$HOST_UID" {} + \
      || echo "[warning] Could not re-own files in volume $vol" >&2
  done
}

# Volumes the agent shares with another container (the proxy's CA and run directories) belong to
# that container's user, so only volumes mounted by the agent alone are re-owned.
_agent_only_volumes() {
  local ctr="$1" other shared="" vol result=""
  for other in $(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME"); do
    case "$ctr" in "$other"*) continue ;; esac
    shared="$shared $(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' "$other")"
  done
  for vol in $(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' "$ctr"); do
    case " $shared " in
      *" $vol "*) debug "not re-owning $vol: another container also mounts it" ;;
      *) result="$result $vol" ;;
    esac
  done
  printf '%s' "$result"
}

# First switch of a project to a derived image, from the running upstream container.
_apply_derived_image() {
  local c_uid="$1" c_user="$2" target_uid="$3" ctr base orig_user volumes=""
  ctr="$(_agent_container)"
  [ -n "$ctr" ] || die "Couldn't find the running agent container for project '$PROJECT_NAME' to inspect."
  base="$(docker inspect -f '{{.Config.Image}}' "$ctr")"
  case "$base" in
    abx/*) die "The agent already runs $base but abx has no record of building it. Remove the lines marked '$OVERRIDE_MARKER' with 'agentbox edit compose', then rerun abx." ;;
  esac
  orig_user="$(docker image inspect -f '{{.Config.User}}' "$base" 2>/dev/null || true)"
  if [ "$c_uid" != "$target_uid" ]; then
    volumes="$(_agent_only_volumes "$ctr")"
    info "The agent runs as UID $c_uid but your files belong to UID $target_uid, so it can't write to the project. Fixing..."
  fi

  _build_derived_image "$base" "$c_user" "$orig_user" "$target_uid"
  _write_override "$REMAPPED_IMAGE"
  _stop_project_containers
  if [ -n "$volumes" ]; then
    # shellcheck disable=SC2086
    _reown_volumes "$c_uid" $volumes
  fi

  _write_image_state "$base" "$c_user" "$orig_user" "$c_uid" "$target_uid"
  printf '%s\n' "$HOST_UID" > "$UID_MARKER"
  if [ "$c_uid" != "$target_uid" ]; then info "Done: the agent will run as UID $target_uid from now on."; fi
}

# Rebuild for a project already on a derived image, e.g. new extras or a newer upstream image.
_refresh_derived_image() {
  local pull="$1"
  # shellcheck disable=SC1090
  . "$UID_STATE"
  _build_derived_image "$BASE" "$USER_NAME" "$ORIG_USER" "${TARGET_UID:-$HOST_UID}" "$pull"
  _write_override "$REMAPPED_IMAGE"
  _stop_project_containers
  _write_image_state "$BASE" "$USER_NAME" "$ORIG_USER" "$OLD_UID" "${TARGET_UID:-$HOST_UID}"
}

_ensure_uid_match() {
  local probe c_uid c_user state stored
  if [ "${ABX_SKIP_UID_CHECK:-false}" = true ]; then return 0; fi
  if [ -f "$UID_MARKER" ] && [ "$(cat "$UID_MARKER")" = "$HOST_UID" ]; then
    if [ -f "$UID_STATE" ]; then
      stored="$(sed -n 's/^EXTRAS_HASH=//p' "$UID_STATE")"
      if [ "${stored:-none}" != "$(_extras_hash)" ]; then
        info "The image extras or abx's CLAUDE.md have changed; rebuilding."
        _refresh_derived_image false
      fi
      return 0
    fi
    # Additions made since this project was checked need a derived image, so check it again.
    _has_image_additions || return 0
  fi
  mkdir -p "$ABX_DIR"
  _exclude_path "$ABX_DIR/"

  probe="$(_probe_container)"
  # runc refuses to exec into a bind mount whose host directory was deleted and recreated while
  # the containers kept running; recreating the containers points them at the new directory.
  if [ -z "$probe" ] && grep -q 'outside of container mount namespace root' "$PROBE_LOG"; then
    info "The sandbox containers predate this directory (it was deleted and recreated). Recreating them..."
    _stop_project_containers
    probe="$(_probe_container)"
  fi
  if [ -z "$probe" ]; then
    echo "[error] Couldn't check whether the agent can write to the project. agentbox returned:" >&2
    sed 's/^/        /' "$PROBE_LOG" | tail -n 15 >&2
    die "Full output is in $PROJECT_DIR/$PROBE_LOG. Set ABX_SKIP_UID_CHECK=true to bypass the check."
  fi
  c_uid="${probe%% *}"; state="${probe##* }"; c_user="${probe#* }"; c_user="${c_user%% *}"
  debug "container user $c_user ($c_uid), project is $state"

  if [ "$state" = writable ]; then
    if _has_image_additions; then
      _apply_derived_image "$c_uid" "$c_user" "$c_uid"
    else
      printf '%s\n' "$HOST_UID" > "$UID_MARKER"
    fi
  elif [ "$c_uid" != "$HOST_UID" ]; then
    _apply_derived_image "$c_uid" "$c_user" "$HOST_UID"
  else
    die "The agent (UID $c_uid) can't write to the project even though the UIDs match. Check for SELinux labels or read-only mounts."
  fi
}

_cmd_rebuild() {
  [ -f "$UID_STATE" ] || { info "This project doesn't use a derived image; nothing to rebuild."; return 0; }
  _refresh_derived_image true
  info "Rebuilt from the latest upstream image; the next abx run starts on it."
}

# Inside the sandbox the project is always /workspace; the statusline reads its real name from here.
_record_project_name() {
  mkdir -p "$ABX_DIR"
  _exclude_path "$ABX_DIR/"
  # pnpm keeps its store on the same filesystem as the project, which in the sandbox is /workspace.
  _exclude_path '.pnpm-store/'
  printf '%s\n' "$(basename "$PROJECT_DIR")" > "$ABX_DIR/project-name"
}

# ── statusline ────────────────────────────────────────────────────────────────

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

_ports_init_vars

# ── abx settings ──────────────────────────────────────────────────────────────

ABX_SETTINGS="$ABX_DIR/settings.json"

# Rewritten on every run from abx's own state, so edits made inside the sandbox don't persist.
_write_abx_settings() {
  command -v python3 >/dev/null 2>&1 || die "python3 is needed to write $ABX_SETTINGS"
  local ports=""
  if [ "$PORTS_OWNED" = true ] || [ "$(docker inspect -f '{{.State.Running}}' "$PORTS_CONTAINER" 2>/dev/null)" = true ]; then
    ports="$PORTS_SPEC"
  fi
  python3 - "$ABX_SETTINGS" "$SANDBOX_WORKSPACE" "$STATUSLINE_ENABLED" "$BEDROCK_ENABLED" "$BEDROCK_REGION" "$ports" \
    "http://$GATEWAY_ALIAS:$GATEWAY_PORT" "$GATEWAY_NO_PROXY" <<'PY'
import json, os, sys
path, ws, statusline, bedrock, region, ports, gateway, no_proxy = sys.argv[1:9]
data = {}
env = {}
if statusline == "true":
    data["statusLine"] = {"type": "command", "command": "bash %s/.abx/statusline.sh" % ws, "padding": 0}
if bedrock == "true":
    env.update({"CLAUDE_CODE_USE_BEDROCK": "1", "AWS_REGION": region,
                "ANTHROPIC_BEDROCK_BASE_URL": gateway, "CLAUDE_CODE_SKIP_BEDROCK_AUTH": "1",
                "NO_PROXY": no_proxy, "no_proxy": no_proxy})
if ports:
    env["ABX_PUBLISHED_PORTS"] = ports
if env:
    data["env"] = env
with open(path + ".tmp", "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(path + ".tmp", path)
PY
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

# ── dispatch ──────────────────────────────────────────────────────────────────

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
