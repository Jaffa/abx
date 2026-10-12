# Bedrock mode (--bedrock): AWS credentials come from a host profile, are refreshed in the background
# while a session runs, and are held by a signing gateway beside the agent, never by the agent itself.

BEDROCK_ENABLED=false
BEDROCK_REGION=""
REFRESHER_PID=""

_export_bedrock_credentials() {
  local tmp
  tmp="$(mktemp "$ABX_RUNTIME_DIR/creds/.credentials.XXXXXX")"
  if aws configure export-credentials --profile "$BEDROCK_PROFILE" --format process > "$tmp" 2>>"$REFRESH_LOG"; then
    chmod 600 "$tmp"
    mv -f "$tmp" "$CREDS_FILE"
  else
    rm -f "$tmp"
    return 1
  fi
}

_disable_bedrock() {
  rm -f "$BEDROCK_MARKER" "$CREDS_FILE" "$LEGACY_CREDS_FILE" "$REFRESH_LOG"
  info "Bedrock mode is off for this project."
}

_prepare_bedrock() {
  local region
  command -v aws >/dev/null 2>&1 || die "Bedrock mode needs the AWS CLI on the host."
  mkdir -p "$ABX_DIR" "$ABX_RUNTIME_DIR/creds"
  chmod 700 "$ABX_DIR" "$(dirname "$ABX_RUNTIME_DIR")" "$ABX_RUNTIME_DIR" "$ABX_RUNTIME_DIR/creds"
  _exclude_path "$ABX_DIR/"
  printf '%s\n' "$BEDROCK_PROFILE" > "$BEDROCK_MARKER"
  # Earlier versions kept credentials in the project, where the agent could read them.
  rm -f "$LEGACY_CREDS_FILE"

  : > "$REFRESH_LOG"
  _export_bedrock_credentials \
    || die "Could not get credentials from AWS profile '$BEDROCK_PROFILE': $(tr '\n' ' ' < "$REFRESH_LOG")
        If your admin identity uses SSO, run 'aws sso login --profile <admin profile>' and retry."

  region="$(aws configure get region --profile "$BEDROCK_PROFILE" 2>/dev/null || true)"
  [ -n "$region" ] || die "AWS profile '$BEDROCK_PROFILE' has no region; set one with: aws configure set region <region> --profile $BEDROCK_PROFILE"
  BEDROCK_REGION="$region"
  info "Bedrock: profile $BEDROCK_PROFILE, region $region, via the abx gateway (credentials refreshed every ${ABX_BEDROCK_REFRESH:-600}s)"
}

_start_refresher() {
  (
    sleeper=""
    # 'wait' is interruptible where a foreground sleep is not, so the loop stops as soon as abx exits.
    trap 'if [ -n "$sleeper" ]; then kill "$sleeper" 2>/dev/null; fi; exit 0' TERM
    while :; do
      sleep "${ABX_BEDROCK_REFRESH:-600}" &
      sleeper=$!
      wait "$sleeper" || true
      _export_bedrock_credentials || true
    done
  ) &
  REFRESHER_PID=$!
}

# The signer runs in its own container, holds the credentials and signs Claude Code's requests, so
# nothing in the agent container (or the project directory it can read) carries AWS credentials,
# and Bedrock traffic doesn't pass through agentbox's proxy or need allowlist entries.
GATEWAY_ALIAS="abx-gateway"
GATEWAY_PORT=8787
GATEWAY_NO_PROXY=""

# Derived from the project directory, so this is set once the project is known rather than on sourcing.
_bedrock_init_vars() {
  BEDROCK_MARKER="$ABX_DIR/bedrock-profile"
  # Credentials stay outside the project, which the agent can read, in a private per-user directory.
  ABX_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$HOME/.cache}/abx/$PROJECT_NAME"
  CREDS_FILE="$ABX_RUNTIME_DIR/creds/aws-credentials.json"
  LEGACY_CREDS_FILE="$ABX_DIR/aws-credentials.json"
  REFRESH_LOG="$ABX_DIR/refresh.log"
  CLAUDE_LOCAL_SETTINGS=".claude/settings.local.json"
  BEDROCK_PROFILE="${ABX_BEDROCK_PROFILE:-claude-bedrock}"
  GATEWAY_CONTAINER="abx-gateway-$PROJECT_NAME"
  SESSIONS_DIR="$ABX_RUNTIME_DIR/sessions"
  case "$BEDROCK_MODE" in
    on) BEDROCK_ENABLED=true ;;
    off) _disable_bedrock ;;
    *)
      if [ -f "$BEDROCK_MARKER" ]; then
        BEDROCK_ENABLED=true
        if [ -z "${ABX_BEDROCK_PROFILE:-}" ]; then BEDROCK_PROFILE="$(head -n1 "$BEDROCK_MARKER")"; fi
      fi
      ;;
  esac
}

# Gateway sessions are tracked by PID so the gateway outlives any one of several concurrent sessions.
_other_gateway_sessions_alive() {
  local f pid
  for f in "$SESSIONS_DIR"/*; do
    [ -f "$f" ] || continue
    pid="$(basename "$f")"
    [ "$pid" = "$$" ] && continue
    if kill -0 "$pid" 2>/dev/null; then return 0; fi
    rm -f "$f"
  done
  return 1
}

# agentbox's output is kept in a log, since a stack that won't start is otherwise invisible here.
_running_agent_container() {
  local ctr
  ctr="$(_agent_container)"
  if [ -z "$ctr" ]; then
    agentbox exec true > "$ABX_DIR/agent-start.log" 2>&1 || true
    ctr="$(_agent_container)"
  fi
  printf '%s' "$ctr"
}

_explain_missing_agent() {
  echo "[error] $1" >&2
  if [ -s "$ABX_DIR/agent-start.log" ]; then
    echo "        Starting the sandbox printed:" >&2
    tail -n 15 "$ABX_DIR/agent-start.log" | sed 's/^/          /' >&2
  fi
  echo "        Containers for project '$PROJECT_NAME':" >&2
  docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" \
    --format '          {{.Names}}  {{.Status}}' >&2 2>/dev/null
  if [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT_NAME")" ]; then
    echo "          (none: check 'docker ps -a' for this project's containers under another name)" >&2
  fi
  local name
  for name in $(docker ps -a --filter "label=com.docker.compose.project=$PROJECT_NAME" --filter status=exited --format '{{.Names}}'); do
    echo "        Last lines from $name:" >&2
    docker logs "$name" 2>&1 | tail -n 10 | sed 's/^/          /' >&2
  done
  exit 1
}

_ensure_signer_image() {
  local src dir tag
  src="$(_resources_dir)/abx-bedrock-signer.py"
  [ -f "$src" ] || die "Bedrock mode needs $src, which is part of abx; is the installation complete?"
  tag="abx/bedrock-signer:$(_sha16 < "$src")"
  SIGNER_IMAGE="$tag"
  docker image inspect "$tag" >/dev/null 2>&1 && return 0
  dir="$ABX_CONFIG_DIR/bedrock-signer"
  mkdir -p "$dir"
  cp "$src" "$dir/signer.py"
  printf '%s\n' 'FROM python:3-alpine' 'COPY signer.py /app/signer.py' \
    'ENTRYPOINT ["python3", "-u", "/app/signer.py"]' > "$dir/Dockerfile"
  info "Building the Bedrock signer image..."
  docker build -t "$tag" "$dir" > "$ABX_DIR/signer-build.log" 2>&1 \
    || { tail -n 10 "$ABX_DIR/signer-build.log" >&2; die "Building the Bedrock signer failed; see $PROJECT_DIR/$ABX_DIR/signer-build.log"; }
}

_start_bedrock_gateway() {
  local ctr nets net i no_proxy
  mkdir -p "$SESSIONS_DIR"
  : > "$SESSIONS_DIR/$$"
  trap _restore_terminal EXIT

  ctr="$(_running_agent_container)"
  [ -n "$ctr" ] || _explain_missing_agent "The agent container isn't running, so the Bedrock gateway can't join its network."

  no_proxy="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$ctr" | sed -n 's/^NO_PROXY=//p' | head -n1)"
  [ -n "$no_proxy" ] || no_proxy="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$ctr" | sed -n 's/^no_proxy=//p' | head -n1)"
  GATEWAY_NO_PROXY="${no_proxy:-localhost,127.0.0.1}"
  case ",$GATEWAY_NO_PROXY," in *",$GATEWAY_ALIAS,"*) ;; *) GATEWAY_NO_PROXY="$GATEWAY_NO_PROXY,$GATEWAY_ALIAS" ;; esac

  if [ "$(docker inspect -f '{{.State.Running}}' "$GATEWAY_CONTAINER" 2>/dev/null)" = true ] && _other_gateway_sessions_alive; then
    debug "reusing the Bedrock gateway of another session"
    return 0
  fi
  docker rm -f "$GATEWAY_CONTAINER" >/dev/null 2>&1 || true
  _ensure_signer_image

  nets="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$ctr")"
  docker run -d --name "$GATEWAY_CONTAINER" --label "abx.gateway-for=$PROJECT_NAME" \
    --network bridge --user "$(id -u):$(id -g)" \
    --read-only --cap-drop ALL --security-opt no-new-privileges \
    -e "AWS_REGION=$BEDROCK_REGION" -e "ABX_SIGNER_PORT=$GATEWAY_PORT" \
    -v "$ABX_RUNTIME_DIR/creds:/run/abx-credentials:ro" \
    "$SIGNER_IMAGE" >/dev/null || die "Could not start the Bedrock gateway."
  for net in $nets; do
    docker network connect --alias "$GATEWAY_ALIAS" "$net" "$GATEWAY_CONTAINER" >/dev/null 2>&1 \
      || echo "[warning] Couldn't connect the Bedrock gateway to network $net" >&2
  done
  for i in 1 2 3 4 5 6 7 8 9 10; do
    docker logs "$GATEWAY_CONTAINER" 2>&1 | grep -q 'forwarding Bedrock inference' && break
    if [ "$(docker inspect -f '{{.State.Running}}' "$GATEWAY_CONTAINER" 2>/dev/null)" != true ]; then
      docker logs "$GATEWAY_CONTAINER" 2>&1 | tail -n 10 >&2
      die "The Bedrock gateway exited during startup."
    fi
    sleep 0.5
  done
  debug "Bedrock gateway $GATEWAY_CONTAINER started"
}

_stop_bedrock_gateway() {
  [ -f "$SESSIONS_DIR/$$" ] || return 0
  rm -f "$SESSIONS_DIR/$$"
  if ! _other_gateway_sessions_alive; then
    docker rm -f "$GATEWAY_CONTAINER" >/dev/null 2>&1 || true
    rm -f "$CREDS_FILE"
  fi
}
