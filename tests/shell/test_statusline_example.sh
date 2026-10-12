# examples/statusline.sh: how it names the project inside the sandbox. Needs jq, as the script does.

statusline() {
  printf '{"workspace":{"current_dir":"%s"},"model":{"display_name":"Opus"}}' "$1" \
    | STATUSLINE_SANDBOX_ROOT="$T/workspace" bash "$REPO_DIR/examples/statusline.sh" 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*m//g'
}

ws_setup() {
  command -v jq >/dev/null 2>&1 || skip "jq is not installed"
  WS="$T/workspace"
  mkdir -p "$WS/src/lib" && cd "$WS" || return 1
}

test_name_from_abx_project_name() {
  ws_setup
  mkdir -p .abx && echo my-project > .abx/project-name
  assert_eq "$(statusline "$WS")" "my-project | Opus" "at the root"
  assert_eq "$(statusline "$WS/src/lib")" "my-project/src/lib | Opus" "in a subdirectory"
}

test_name_from_agentbox_compose_project() {
  ws_setup
  mkdir -p .agent-sandbox && printf "name: 'demo-app'\nservices: {}\n" > .agent-sandbox/docker-compose.yml
  assert_eq "$(statusline "$WS/src")" "demo-app/src | Opus" "compose name"
}

test_name_from_git_remote() {
  ws_setup
  git init -q . && git remote add origin git@github.com:someone/my-repo.git
  case "$(statusline "$WS/src")" in "my-repo/src | "*) ;; *) fail "expected the repository name, got: $(statusline "$WS/src")" ;; esac
}

test_control_characters_stripped_from_names() {
  ws_setup
  mkdir -p .abx && printf 'evil\033]0;pwned\007name\n' > .abx/project-name
  case "$(statusline "$WS" | cat -v)" in *'^['*|*'^G'*) fail "control characters reached the terminal" ;; esac
}

test_host_paths_abbreviate_home() {
  ws_setup
  mkdir -p "$HOME/src/thing"
  assert_eq "$(statusline "$HOME/src/thing")" "~/src/thing | Opus" "host path"
}
