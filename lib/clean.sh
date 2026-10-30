# 'abx clean': removes what abx started for this project's sandbox, or with --all for every agentbox project on the
# machine. A project's containers are only the ones it owns (see lib/containers.sh), and its sidecars only when they
# belong to it. The state directory and the project's .agent-sandbox/ and .abx/ are never removed.

# The lists _cmd_clean resets and the planning functions fill, each in the order it's removed: containers as "ID NAME",
# the rest as names, and CLEAN_NOTES as sentences for the report. CLEAN_PRUNE says whether to prune dangling images.

_clean_runtime_base() {
  printf '%s/abx' "${XDG_RUNTIME_DIR:-$HOME/.cache}"
}

# Whether a session of abx is running that registered in DIR (see lib/bedrock.sh). The session files are named by
# the PID of the abx process, so one is live when that process still runs.
_sessions_live() {
  local f
  for f in "$1"/*; do
    [ -f "$f" ] || continue
    if kill -0 "$(basename "$f")" 2>/dev/null; then return 0; fi
  done
  return 1
}

# Lists the networks of Compose project PROJECT, one per line.
_project_networks() {
  docker network ls --filter "label=com.docker.compose.project=$1" --format '{{.Name}}' 2>/dev/null || true
}

# Fills the lists for this project: its owned containers, its sidecars when they belong to it, its networks, and with
# --volumes its Compose volumes.
_clean_plan_project() {
  local volumes="$1" foreign id name vol net
  foreign="$(_foreign_workdirs)"
  if [ "$volumes" = true ] && [ -n "$foreign" ]; then
    die "Containers named '$PROJECT_NAME' belong to another directory: $(printf '%s' "$foreign" | tr '\n' ' '). --volumes is refused, because those containers may share the project's volumes. Rename one of the two directories, then rerun abx."
  fi
  while read -r id name; do
    [ -n "$id" ] || continue
    CLEAN_CONTAINERS+=("$id $name")
  done <<EOF
$(_owned_containers)
EOF
  for name in "abx-gateway-$PROJECT_NAME" "abx-ports-$PROJECT_NAME" "abx-outbound-$PROJECT_NAME"; do
    case "$(_sidecar_owner "$name")" in
      owned) CLEAN_CONTAINERS+=("$name $name") ;;
      foreign) CLEAN_NOTES+=("$name belongs to another directory, or to an earlier abx, so it's left alone.") ;;
    esac
  done
  while read -r net; do
    [ -n "$net" ] || continue
    CLEAN_NETWORKS+=("$net")
  done <<EOF
$(_project_networks "$PROJECT_NAME")
EOF
  if [ "$volumes" = true ]; then
    while read -r vol; do
      [ -n "$vol" ] || continue
      CLEAN_VOLUMES+=("$vol")
    done <<EOF
$(docker volume ls --filter "label=com.docker.compose.project=$PROJECT_NAME" --format '{{.Name}}' 2>/dev/null || true)
EOF
  fi
  if [ -d "$ABX_RUNTIME_DIR/creds" ]; then CLEAN_CREDENTIALS+=("$ABX_RUNTIME_DIR/creds"); fi
  if _sessions_live "$SESSIONS_DIR"; then CLEAN_NOTES+=("A session of this project is running, and cleaning stops its sandbox."); fi
  return 0
}

# Fills the lists for every agentbox project. A project is one whose containers run an agentbox image, found from the
# image each container names. Images are never matched with 'ancestor=', which resolves a name to the image it names
# now and so misses containers made from earlier pulls.
_clean_plan_all() {
  local volumes="$1" images="$2" id image project name vol img net projects="" dir base
  while read -r id; do
    [ -n "$id" ] || continue
    read -r image project <<< "$(docker inspect -f '{{.Config.Image}} {{index .Config.Labels "com.docker.compose.project"}}' "$id" 2>/dev/null || true)"
    case "$image" in ghcr.io/mattolson/agent-sandbox-*|abx/*) ;; *) continue ;; esac
    if ! [[ "$project" =~ $DOCKER_PROJECT_RE ]]; then continue; fi
    case " $projects " in *" $project "*) ;; *) projects="$projects $project" ;; esac
  done <<EOF
$(docker ps -aq --filter label=com.docker.compose.project 2>/dev/null || true)
EOF

  for project in $projects; do
    while read -r id name; do
      [ -n "$id" ] || continue
      CLEAN_CONTAINERS+=("$id $name")
    done <<EOF
$(docker ps -a --format '{{.ID}} {{.Names}}' --filter "label=com.docker.compose.project=$project" 2>/dev/null || true)
EOF
    while read -r net; do
      [ -n "$net" ] || continue
      CLEAN_NETWORKS+=("$net")
    done <<EOF
$(_project_networks "$project")
EOF
  done

  while read -r id name; do
    [ -n "$id" ] || continue
    case "$name" in abx-gateway-*|abx-ports-*|abx-outbound-*) CLEAN_CONTAINERS+=("$id $name") ;; esac
  done <<EOF
$(docker ps -a --format '{{.ID}} {{.Names}}' 2>/dev/null || true)
EOF

  if [ "$volumes" = true ]; then
    while read -r vol; do
      case "$vol" in
        *_claude-state|*_claude-history|*_proxy-state|*_proxy-ca|*_proxy-agentbox-run) CLEAN_VOLUMES+=("$vol") ;;
      esac
    done <<EOF
$(docker volume ls --format '{{.Name}}' 2>/dev/null || true)
EOF
  fi
  if [ "$images" = true ]; then
    while read -r img; do
      case "$img" in abx/*) CLEAN_IMAGES+=("$img") ;; esac
    done <<EOF
$(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true)
EOF
    CLEAN_PRUNE=true
  fi

  base="$(_clean_runtime_base)"
  for dir in "$base"/*; do
    if [ -d "$dir/creds" ]; then CLEAN_CREDENTIALS+=("$dir/creds"); fi
    if [ -d "$dir/sessions" ] && _sessions_live "$dir/sessions"; then
      CLEAN_NOTES+=("A session of ${dir##*/} is running, and cleaning stops its sandbox.")
    fi
  done
  return 0
}

# The names in a list, joined by commas. Container entries are "ID NAME", so the name is the part after the space.
_clean_names() {
  local e out=""
  for e in "$@"; do out="${out:+$out, }${e#* }"; done
  printf '%s' "$out"
}

_clean_total() {
  echo $(( ${#CLEAN_CONTAINERS[@]} + ${#CLEAN_NETWORKS[@]} + ${#CLEAN_VOLUMES[@]} + ${#CLEAN_IMAGES[@]} + ${#CLEAN_CREDENTIALS[@]} ))
}

_clean_report() {
  local note
  if [ ${#CLEAN_CONTAINERS[@]} -gt 0 ]; then echo "  containers: $(_clean_names ${CLEAN_CONTAINERS[@]+"${CLEAN_CONTAINERS[@]}"})" >&2; fi
  if [ ${#CLEAN_NETWORKS[@]} -gt 0 ]; then echo "  networks, once empty: $(_clean_names ${CLEAN_NETWORKS[@]+"${CLEAN_NETWORKS[@]}"})" >&2; fi
  if [ ${#CLEAN_VOLUMES[@]} -gt 0 ]; then echo "  volumes: $(_clean_names ${CLEAN_VOLUMES[@]+"${CLEAN_VOLUMES[@]}"})" >&2; fi
  if [ ${#CLEAN_IMAGES[@]} -gt 0 ]; then echo "  images: $(_clean_names ${CLEAN_IMAGES[@]+"${CLEAN_IMAGES[@]}"})" >&2; fi
  if [ "$CLEAN_PRUNE" = true ]; then echo "  dangling images (docker image prune)" >&2; fi
  for dir in ${CLEAN_CREDENTIALS[@]+"${CLEAN_CREDENTIALS[@]}"}; do echo "  Bedrock credentials: $dir" >&2; done
  for note in ${CLEAN_NOTES[@]+"${CLEAN_NOTES[@]}"}; do echo "  note: $note" >&2; done
}

_clean_remove() {
  local e id net vol img dir
  for e in ${CLEAN_CONTAINERS[@]+"${CLEAN_CONTAINERS[@]}"}; do
    id="${e%% *}"
    docker rm -f "$id" >/dev/null 2>&1 || echo "[warning] Couldn't remove container ${e#* }." >&2
  done
  for net in ${CLEAN_NETWORKS[@]+"${CLEAN_NETWORKS[@]}"}; do
    # A network with other containers left on it stays; Docker would refuse to remove it anyway.
    if [ "$(docker network inspect -f '{{len .Containers}}' "$net" 2>/dev/null || true)" = 0 ]; then
      docker network rm "$net" >/dev/null 2>&1 || echo "[warning] Couldn't remove network $net." >&2
    else
      echo "[warning] Kept network $net: other containers still use it." >&2
    fi
  done
  for vol in ${CLEAN_VOLUMES[@]+"${CLEAN_VOLUMES[@]}"}; do
    docker volume rm "$vol" >/dev/null 2>&1 || echo "[warning] Couldn't remove volume $vol." >&2
  done
  for img in ${CLEAN_IMAGES[@]+"${CLEAN_IMAGES[@]}"}; do
    docker image rm "$img" >/dev/null 2>&1 || echo "[warning] Couldn't remove image $img." >&2
  done
  if [ "$CLEAN_PRUNE" = true ]; then docker image prune -f >/dev/null 2>&1 || true; fi
  for dir in ${CLEAN_CREDENTIALS[@]+"${CLEAN_CREDENTIALS[@]}"}; do
    rm -rf "$dir"
  done
  return 0
}

# Usage: abx clean [--all] [--volumes] [--images] [--dry-run] [--yes]
_cmd_clean() {
  local all=false volumes=false images=false yes=false dry_run=false arg reply
  CLEAN_CONTAINERS=(); CLEAN_NETWORKS=(); CLEAN_VOLUMES=(); CLEAN_IMAGES=(); CLEAN_CREDENTIALS=(); CLEAN_NOTES=()
  CLEAN_PRUNE=false
  for arg in ${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}; do
    case "$arg" in
      --all) all=true ;;
      --volumes) volumes=true ;;
      --images) images=true ;;
      --yes) yes=true ;;
      --dry-run) dry_run=true ;;
      *) die "Unknown option for 'abx clean': $arg. Options: --all, --volumes, --images, --dry-run and --yes." ;;
    esac
  done
  if [ "$images" = true ] && [ "$all" != true ]; then
    die "--images removes images that every project shares, so it needs --all."
  fi

  if [ "$all" = true ]; then _clean_plan_all "$volumes" "$images"; else _clean_plan_project "$volumes"; fi

  if [ "$(_clean_total)" = 0 ] && [ "$CLEAN_PRUNE" != true ]; then
    info "Nothing to remove."
    _clean_report
    return 0
  fi
  echo "abx clean will remove:" >&2
  _clean_report
  if [ "$all" = true ]; then
    echo "  Kept: the state directories, and every project's .agent-sandbox/ and .abx/." >&2
  else
    echo "  Kept: the state directory, $PROJECT_DIR/.agent-sandbox/ and $PROJECT_DIR/.abx/." >&2
  fi

  if [ "$dry_run" = true ]; then
    info "Dry run: nothing was removed."
    return 0
  fi
  if [ "$yes" != true ]; then
    if [ ! -t 0 ]; then
      die "abx clean needs confirmation, and this input isn't a terminal. Rerun with --yes to remove the list above."
    fi
    printf 'Remove these? [y/N] ' >&2
    read -r reply || reply=""
    case "$reply" in
      y|Y|yes|YES) ;;
      *) info "Nothing was removed."; return 0 ;;
    esac
  fi
  _clean_remove
  info "Cleaned."
}
