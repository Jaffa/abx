# Outbound TCP: lets the agent open TCP connections to named IPv4 endpoints, such as a device on the LAN, which the proxy
# can't carry (it speaks only HTTP and HTTPS, and the firewall drops everything else). A relay container runs beside the
# sandbox on the project network, under the alias abx-outbound, and forwards each port to its one endpoint and nothing
# else. The agent's own firewall is untouched.

OUTBOUND_ALIAS="abx-outbound"
OUTBOUND_SPEC_RE='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3}):([0-9]{1,5})$'
# A label read back from Docker is checked before use, as state files are.
OUTBOUND_LABEL_RE='^[0-9.:,]+$'
OUTBOUND_SPECS=""
OUTBOUND_OWNED=false

# Derived from the project name, so it is set once the project is known rather than on sourcing.
_outbound_init_vars() {
  OUTBOUND_CONTAINER="abx-outbound-$PROJECT_NAME"
}

# Validates the --outbound-tcp arguments and sets OUTBOUND_SPECS to the normalised list, comma-separated as the flag
# is. It runs before anything is changed, so a bad value stops abx before the sandbox is touched.
_outbound_parse() {
  local arg a b c d e ip port seen=" " spec=""
  [ "${#OUTBOUND_ARGS[@]}" -gt 0 ] || return 0
  for arg in "${OUTBOUND_ARGS[@]}"; do
    if ! [[ "$arg" =~ $OUTBOUND_SPEC_RE ]]; then
      die "'$arg' isn't IP:PORT. Give an IPv4 address and a port, e.g. --outbound-tcp 192.168.1.50:5555. Names aren't looked up, so use the address."
    fi
    # Leading zeros would otherwise be read as octal, so every number is read in base 10.
    a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]})); c=$((10#${BASH_REMATCH[3]}))
    d=$((10#${BASH_REMATCH[4]})); e=$((10#${BASH_REMATCH[5]}))
    if [ "$a" -gt 255 ] || [ "$b" -gt 255 ] || [ "$c" -gt 255 ] || [ "$d" -gt 255 ]; then
      die "'$arg' isn't IP:PORT: an IPv4 address's numbers go up to 255."
    fi
    ip="$a.$b.$c.$d"; port="$e"
    if [ "$a" -eq 0 ] || [ "$a" -eq 127 ] || [ "$a" -ge 224 ] || { [ "$a" -eq 169 ] && [ "$b" -eq 254 ]; }; then
      die "$ip can't be relayed: loopback, link-local, multicast and unspecified addresses are refused."
    fi
    # The relay listens on the endpoint's port without privileges, as the port forwarder does.
    if [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ]; then
      die "Port $port in '$arg' must be within 1024-65535: the relay listens on the endpoint's own port."
    fi
    case "$seen" in
      *" $port "*) die "Two endpoints use port $port. The agent reaches each endpoint through the relay on its own port, so the ports must differ." ;;
    esac
    seen="$seen$port "
    if ! _outbound_is_private "$ip"; then
      echo "[warning] $ip isn't on a private network. The agent can reach it through the relay whatever the domain allowlist says." >&2
    fi
    spec="${spec:+$spec,}$ip:$port"
  done
  OUTBOUND_SPECS="$spec"
}

# Whether IP is in one of the private ranges (RFC 1918).
_outbound_is_private() {
  local a b rest
  a="${1%%.*}"; rest="${1#*.}"; b="${rest%%.*}"
  [ "$a" -eq 10 ] && return 0
  [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 0
  [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 0
  return 1
}

# The relay sits on the bridge and the agent's network, so the host itself is reachable through their gateway
# addresses. Refused, since that would expose the host's own services, such as an adb server on port 5037, to the agent.
_outbound_refuse_host_addresses() { # NETWORK...
  local net gateways spec ip
  for net in "$@"; do
    gateways="$(docker network inspect -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' "$net" 2>/dev/null || true)"
    for spec in $(printf '%s' "$OUTBOUND_SPECS" | tr ',' ' '); do
      ip="${spec%:*}"
      case " $gateways " in
        *" $ip "*) die "$ip is this machine's address on Docker network $net, so the relay would reach the host's own services. Choose the device's address instead." ;;
      esac
    done
  done
}

# Whether this session's endpoints all appear in the label LABEL of a running relay.
_outbound_covers() { # LABEL
  local spec
  for spec in $(printf '%s' "$OUTBOUND_SPECS" | tr ',' ' '); do
    case ",$1," in *",$spec,"*) ;; *) return 1 ;; esac
  done
}

_start_outbound_relay() {
  local owner label ctr nets net err
  local -a run
  trap _restore_terminal EXIT

  if [ "$(_sidecar_owner "$OUTBOUND_CONTAINER")" = foreign ]; then
    die "A container named $OUTBOUND_CONTAINER belongs to another directory, or to an earlier abx without its project label, so the outbound relay can't use that name. If it's stale, remove it with 'docker rm -f $OUTBOUND_CONTAINER' and rerun abx; otherwise rename one of the two directories."
  fi
  # A relay that a live session of this project started is shared, if it has every endpoint this session asked for.
  if _owned_sidecar_running "$OUTBOUND_CONTAINER"; then
    owner="$(docker inspect -f '{{index .Config.Labels "abx.owner-pid"}}' "$OUTBOUND_CONTAINER" 2>/dev/null || true)"
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
      label="$(docker inspect -f '{{index .Config.Labels "abx.outbound-spec"}}' "$OUTBOUND_CONTAINER" 2>/dev/null || true)"
      [[ "$label" =~ $OUTBOUND_LABEL_RE ]] || label=""
      if ! _outbound_covers "$label"; then
        die "Another abx session for this project is relaying ${label:-nothing}, which doesn't include $OUTBOUND_SPECS. Exit that session, then rerun abx."
      fi
      OUTBOUND_SPECS="$label"
      info "Relaying TCP to $label is already set up by another abx session for this project."
      return 0
    fi
  fi
  _remove_owned_sidecar "$OUTBOUND_CONTAINER"
  _ensure_forwarder_image || die "Couldn't build the relay image; see $ABX_STATE/forwarder-build.log"

  # The relay joins the agent's network, which exists only once the stack is up.
  ctr="$(_running_agent_container)"
  [ -n "$ctr" ] || _explain_missing_agent "The agent container isn't running, so the outbound relay can't join its network."
  nets="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$ctr")"
  _outbound_refuse_host_addresses bridge $nets

  # The relay splits its endpoints on commas, as the flag and the settings do, and forwards each port to its endpoint.
  run=(docker run -d --name "$OUTBOUND_CONTAINER"
    --label "abx.outbound-for=$PROJECT_NAME" --label "abx.owner-pid=$$" --label "abx.outbound-spec=$OUTBOUND_SPECS"
    --label "abx.project-dir=$PROJECT_DIR"
    --network bridge --cap-drop ALL --security-opt no-new-privileges --read-only
    -e "OUTBOUND=$OUTBOUND_SPECS" "$FORWARDER_IMAGE"
    sh -c 'IFS=,; for e in $OUTBOUND; do socat TCP-LISTEN:"${e##*:}",fork,reuseaddr TCP:"${e%:*}":"${e##*:}" & done; wait')
  # The exact command is kept, quoted, so a failure can be reproduced by hand.
  { printf '%q ' "${run[@]}"; echo; } > "$ABX_STATE/outbound.log"
  if ! err="$("${run[@]}" 2>&1 >/dev/null)"; then
    printf '%s\n' "$err" >> "$ABX_STATE/outbound.log"
    die "Couldn't start the outbound relay. Docker said: $err The command is in $ABX_STATE/outbound.log"
  fi
  for net in $nets; do
    if ! docker network connect --alias "$OUTBOUND_ALIAS" "$net" "$OUTBOUND_CONTAINER" >/dev/null 2>&1; then
      _remove_owned_sidecar "$OUTBOUND_CONTAINER"
      die "Couldn't connect the outbound relay to network $net, so the agent couldn't reach it."
    fi
  done
  OUTBOUND_OWNED=true
  info "Relaying TCP to $OUTBOUND_SPECS for this session. Connect to host $OUTBOUND_ALIAS on the same port."
}

# The relay is shared with other sessions, so it goes only once none are left.
_stop_outbound_relay() {
  [ -n "$OUTBOUND_SPECS" ] || return 0
  if [ -z "$(_live_sessions)" ]; then _remove_owned_sidecar "$OUTBOUND_CONTAINER"; fi
}
