# Which containers abx may act on. Docker's project label is shared by every directory whose name matches, so a
# container is only ever used when its working directory is this project's .agent-sandbox/ (or inside it). Anything
# read from a container's labels is checked before use, as state files are.

DOCKER_BOOL_RE='^(true|false)$'
DOCKER_SERVICE_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
DOCKER_PATH_RE='^/[^[:cntrl:]]*$'
DOCKER_TIME_RE='^[0-9][0-9TZ:.+-]*$'
DOCKER_PROJECT_RE='^[a-z0-9][a-z0-9_-]*$'

# Reads the facts about container ID that abx needs, and sets CTR_RUNNING, CTR_SERVICE, CTR_IMAGE, CTR_CREATED,
# CTR_WORKDIR and CTR_OWNED. CTR_WORKDIR is the label without control characters, for messages. A container is owned
# only if every fact is valid, its project is this project's and its working directory is the sandbox's.
_describe_container() {
  local raw running service workdir project image created
  raw="$(docker inspect -f '{{.State.Running}}|{{index .Config.Labels "com.docker.compose.service"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}|{{index .Config.Labels "com.docker.compose.project"}}|{{.Config.Image}}|{{.Created}}' "$1" 2>/dev/null || true)"
  IFS='|' read -r running service workdir project image created <<< "$raw" || true
  CTR_RUNNING="$running"; CTR_SERVICE="$service"; CTR_IMAGE="$image"; CTR_CREATED="$created"
  CTR_WORKDIR="$(printf '%s' "$workdir" | tr -d '[:cntrl:]')"
  CTR_OWNED=false
  if [[ "$running" =~ $DOCKER_BOOL_RE && "$service" =~ $DOCKER_SERVICE_RE && "$workdir" =~ $DOCKER_PATH_RE \
        && "$image" =~ $STATE_IMAGE_RE && "$created" =~ $DOCKER_TIME_RE && "$project" = "$PROJECT_NAME" ]]; then
    case "$workdir" in
      "$PROJECT_DIR/.agent-sandbox"|"$PROJECT_DIR/.agent-sandbox"/*) CTR_OWNED=true ;;
    esac
  fi
  return 0
}

# "ID NAME" for each container that carries this project's Compose label, whichever directory it's from.
_project_containers() {
  docker ps -a --format '{{.ID}} {{.Names}}' --filter "label=com.docker.compose.project=$PROJECT_NAME" 2>/dev/null || true
}

# "ID NAME" for each container this project owns, optionally only those of one SERVICE, and only the running ones
# with scope 'running'.
_owned_containers() {
  local want="${1:-}" scope="${2:-all}" id name
  while read -r id name; do
    [ -n "$id" ] || continue
    _describe_container "$id"
    if [ "$CTR_OWNED" != true ]; then continue; fi
    if [ -n "$want" ] && [ "$CTR_SERVICE" != "$want" ]; then continue; fi
    if [ "$scope" = running ] && [ "$CTR_RUNNING" != true ]; then continue; fi
    echo "$id $name"
  done <<EOF
$(_project_containers)
EOF
  return 0
}

_owned_ids() { _owned_containers "$@" | cut -d' ' -f1; }

# The working directories, as labelled, of containers that carry this project's name but aren't owned: one per line.
_foreign_workdirs() {
  local id name
  while read -r id name; do
    [ -n "$id" ] || continue
    _describe_container "$id"
    if [ "$CTR_OWNED" != true ]; then echo "${CTR_WORKDIR:-(no working directory label)}"; fi
  done <<EOF
$(_project_containers)
EOF
  return 0
}

# A Docker timestamp such as 2026-10-12T06:00:00.5Z as digits, the fraction padded to nanoseconds, so that times
# compare as strings. Docker trims trailing zeros from the fraction, so the raw strings don't sort correctly.
_time_key() {
  local base="${1%Z}" frac=""
  case "$base" in *.*) frac="${base#*.}"; base="${base%%.*}" ;; esac
  frac="${frac}000000000"
  printf '%s%s' "$(printf '%s' "$base" | tr -d -- '-T:')" "${frac:0:9}"
}

# "ID NAME" for each running agent this project owns, newest first.
_ranked_agents() {
  local id name ranked=""
  while read -r id name; do
    [ -n "$id" ] || continue
    ranked="$ranked$(_time_key "$(docker inspect -f '{{.Created}}' "$id" 2>/dev/null || true)") $id $name"$'\n'
  done <<EOF
$(_owned_containers agent running)
EOF
  printf '%s' "$ranked" | sort -r | while read -r _key id name; do echo "$id $name"; done
  return 0
}

# The agent container to use: the newest running agent this project owns. Older ones are reported by
# _check_containers, which runs once per session.
_agent_container() {
  local ranked
  ranked="$(_ranked_agents)"
  if [ -z "$ranked" ]; then return 0; fi
  printf '%s' "${ranked%% *}"
}

# Runs before anything that uses the project's containers. A project name that another directory also uses stops abx
# when none of the containers under it are this project's, since Compose would then be sharing someone else's
# containers. Otherwise it's a warning. Several running agents are reported too: the older ones are left over from
# earlier stacks, and only 'abx clean' removes them.
_check_containers() {
  local foreign dirs ranked id name newest="" older=""
  foreign="$(_foreign_workdirs)"
  if [ -n "$foreign" ]; then
    dirs="$(printf '%s' "$foreign" | tr '\n' ' ')"
    if [ -z "$(_owned_containers)" ]; then
      die "Containers named '$PROJECT_NAME' belong to another directory: ${dirs% }. Two projects share that name, so abx won't use them. Rename one of the two directories, then rerun abx."
    fi
    echo "[warning] Containers named '$PROJECT_NAME' also belong to ${dirs% }. abx leaves them alone, but two directories share this name, so their volumes may be shared. Rename one of the directories." >&2
  fi
  ranked="$(_ranked_agents)"
  while read -r id name; do
    [ -n "$id" ] || continue
    if [ -z "$newest" ]; then newest="$name"; else older="$older $name"; fi
  done <<EOF
$ranked
EOF
  if [ -n "$older" ]; then
    echo "[warning] More than one agent container of this project is running. Using $newest, the newest. Still running:$older. Run 'abx clean' to remove the older ones." >&2
  fi
  return 0
}

# Whether the sidecar NAME (abx's gateway or port forwarder) is absent, belongs to this project, or belongs to another
# directory. Sidecars have no Compose labels, so abx marks each with its project directory.
_sidecar_owner() {
  local dir
  if ! docker inspect "$1" >/dev/null 2>&1; then echo absent; return 0; fi
  dir="$(docker inspect -f '{{index .Config.Labels "abx.project-dir"}}' "$1" 2>/dev/null || true)"
  if [ "$dir" = "$PROJECT_DIR" ]; then echo owned; else echo foreign; fi
  return 0
}

# Removes the sidecar NAME, but only if this project owns it.
_remove_owned_sidecar() {
  if [ "$(_sidecar_owner "$1")" = owned ]; then docker rm -f "$1" >/dev/null 2>&1 || true; fi
  return 0
}

# Whether the sidecar NAME is owned by this project and running.
_owned_sidecar_running() {
  [ "$(_sidecar_owner "$1")" = owned ] && [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = true ]
}
