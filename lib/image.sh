# agentbox's image user has a fixed UID (501, the macOS default). macOS file sharing hides the
# mismatch, but Linux bind mounts don't, leaving the project read-only to the agent. abx probes
# for that, and on a mismatch rebuilds the image with the user renumbered to the host UID.

OVERRIDE_MARKER="# abx: uid-remap"

# Derived from the project directory and the environment, so this is set once the project is known
# rather than on sourcing.
_image_init_vars() {
  ABX_CONFIG_DIR="${ABX_CONFIG_DIR:-$HOME/.config/agent-sandbox/abx}"
  UID_MARKER="$ABX_DIR/uid-ok"
  UID_STATE="$ABX_DIR/uid-remap.env"
  HOST_UID="$(id -u)"
  PROBE_LOG="$ABX_DIR/probe.log"
  IMAGE_EXTRAS="${ABX_IMAGE_EXTRAS:-$ABX_CONFIG_DIR/Dockerfile.extra}"
}

_agent_container() {
  docker ps -q --filter "label=com.docker.compose.project=$PROJECT_NAME" \
    --filter "label=com.docker.compose.service=agent" | head -n1
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
