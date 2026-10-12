# agentbox's image user has a fixed UID (501, the macOS default). macOS file sharing hides the
# mismatch, but Linux bind mounts don't, leaving the project read-only to the agent. abx probes
# for that, and on a mismatch rebuilds the image with the user renumbered to the host UID.

OVERRIDE_MARKER="# abx: uid-remap"

# Derived from the project directory and the environment, so this is set once the project is known
# rather than on sourcing.
_image_init_vars() {
  ABX_CONFIG_DIR="${ABX_CONFIG_DIR:-$HOME/.config/agent-sandbox/abx}"
  UID_MARKER="$ABX_STATE/uid-ok"
  UID_STATE="$ABX_STATE/uid-remap.env"
  HOST_UID="$(id -u)"
  PROBE_LOG="$ABX_STATE/probe.log"
  IMAGE_EXTRAS="${ABX_IMAGE_EXTRAS:-$ABX_CONFIG_DIR/Dockerfile.extra}"
}

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
  printf 'services:\n  agent:\n'
  if [ -n "$1" ]; then printf '    image: %s  %s\n    pull_policy: never  %s\n' "$1" "$OVERRIDE_MARKER" "$OVERRIDE_MARKER"; fi
  printf '    volumes:\n      - type: bind  %s\n        source: "%s/%s"  %s\n        target: /workspace/.abx  %s\n        read_only: true  %s\n' \
    "$OVERRIDE_MARKER" "$PROJECT_DIR" "$ABX_DIR" "$OVERRIDE_MARKER" "$OVERRIDE_MARKER" "$OVERRIDE_MARKER"
}

# agentbox seeds the override with its own content, so abx merges two keys into the agent service
# rather than replacing the file, then checks the result through agentbox's merged configuration.
_merge_override() {
  python3 -I "$ABX_HOME/lib/merge_override.py" "$1" "$2" "$3"
}

_write_override() {
  local tag="$1" file status config missing backup=""
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
  status="$(_merge_override "$file" "$tag" "$PROJECT_DIR/$ABX_DIR")" || die "Could not update $file"
  if [ "$status" = conflict ]; then
    rm -f "$backup"
    echo "[error] $file already sets the agent's image or build, so abx won't change it. Merge this in yourself, then rerun abx:" >&2
    _override_snippet "$tag" >&2
    exit 1
  fi
  if [ "$status" = unchanged ]; then
    rm -f "$backup"
    return 0
  fi
  # Each change abx made must show in agentbox's merged configuration, or the file is restored.
  config="$(agentbox compose config 2>/dev/null || true)"
  missing=""
  if [ -n "$tag" ] && ! printf '%s' "$config" | grep -F "$tag" >/dev/null; then missing="new image"; fi
  if [ -z "$missing" ] && ! printf '%s' "$config" | grep -F "target: /workspace/.abx" >/dev/null; then missing="new mount"; fi
  if [ -n "$missing" ]; then
    if [ -n "$backup" ]; then mv -f "$backup" "$file"; else rm -f "$file"; fi
    echo "[error] agentbox's merged configuration didn't pick up the $missing, so $file has been restored. Add this with 'agentbox edit compose':" >&2
    _override_snippet "$tag" >&2
    exit 1
  fi
  rm -f "$backup"
  # Containers started from the previous override don't have the change, so they're recreated.
  _stop_project_containers
  debug "override $status in $file"
}

# The agent can read .abx/ but not write it, so the host's files there can't be changed from inside. Applied
# on every run, whether or not the agent has a derived image.
_ensure_abx_mount() {
  _write_override ""
}

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
      "$dir" > "$ABX_STATE/build.log" 2>&1; then
    tail -n 20 "$ABX_STATE/build.log" >&2
    die "Building $REMAPPED_IMAGE failed; the full log is in $ABX_STATE/build.log"
  fi
}

_write_image_state() {
  _write_uid_state "$UID_STATE" "$1" "$2" "$3" "$4" "$5" "$(_extras_hash)"
}

_stop_project_containers() {
  local ids
  ids="$(_owned_ids)"
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
# that container's user, so only volumes mounted by the agent alone are re-owned. While a container
# of another directory has this project's name, none are: its volumes may be the same ones, and abx
# doesn't inspect containers it doesn't own to find out.
_agent_only_volumes() {
  local ctr="$1" other shared="" vol result=""
  if [ -n "$(_foreign_workdirs)" ]; then
    echo "[warning] Containers of another directory use this project's name, so the agent's volumes are left as they are and may stay unwritable to it. Rename one of the two directories, then rerun abx." >&2
    return 0
  fi
  for other in $(_owned_ids); do
    if [ "$other" != "$ctr" ]; then
      shared="$shared $(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' "$other")"
    fi
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
  # The state was checked by _read_uid_remap, and is never sourced.
  _build_derived_image "$BASE" "$USER_NAME" "$ORIG_USER" "${TARGET_UID:-$HOST_UID}" "$pull"
  _write_override "$REMAPPED_IMAGE"
  _stop_project_containers
  _write_image_state "$BASE" "$USER_NAME" "$ORIG_USER" "$OLD_UID" "${TARGET_UID:-$HOST_UID}"
}

_ensure_uid_match() {
  local probe c_uid c_user state
  if [ "${ABX_SKIP_UID_CHECK:-false}" = true ]; then return 0; fi
  if _state_file "$UID_MARKER" && [ "$(cat "$UID_MARKER")" = "$HOST_UID" ]; then
    if _read_uid_remap "$UID_STATE"; then
      if [ "${EXTRAS_HASH:-none}" != "$(_extras_hash)" ]; then
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
    die "Full output is in $PROBE_LOG. Set ABX_SKIP_UID_CHECK=true to bypass the check."
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
  _read_uid_remap "$UID_STATE" || { info "This project doesn't use a derived image; nothing to rebuild."; return 0; }
  _refresh_derived_image true
  info "Rebuilt from the latest upstream image; the next abx run starts on it."
}
