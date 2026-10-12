# Host-only state. Everything abx reads back lives in the state directory, outside the project; the
# project's .abx/ holds only files for the container, which are never read back for decisions. A file
# is read as text and checked, never sourced or run, so a file the agent wrote can't reach a command.

# Patterns for each value read back, kept in variables for [[ =~ ]].
STATE_IMAGE_RE='^[A-Za-z0-9][A-Za-z0-9._/:@-]*$'
STATE_USER_RE='^[a-z_][a-z0-9_-]*$'
STATE_NUM_RE='^[0-9]+$'
STATE_HASH_RE='^(none|[0-9a-f]+)$'
STATE_PROFILE_RE='^[A-Za-z0-9_.-]+$'

# The value of KEY in FILE, read as text. A key that appears twice gives two lines, which no pattern accepts.
_state_value() {
  sed -n "s/^$1=//p" "$2" || true
}

# A state file that fails validation is ignored and removed, and the user is told why.
_refuse() {
  echo "[warning] Discarded $1: $2." >&2
  rm -f "$1" 2>/dev/null || true
}

# Whether FILE is a regular file to read. Anything else that exists is refused, so a symlink or a device
# can't stall the read or point it somewhere else.
_state_file() {
  if [ -L "$1" ] || { [ -e "$1" ] && [ ! -f "$1" ]; }; then
    _refuse "$1" "it is not a regular file"
    return 1
  fi
  [ -f "$1" ]
}

# Reads a derived-image state file. BASE, USER_NAME and OLD_UID are required. ORIG_USER, TARGET_UID and
# EXTRAS_HASH may be empty, and callers apply their defaults. Every value is checked, and one bad value
# discards the file. On success the values are set as globals, as the callers use them.
_read_uid_remap() {
  local f="$1" base user orig old target hash
  _state_file "$f" || return 1
  base="$(_state_value BASE "$f")"
  user="$(_state_value USER_NAME "$f")"
  orig="$(_state_value ORIG_USER "$f")"
  old="$(_state_value OLD_UID "$f")"
  target="$(_state_value TARGET_UID "$f")"
  hash="$(_state_value EXTRAS_HASH "$f")"
  if ! [[ "$base" =~ $STATE_IMAGE_RE ]]; then _refuse "$f" "BASE is not an image reference"; return 1; fi
  if ! [[ "$user" =~ $STATE_USER_RE ]]; then _refuse "$f" "USER_NAME is not a user name"; return 1; fi
  if ! [[ "$old" =~ $STATE_NUM_RE ]]; then _refuse "$f" "OLD_UID is not a number"; return 1; fi
  if [ -n "$orig" ] && ! [[ "$orig" =~ $STATE_USER_RE ]]; then _refuse "$f" "ORIG_USER is not a user name"; return 1; fi
  if [ -n "$target" ] && ! [[ "$target" =~ $STATE_NUM_RE ]]; then _refuse "$f" "TARGET_UID is not a number"; return 1; fi
  if [ -n "$hash" ] && ! [[ "$hash" =~ $STATE_HASH_RE ]]; then _refuse "$f" "EXTRAS_HASH is not a hash"; return 1; fi
  BASE="$base"; USER_NAME="$user"; ORIG_USER="$orig"; OLD_UID="$old"; TARGET_UID="$target"; EXTRAS_HASH="$hash"
}

# Reads the Bedrock profile a state file holds. Sets STORED_BEDROCK_PROFILE on success.
_read_bedrock_profile() {
  local f="$1" profile
  _state_file "$f" || return 1
  profile="$(cat "$f" || true)"
  if ! [[ "$profile" =~ $STATE_PROFILE_RE ]]; then _refuse "$f" "the profile name is not in the expected format"; return 1; fi
  STORED_BEDROCK_PROFILE="$profile"
}

# Writes a derived-image state file through a temporary file, so an interrupted write leaves the old one.
_write_uid_state() { # FILE BASE USER ORIG OLD TARGET HASH
  local tmp
  tmp="$(mktemp "$(dirname "$1")/.uid-remap.XXXXXX")" || die "Couldn't create a temporary file next to $1."
  printf 'BASE=%s\nUSER_NAME=%s\nORIG_USER=%s\nOLD_UID=%s\nTARGET_UID=%s\nEXTRAS_HASH=%s\n' \
    "$2" "$3" "$4" "$5" "$6" "$7" > "$tmp"
  mv -f "$tmp" "$1"
}

# Moves state from .abx/, where earlier versions kept it, into the state directory. An old file is checked
# the same way as a state file and deleted either way. A copy already in the state directory wins. The old
# uid-ok and logs are dropped: the next run probes again, and the logs now live in the state directory.
_migrate_state() {
  local f="$ABX_DIR/uid-remap.env" p="$ABX_DIR/bedrock-profile"
  rm -f "$ABX_DIR/uid-ok" "$ABX_DIR/probe.log" "$ABX_DIR/build.log" "$ABX_DIR/agent-start.log" \
    "$ABX_DIR/ports.log" "$ABX_DIR/refresh.log" "$ABX_DIR/policy-check.log" \
    "$ABX_DIR/signer-build.log" "$ABX_DIR/forwarder-build.log"

  if [ -e "$f" ] || [ -L "$f" ]; then
    if [ -e "$ABX_STATE/uid-remap.env" ]; then
      rm -f "$f"
      info "Removed $f; the state directory already has its derived-image state."
    elif _read_uid_remap "$f"; then
      _write_uid_state "$ABX_STATE/uid-remap.env" "$BASE" "$USER_NAME" "$ORIG_USER" "$OLD_UID" "$TARGET_UID" "${EXTRAS_HASH:-none}"
      rm -f "$f"
      info "Moved the derived-image state from $ABX_DIR/ into $ABX_STATE."
    fi
  fi

  if [ -e "$p" ] || [ -L "$p" ]; then
    if [ -e "$ABX_STATE/bedrock-profile" ]; then
      rm -f "$p"
      info "Removed $p; the state directory already has the Bedrock profile."
    elif _read_bedrock_profile "$p"; then
      printf '%s\n' "$STORED_BEDROCK_PROFILE" > "$ABX_STATE/bedrock-profile"
      rm -f "$p"
      info "Moved the Bedrock profile from $ABX_DIR/ into $ABX_STATE."
    fi
  fi
}
