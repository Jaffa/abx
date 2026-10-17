# agentbox's image user has a fixed UID and group (501, the macOS defaults). macOS file sharing hides the
# mismatch, but Linux bind mounts don't: the project is read-only to the agent, and its files carry the wrong group.
# abx probes for that, and on a mismatch rebuilds the image with the user renumbered to the host UID and its group
# to the host GID.

OVERRIDE_MARKER="# abx: uid-remap"

# Derived from the project directory and the environment, so this is set once the project is known
# rather than on sourcing.
_image_init_vars() {
  ABX_CONFIG_DIR="${ABX_CONFIG_DIR:-$HOME/.config/agent-sandbox/abx}"
  UID_MARKER="$ABX_STATE/uid-ok"
  UID_STATE="$ABX_STATE/uid-remap.env"
  HOST_UID="$(id -u)"
  HOST_GID="$(id -g)"
  PROBE_LOG="$ABX_STATE/probe.log"
  IMAGE_EXTRAS="${ABX_IMAGE_EXTRAS:-$ABX_CONFIG_DIR/Dockerfile.extra}"
  # 'off' means no extras; an empty path is never a file, so nothing is layered in.
  if [ "$IMAGE_EXTRAS" = off ]; then IMAGE_EXTRAS=""; fi
}

# Everything agentbox prints is kept in the probe log, since a failure here is otherwise opaque.
_probe_container() {
  local raw
  raw="$(agentbox exec sh -c 'printf "%s %s %s " "$(id -u)" "$(id -un 2>/dev/null || echo unknown)" "$(id -g)"; if touch .abx-write-probe 2>/dev/null; then rm -f .abx-write-probe; echo writable; else echo readonly; fi' 2>&1)" || true
  printf '%s\n' "$raw" > "$PROBE_LOG"
  printf '%s\n' "$raw" | tr -d '\r' | grep -E '^[0-9]+ [^ ]+ [0-9]+ (writable|readonly)$' | tail -n1 || true
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

# The directories abx mounts read-only in the agent, as TARGET=SOURCE: its own state, and Claude Code's configuration
# (see lib/claude.sh) when present.
_override_mounts() {
  OVERRIDE_MOUNTS=("/workspace/.abx=$PROJECT_DIR/$ABX_DIR")
  if [ -n "$CLAUDE_HOST" ]; then OVERRIDE_MOUNTS+=("$CLAUDE_DIR_TARGET=$CLAUDE_HOST"); fi
  if [ -n "$BASE_CLAUDE_HOST" ]; then OVERRIDE_MOUNTS+=("$BASE_CLAUDE_TARGET=$BASE_CLAUDE_HOST"); fi
}

_override_snippet() {
  local m
  printf 'services:\n  agent:\n'
  if [ -n "$1" ]; then printf '    image: %s  %s\n    pull_policy: never  %s\n' "$1" "$OVERRIDE_MARKER" "$OVERRIDE_MARKER"; fi
  printf '    volumes:\n'
  for m in "${OVERRIDE_MOUNTS[@]}"; do
    printf '      - type: bind  %s\n        source: "%s"  %s\n        target: %s  %s\n        read_only: true  %s\n' \
      "$OVERRIDE_MARKER" "${m#*=}" "$OVERRIDE_MARKER" "${m%%=*}" "$OVERRIDE_MARKER" "$OVERRIDE_MARKER"
  done
}

# agentbox seeds the override with its own content, so abx merges its keys into the agent service
# rather than replacing the file, then checks the result through agentbox's merged configuration.
_merge_override() {
  python3 -I "$ABX_HOME/lib/merge_override.py" "$1" "$2" "${OVERRIDE_MOUNTS[@]}"
}

_write_override() {
  local tag="$1" file status config missing backup="" m
  command -v python3 >/dev/null 2>&1 || die "python3 is needed to update agentbox's compose override."
  _override_mounts
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
  if [ "$status" = unchanged ]; then
    rm -f "$backup"
    return 0
  fi
  # Each change abx made must show in agentbox's merged configuration, or the file is restored.
  config="$(agentbox compose config 2>/dev/null || true)"
  missing=""
  if [ -n "$tag" ] && ! printf '%s' "$config" | grep -F "$tag" >/dev/null; then missing="new image"; fi
  for m in "${OVERRIDE_MOUNTS[@]}"; do
    if [ -z "$missing" ] && ! printf '%s' "$config" | grep -F "target: ${m%%=*}" >/dev/null; then missing="new mount"; fi
  done
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

# The agent can read .abx/ and Claude Code's configuration but not write them, so the host's files there can't be
# changed from inside. Applied on every run, whether or not the agent has a derived image, so a configuration directory
# that's added or removed takes effect on the next run.
_ensure_abx_mount() {
  _write_override ""
}

_has_image_additions() {
  [ -f "$IMAGE_EXTRAS" ]
}

# A change to the extras triggers a rebuild, so the hash of the file is stored.
_extras_hash() {
  if ! _has_image_additions; then echo none; return 0; fi
  _sha16 < "$IMAGE_EXTRAS"
}

# Builds the image abx points the agent service at: the upstream image with the agent user renumbered to target_uid
# and its group to target_gid (a no-op when they already match), plus any image extras. The labels record the
# derived-image state, so it can be rebuilt if the state directory is lost.
_build_derived_image() { # BASE USER ORIG_USER OLD_UID OLD_GID TARGET_UID TARGET_GID [PULL]
  local base="$1" user="$2" orig_user="$3" old_uid="$4" old_gid="$5" target_uid="$6" target_gid="$7" pull="${8:-false}" \
    name repo tag dir flags=() labels=()
  name="${base##*/}"; name="${name%%@*}"
  repo="${name%%:*}"
  tag="latest"
  case "$name" in *:*) tag="${name#*:}" ;; esac
  REMAPPED_IMAGE="abx/${repo}-uid${target_uid}:${tag}"

  dir="$(_cache_dir)/uid-remap"
  mkdir -p "$dir"
  {
    cat <<'EOF'
ARG BASE
FROM ${BASE}
ARG HOST_UID
ARG HOST_GID
ARG USER_NAME
ARG ORIG_USER=root
USER root
# Another account already holding the host UID (e.g. 'node') is moved out of the way first.
RUN other="$(getent passwd "${HOST_UID}" | cut -d: -f1)" \
 && if [ -n "$other" ] && [ "$other" != "${USER_NAME}" ]; then usermod -u 59999 "$other"; fi \
 && old_uid="$(id -u "${USER_NAME}")" \
 && usermod -u "${HOST_UID}" "${USER_NAME}" \
 && (find / -xdev -uid "${old_uid}" -exec chown -h "${HOST_UID}" {} + 2>/dev/null || true)
# The group follows the same steps. groupmod leaves the GID recorded in /etc/passwd, so usermod -g sets the user's
# primary group again, and the accounts of a group moved aside are pointed at its new GID.
RUN group="$(id -gn "${USER_NAME}")" \
 && other="$(getent group "${HOST_GID}" | cut -d: -f1)" \
 && if [ -n "$other" ] && [ "$other" != "$group" ]; then groupmod -g 59999 "$other" \
    && for u in $(awk -F: -v g="${HOST_GID}" '$4 == g { print $1 }' /etc/passwd); do usermod -g "$other" "$u"; done; fi \
 && old_gid="$(id -g "${USER_NAME}")" \
 && groupmod -g "${HOST_GID}" "$group" \
 && usermod -g "$group" "${USER_NAME}" \
 && (find / -xdev -gid "${old_gid}" -exec chgrp -h "${HOST_GID}" {} + 2>/dev/null || true)
EOF
    if [ -f "$IMAGE_EXTRAS" ]; then
      printf '\n# Image extras from %s (run as root)\n' "$IMAGE_EXTRAS"
      cat "$IMAGE_EXTRAS"
      printf '\nUSER root\n'
    fi
    printf '%s\n' 'USER ${ORIG_USER}'
  } > "$dir/Dockerfile"

  if [ "$pull" = true ]; then flags=(--pull); fi
  labels=(--label "abx.base=$base" --label "abx.user=$user" --label "abx.orig-user=${orig_user:-root}"
    --label "abx.old-uid=$old_uid" --label "abx.old-gid=$old_gid" --label "abx.target-uid=$target_uid"
    --label "abx.target-gid=$target_gid")
  info "Building $REMAPPED_IMAGE$( _has_image_additions && printf ' with abx additions')..."
  if ! docker build ${flags[@]+"${flags[@]}"} ${labels[@]+"${labels[@]}"} -t "$REMAPPED_IMAGE" \
      --build-arg "BASE=$base" --build-arg "HOST_UID=$target_uid" --build-arg "HOST_GID=$target_gid" \
      --build-arg "USER_NAME=$user" --build-arg "ORIG_USER=${orig_user:-root}" \
      "$dir" > "$ABX_STATE/build.log" 2>&1; then
    tail -n 20 "$ABX_STATE/build.log" >&2
    die "Building $REMAPPED_IMAGE failed; the full log is in $ABX_STATE/build.log"
  fi
}

_write_image_state() { # BASE USER ORIG_USER OLD_UID OLD_GID TARGET_UID TARGET_GID
  _write_uid_state "$UID_STATE" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$(_extras_hash)"
}

_stop_project_containers() {
  local ids
  ids="$(_owned_ids)"
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086
    docker rm -f $ids >/dev/null
  fi
}

# Re-owns the files in each volume from OLD_UID:OLD_GID to the new IDs. The IDs are passed as arguments, not
# spliced into the script.
_reown_volumes() { # OLD_UID OLD_GID TARGET_UID TARGET_GID VOLUME...
  local old_uid="$1" old_gid="$2" target_uid="$3" target_gid="$4" vol
  shift 4
  for vol in "$@"; do
    debug "re-owning files in volume $vol from UID $old_uid:GID $old_gid to $target_uid:$target_gid"
    docker run --rm --network none -u 0 --entrypoint sh -v "$vol:/v" "$REMAPPED_IMAGE" \
      -c 'find /v -xdev -uid "$1" -exec chown -h "$2" {} + ; find /v -xdev -gid "$3" -exec chgrp -h "$4" {} +' \
      sh "$old_uid" "$target_uid" "$old_gid" "$target_gid" \
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

# The value of label KEY on IMAGE, or nothing if the image has no such label.
_image_label() {
  docker image inspect -f "{{index .Config.Labels \"$2\"}}" "$1" 2>/dev/null || true
}

# Reads the derived-image record from the abx.* labels that _build_derived_image writes. On success it sets the same
# values as _read_uid_remap, with no extras hash, since the labels don't record the extras. On failure it sets
# RECORD_PROBLEM to the label that's missing or the reason it's invalid. Labels are text that anyone who can build
# the image can write, so they're checked as state files are. The group labels may be absent, in an image built before
# the group was renumbered.
_read_uid_remap_labels() { # IMAGE
  local base user orig old old_gid target target_gid
  base="$(_image_label "$1" abx.base)"
  user="$(_image_label "$1" abx.user)"
  orig="$(_image_label "$1" abx.orig-user)"
  old="$(_image_label "$1" abx.old-uid)"
  old_gid="$(_image_label "$1" abx.old-gid)"
  target="$(_image_label "$1" abx.target-uid)"
  target_gid="$(_image_label "$1" abx.target-gid)"
  if [ -z "$base" ] || [ -z "$user" ] || [ -z "$orig" ] || [ -z "$old" ] || [ -z "$target" ]; then
    RECORD_PROBLEM="a label is missing"
    return 1
  fi
  RECORD_PROBLEM="$(_uid_remap_problem "$base" "$user" "$orig" "$old" "$old_gid" "$target" "$target_gid" none)" \
    || return 1
  BASE="$base"; USER_NAME="$user"; ORIG_USER="$orig"; OLD_UID="$old"; OLD_GID="$old_gid"
  TARGET_UID="$target"; TARGET_GID="$target_gid"; EXTRAS_HASH=none
}

# The agent runs a derived image that abx has no state record for, as after a lost state directory. The record is
# rebuilt from the image's labels and written, and the image is then rebuilt from its base as usual. If a valid
# record exists, its base is used. Sets BASE to the upstream image.
_recover_derived_record() { # IMAGE
  if _read_uid_remap "$UID_STATE"; then return 0; fi
  if ! _read_uid_remap_labels "$1"; then
    die "The agent runs $1, but abx has no record of building it, and the image's abx.* labels are missing or invalid ($RECORD_PROBLEM). Run 'abx clean', then rerun abx."
  fi
  _write_uid_state "$UID_STATE" "$BASE" "$USER_NAME" "$ORIG_USER" "$OLD_UID" "$OLD_GID" "$TARGET_UID" "$TARGET_GID" none
  info "Recovered the derived-image record for $1 from its labels."
}

# First switch of a project to a derived image, from the running upstream container. The IDs passed in are the running
# container's: the files the agent wrote carry them, so they're what the volumes are re-owned from.
_apply_derived_image() { # UID GID USER TARGET_UID TARGET_GID
  local c_uid="$1" c_gid="$2" c_user="$3" target_uid="$4" target_gid="$5" ctr base orig_user volumes=""
  ctr="$(_agent_container)"
  [ -n "$ctr" ] || die "Couldn't find the running agent container for project '$PROJECT_NAME' to inspect."
  base="$(docker inspect -f '{{.Config.Image}}' "$ctr")"
  case "$base" in
    abx/*) _recover_derived_record "$base"; base="$BASE" ;;
  esac
  orig_user="$(docker image inspect -f '{{.Config.User}}' "$base" 2>/dev/null || true)"
  if [ "$c_uid" != "$target_uid" ] || [ "$c_gid" != "$target_gid" ]; then
    volumes="$(_agent_only_volumes "$ctr")"
  fi
  if [ "$c_uid" != "$target_uid" ]; then
    info "The agent runs as UID $c_uid but your files belong to UID $target_uid, so it can't write to the project. Fixing..."
  fi
  if [ "$c_gid" != "$target_gid" ]; then
    info "The agent's group is GID $c_gid but your files belong to GID $target_gid. Fixing..."
  fi

  _build_derived_image "$base" "$c_user" "$orig_user" "$c_uid" "$c_gid" "$target_uid" "$target_gid"
  _write_override "$REMAPPED_IMAGE"
  _stop_project_containers
  if [ -n "$volumes" ]; then
    # shellcheck disable=SC2086
    _reown_volumes "$c_uid" "$c_gid" "$target_uid" "$target_gid" $volumes
  fi

  _write_image_state "$base" "$c_user" "$orig_user" "$c_uid" "$c_gid" "$target_uid" "$target_gid"
  printf '%s %s\n' "$HOST_UID" "$HOST_GID" > "$UID_MARKER"
  if [ "$c_uid" != "$target_uid" ] || [ "$c_gid" != "$target_gid" ]; then
    info "Done: the agent will run as UID $target_uid and GID $target_gid from now on."
  fi
}

# Rebuild for a project already on a derived image, e.g. new extras or a newer upstream image. A record from before the
# group was renumbered has no TARGET_GID, so the host's group is used.
_refresh_derived_image() {
  local pull="$1" target_uid="${TARGET_UID:-$HOST_UID}" target_gid="${TARGET_GID:-$HOST_GID}"
  # The state was checked by _read_uid_remap, and is never sourced.
  _build_derived_image "$BASE" "$USER_NAME" "$ORIG_USER" "$OLD_UID" "$OLD_GID" "$target_uid" "$target_gid" "$pull"
  _write_override "$REMAPPED_IMAGE"
  _stop_project_containers
  _write_image_state "$BASE" "$USER_NAME" "$ORIG_USER" "$OLD_UID" "$OLD_GID" "$target_uid" "$target_gid"
}

# Whether the derived image's record says abx renumbered the agent's UID. A record that says so is for a Linux host, and
# its group is renumbered with the UID. A macOS host's UID already matches, so its group is left alone.
_record_renumbers_uid() {
  _read_uid_remap "$UID_STATE" && [ "$OLD_UID" != "$TARGET_UID" ]
}

_ensure_uid_match() {
  local probe c_uid c_gid c_user state
  if [ "${ABX_SKIP_UID_CHECK:-false}" = true ]; then return 0; fi
  if _state_file "$UID_MARKER" && [ "$(cat "$UID_MARKER")" = "$HOST_UID $HOST_GID" ]; then
    if _read_uid_remap "$UID_STATE"; then
      if [ "${EXTRAS_HASH:-none}" != "$(_extras_hash)" ]; then
        info "abx's record of the image extras is out of date; rebuilding."
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
  read -r c_uid c_user c_gid state <<< "$probe"
  debug "container user $c_user ($c_uid:$c_gid), project is $state"

  if [ "$state" != writable ]; then
    [ "$c_uid" != "$HOST_UID" ] || die "The agent (UID $c_uid) can't write to the project even though the UIDs match. Check for SELinux labels or read-only mounts."
    _apply_derived_image "$c_uid" "$c_gid" "$c_user" "$HOST_UID" "$HOST_GID"
  elif [ "$c_uid" = "$HOST_UID" ] && [ "$c_gid" != "$HOST_GID" ] && _record_renumbers_uid; then
    # A derived image from before the group was renumbered: its UID is right but its files still carry the old group.
    _apply_derived_image "$c_uid" "$c_gid" "$c_user" "$HOST_UID" "$HOST_GID"
  elif _has_image_additions; then
    _apply_derived_image "$c_uid" "$c_gid" "$c_user" "$c_uid" "$c_gid"
  else
    printf '%s %s\n' "$HOST_UID" "$HOST_GID" > "$UID_MARKER"
  fi
}

_cmd_rebuild() {
  _read_uid_remap "$UID_STATE" || { info "This project doesn't use a derived image; nothing to rebuild."; return 0; }
  _refresh_derived_image true
  info "Rebuilt from the latest upstream image; the next abx run starts on it."
}
