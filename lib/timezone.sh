# The sandbox's time zone. agentbox's compose file sets the agent's TZ from the host's TZ, falling back to
# America/Los_Angeles when TZ is unset, and most Linux hosts leave TZ unset. So abx works the host's zone out from
# the system and exports it, and recreates a sandbox whose containers were made for another zone.

TZ_ZONE_RE='^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$'

# The zone /etc/localtime links to, such as Europe/London. macOS links into /var/db/timezone, which still ends in zoneinfo/.
_zone_from_localtime() {
  local target
  [ -L /etc/localtime ] || return 0
  target="$(readlink /etc/localtime 2>/dev/null || true)"
  case "$target" in *zoneinfo/*) printf '%s' "${target##*zoneinfo/}" ;; esac
  return 0
}

# Debian and Ubuntu name the zone in /etc/timezone, for hosts whose /etc/localtime is a copy rather than a link.
_zone_from_etc_timezone() {
  [ -f /etc/timezone ] || return 0
  head -n 1 /etc/timezone 2>/dev/null | tr -d '[:space:]' || true
}

# Sets HOST_TZ, the zone the sandbox runs in, and exports it for agentbox's compose file. A TZ the user has set is
# used as it is, which is what compose would do anyway.
_timezone_init_vars() {
  if [ -n "${TZ:-}" ]; then
    HOST_TZ="$TZ"
    return 0
  fi
  HOST_TZ="$(_zone_from_localtime)"
  [ -n "$HOST_TZ" ] || HOST_TZ="$(_zone_from_etc_timezone)"
  # The name comes from a file on the host, so it's checked before it goes anywhere.
  if ! [[ "$HOST_TZ" =~ $TZ_ZONE_RE ]]; then
    echo "[warning] Couldn't work out this host's time zone, so the sandbox clock will be UTC. Set TZ to yours, e.g. TZ=Europe/London, to change that." >&2
    HOST_TZ=UTC
  fi
  export TZ="$HOST_TZ"
}

# A container keeps the TZ it was created with, so one made for another zone is removed here. The next agentbox exec
# starts a new one with HOST_TZ.
_ensure_timezone() {
  local id tz
  for id in $(_owned_ids agent); do
    tz="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$id" 2>/dev/null | sed -n 's/^TZ=//p' || true)"
    if [ "$tz" != "$HOST_TZ" ]; then
      _require_no_live_session "The sandbox's clock uses ${tz:-no time zone} but this host's is $HOST_TZ, so its containers need recreating"
      info "Recreating the sandbox containers so their clock uses $HOST_TZ (they used ${tz:-no time zone})."
      _stop_project_containers
      return 0
    fi
  done
}
