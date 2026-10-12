# Port publishing: forwards the agent's servers to the host for the length of one session.

# A forwarding container lives only as long as the session: it publishes the ports on the host and
# relays each connection to the same port on the agent, so nothing stays exposed after exit and
# agentbox's own configuration is untouched.
DEFAULT_PORTS="3000-3010,4173,5170-5190,6006,8080-8090"
PORTS_ENABLED=false
PORTS_SPEC=""
PORTS_BIND="127.0.0.1"
PORTS_OWNED=false
FORWARDER_IMAGE="abx/port-forwarder:latest"

# Derived from the project name, so it is set once the project is known rather than on sourcing.
_ports_init_vars() {
  PORTS_CONTAINER="abx-ports-$PROJECT_NAME"
}

# Validates a spec like "3000-3010,5173" and prints the expanded port list.
_expand_ports() {
  local spec="$1" item lo hi total=0 out=""
  for item in $(printf '%s' "$spec" | tr ',' ' '); do
    case "$item" in
      *[!0-9-]*|-*|*-|*-*-*|"") die "Invalid port spec '$item' in '$spec'; use e.g. 3000-3010,5173" ;;
      *-*) lo="${item%-*}"; hi="${item#*-}" ;;
      *) lo="$item"; hi="$item" ;;
    esac
    # The forwarder runs without privileges, so it can only listen on unprivileged ports.
    if [ "$lo" -lt 1024 ] || [ "$hi" -gt 65535 ] || [ "$lo" -gt "$hi" ]; then
      die "Port range '$item' must be within 1024-65535, low to high."
    fi
    total=$(( total + hi - lo + 1 ))
    out="$out $(seq "$lo" "$hi" | tr '\n' ' ')"
  done
  [ "$total" -le 200 ] || die "That's $total ports; publish at most 200."
  printf '%s' "$out"
}

_ensure_forwarder_image() {
  local dir="$ABX_CONFIG_DIR/port-forwarder"
  docker image inspect "$FORWARDER_IMAGE" >/dev/null 2>&1 && return 0
  mkdir -p "$dir"
  printf '%s\n' 'FROM alpine:3' 'RUN apk add --no-cache socat' 'USER nobody' > "$dir/Dockerfile"
  info "Building the port forwarder image..."
  docker build -t "$FORWARDER_IMAGE" "$dir" > "$ABX_STATE/forwarder-build.log" 2>&1 \
    || { tail -n 10 "$ABX_STATE/forwarder-build.log" >&2; return 1; }
}

# Prints a sorted port list in compact form, e.g. "5170 5171 5172 6006" becomes "5170-5172,6006".
_compress_ports() {
  local out="" start="" prev="" p
  for p in "$@"; do
    if [ -n "$start" ] && [ "$p" -eq $(( prev + 1 )) ]; then prev="$p"; continue; fi
    if [ -n "$start" ]; then
      if [ "$start" = "$prev" ]; then out="$out,$start"; else out="$out,$start-$prev"; fi
    fi
    start="$p"; prev="$p"
  done
  if [ -n "$start" ]; then
    if [ "$start" = "$prev" ]; then out="$out,$start"; else out="$out,$start-$prev"; fi
  fi
  printf '%s' "${out#,}"
}

# Prints the ports something on the host already listens on, by trying to bind each one.
_host_ports_in_use() {
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -I "$ABX_HOME/lib/host_ports_in_use.py" "$PORTS_BIND" "$@"
}

_without_port() {
  local drop="$1" p out=""
  shift
  for p in "$@"; do [ "$p" = "$drop" ] || out="$out $p"; done
  printf '%s' "$out"
}

_start_port_forwarder() {
  local ports ctr nets net p err owner busy skipped="" attempt=0 args=()
  ports="$(_expand_ports "$PORTS_SPEC")"

  # A forwarder with this name from another directory is left alone, so the session goes on without ports.
  if [ "$(_sidecar_owner "$PORTS_CONTAINER")" = foreign ]; then
    echo "[warning] A container named $PORTS_CONTAINER belongs to another directory, or to an earlier abx without its project label, so abx won't use it. Continuing without published ports; if it's stale, remove it with docker rm." >&2
    return 0
  fi
  if _owned_sidecar_running "$PORTS_CONTAINER"; then
    owner="$(docker inspect -f '{{index .Config.Labels "abx.owner-pid"}}' "$PORTS_CONTAINER" 2>/dev/null)"
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
      PORTS_SPEC="$(docker inspect -f '{{index .Config.Labels "abx.ports-spec"}}' "$PORTS_CONTAINER" 2>/dev/null)"
      info "Ports $PORTS_SPEC are already published by another abx session for this project."
      return 0
    fi
  fi
  _remove_owned_sidecar "$PORTS_CONTAINER"
  _ensure_forwarder_image || { echo "[warning] Couldn't build the port forwarder; continuing without published ports." >&2; return 0; }

  # The forwarder joins the agent's network, which exists only once the stack is up.
  ctr="$(_running_agent_container)"
  [ -n "$ctr" ] || { echo "[warning] The agent container isn't running; continuing without published ports. See $ABX_STATE/agent-start.log" >&2; return 0; }
  nets="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$ctr")"

  for busy in $(_host_ports_in_use $ports); do
    ports="$(_without_port "$busy" $ports)"
    skipped="$skipped $busy"
  done

  trap _restore_terminal EXIT
  # Ports are published one by one, so a port taken by something the bind check can't see
  # (such as another container's reservation) costs only itself: Docker names it and abx retries.
  while :; do
    if [ -z "$(printf '%s' "$ports" | tr -d ' ')" ]; then
      echo "[warning] All the requested ports are already in use on the host; continuing without published ports." >&2
      return 0
    fi
    PORTS_SPEC="$(_compress_ports $ports)"
    args=()
    for p in $ports; do args+=(-p "$PORTS_BIND:$p:$p"); done
    local -a run=(docker run -d --name "$PORTS_CONTAINER"
      --label "abx.ports-for=$PROJECT_NAME" --label "abx.owner-pid=$$" --label "abx.ports-spec=$PORTS_SPEC"
      --label "abx.project-dir=$PROJECT_DIR"
      --network bridge --cap-drop ALL --security-opt no-new-privileges --read-only
      "${args[@]}" -e "PORTS=$ports" "$FORWARDER_IMAGE"
      sh -c 'for p in $PORTS; do socat TCP-LISTEN:"$p",fork,reuseaddr TCP:agent:"$p" & done; wait')
    # The exact command is kept, quoted, so a failure can be reproduced by hand.
    { printf '%q ' "${run[@]}"; echo; } > "$ABX_STATE/ports.log"
    if err="$("${run[@]}" 2>&1 >/dev/null)"; then break; fi

    printf '%s\n' "$err" >> "$ABX_STATE/ports.log"
    _remove_owned_sidecar "$PORTS_CONTAINER"
    busy="$(printf '%s' "$err" | sed -n 's/.*Bind for .*:\([0-9][0-9]*\) failed.*/\1/p' | head -n1)"
    attempt=$(( attempt + 1 ))
    if [ -n "$busy" ] && [ "$attempt" -le 20 ]; then
      debug "port $busy is already allocated; retrying without it"
      ports="$(_without_port "$busy" $ports)"
      skipped="$skipped $busy"
      continue
    fi
    echo "[warning] Couldn't publish ports; continuing without them. Docker said:" >&2
    printf '%s\n' "$err" | grep -v "^Run 'docker run --help'\|^See 'docker run --help'" | sed 's/^/          /' >&2
    echo "          The command is in $ABX_STATE/ports.log" >&2
    return 0
  done
  for net in $nets; do
    docker network connect "$net" "$PORTS_CONTAINER" >/dev/null 2>&1 \
      || echo "[warning] Couldn't connect the port forwarder to network $net" >&2
  done
  PORTS_OWNED=true

  if [ -n "$skipped" ]; then
    info "Skipping ports already in use on the host: $(_compress_ports $(printf '%s\n' $skipped | sort -n))"
  fi
  if [ "$PORTS_BIND" = "127.0.0.1" ]; then
    info "Publishing ports $PORTS_SPEC on localhost for this session."
  else
    echo "" >&2
    echo "  PORTS ARE OPEN TO THE NETWORK: $PORTS_SPEC on $PORTS_BIND, for this session." >&2
    echo "  Anyone who can reach this machine can reach the agent's servers on them, and Docker's" >&2
    echo "  published ports can bypass host firewall rules such as ufw." >&2
    echo "" >&2
  fi
}

_stop_port_forwarder() {
  if [ "$PORTS_OWNED" = true ]; then _remove_owned_sidecar "$PORTS_CONTAINER"; fi
}
