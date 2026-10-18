# abx

abx is a single command, `abx`, that runs Claude Code in a sandbox for the current project. It wraps [mattolson/agent-sandbox](https://github.com/mattolson/agent-sandbox) (the `agentbox` CLI), which supplies the isolation; abx adds the workflow around it: one command from any directory in a project, a persistent per-project setup, and fixes for gaps agentbox doesn't yet cover.

This file is for working on abx itself. `resources/claude/CLAUDE.md` is a different file: the instructions abx adds to the system prompt of Claude sessions running inside the sandbox. Don't confuse the two.

## Files

| Path | Purpose |
| --- | --- |
| `abx.sh` | The launcher. Installed by symlinking it onto `PATH` as `abx` |
| `lib/` | The modules abx.sh sources from its real location: output helpers, host state, terminal handling, time zone, port publishing, Bedrock, container ownership, the UID alignment and derived image, settings and project setup, Claude Code's configuration, `abx policy` and `abx reload`, and `abx clean`. The Python programs they run are here too (`lib/*.py`). Required: abx stops with an error if it's missing |
| `resources/` | Files abx itself depends on, used in place. Never copied to the user's configuration |
| `resources/claude/CLAUDE.md` | abx's instructions, added to the system prompt with `--append-system-prompt-file` on every run, from a read-only mount at `/opt/abx-base`. Required: abx warns if it's missing |
| `resources/abx-bedrock-signer.py` | The Bedrock gateway: a standard-library SigV4 signing proxy, built into a small image by abx. Required for `--bedrock` |
| `resources/bedrock-bootstrap.sh` | One-off AWS setup, run by the user: a least-privilege IAM role, a CLI profile that assumes it, and an optional budget |
| `examples/` | Starting points the user may copy into `~/.config/agent-sandbox/abx/`. abx never reads this directory |
| `examples/statusline.sh` | A statusline showing the project name rather than `/workspace`. Installed only once copied to `~/.config/agent-sandbox/abx/claude/statusline.sh` |
| `examples/Dockerfile.extra` | Image extras adding Node.js, npm, pnpm, Yarn, Python and Chromium. Used only once copied to `~/.config/agent-sandbox/abx/Dockerfile.extra` |

abx locates `lib/` and `resources/` relative to the real location of `abx.sh`, following symlinks, so they must stay together. Anything in `examples/` must remain optional: no code path may fall back to it.

## How agentbox works (the parts abx depends on)

| Component | Detail |
| --- | --- |
| Containers | A Compose project per sandbox, named with `agentbox init --name`, with services `agent` and `proxy`. Each container carries its project's name and its directory's `.agent-sandbox/` as Compose labels, and abx acts only on containers whose labels say they're this project's (see Security model) |
| Network | All egress goes through a mitmproxy sidecar that enforces the allowlist. iptables in the agent container blocks direct outbound traffic. The proxy's CA is added to the agent's system trust store at startup |
| Project files | `.agent-sandbox/` in the project: the policy in `policy/user.policy.yaml`, and the user Compose override in `compose/user.override.yml`. agentbox seeds the override with content of its own |
| Inside the container | The project is mounted at `/workspace`. The live allowlist is at `/run/agentbox/policy.yaml`, a directory that exists only inside the sandbox. The agent user is `dev`, UID 501 upstream |
| State | Named volumes per project for Claude Code state and history. The proxy shares its CA and run volumes with the agent |
| `agentbox exec` | Passes its arguments through to the container verbatim. It doesn't treat `--` as a separator |

## What abx does on each run

`abx.sh` runs these steps in order. The module named at the end of each step holds its code. Host-only state goes to the state directory, and `.abx/` is written only for the container.

1. **Finds the project root.** It takes the nearest directory, from the current one upwards, containing `.agent-sandbox/` or `.abx/`; then the git root; then the current directory. The search stops below `$HOME`, and `/`, `$HOME` and `/Users`-style paths are refused. Markers come before git so a nested repository isn't mistaken for the project. Code: `lib/project.sh`.
2. **Initialises** with `agentbox init --agent claude --mode cli --name <project>` if there's no sandbox yet, then applies the user's policy template. A new project's name is its directory's name and eight hex digits of a hash of its path (see Project names). Code: `lib/project.sh`.
3. **Records the project name** in `.abx/project-name` for the statusline, since the container only ever sees `/workspace`. Code: `lib/settings.sh`.
4. **Excludes** `.agent-sandbox/`, `.abx/` and `.pnpm-store/` via `.git/info/exclude`, never `.gitignore`. All three exist only because the project runs in abx's sandbox, so they're personal to this clone; `.gitignore` is shared project content, and editing it would leave changes in repositories the user may not own. `.pnpm-store/` is the one tool-specific entry: pnpm hard-links from its store, so it needs the store on the project's filesystem, which inside the sandbox is the `/workspace` mount. On a normal host, the store sits in the home directory and never appears in the project. Add another exclusion only when the sandbox itself causes a tool to write into the project; anything a normal host workflow also produces is the project's own business. Code: `lib/project.sh`.
5. **Ensures the agent can write to the project**, building a derived image when needed (see the #206 workaround), and mounting `.abx/` read-only in the agent on every run. Code: `lib/image.sh`.
6. **Prepares Bedrock**, if enabled for the project. Code: `lib/bedrock.sh`.
7. **Writes `.abx/settings.json`** and launches Claude Code in the matching subdirectory of `/workspace`, with `--settings /workspace/.abx/settings.json`. Code: `lib/settings.sh`, with `lib/write_settings.py`.
8. **Restores the terminal** on exit, by resetting text attributes and terminal modes and restoring `stty` state, then stops the credential refresher. Code: `lib/terminal.sh`.

## Features

| Feature | How it works |
| --- | --- |
| Starting in a subdirectory | From `project/sub`, Claude starts in `/workspace/sub`, equivalent to running `/cd sub` at the start of a session. Sessions are stored by starting directory, so `--continue` is per directory |
| abx's own settings | `.abx/settings.json` holds the statusline command, the Bedrock and port settings, and the variable that lets Claude Code read `CLAUDE.md` from added directories, with absolute container paths. It's regenerated every run and passed with `--settings`, so abx never edits the project's `.claude/` files. `.abx/` is mounted read-only in the agent at `/workspace/.abx`, through an entry in agentbox's override tagged `# abx: uid-remap`. Earlier versions wrote to `.claude/settings.local.json`; `_remove_legacy_settings` removes those keys and nothing else |
| Bedrock mode | `abx --bedrock` is remembered per project in the state directory (`bedrock-profile`, see [Security](#security-model-and-rules-for-changes)). A gateway container (`abx-gateway-<project>`, alias `abx-gateway` on the project network) runs `resources/abx-bedrock-signer.py`. Like the port forwarder it's labelled `abx.project-dir`, and one that another directory owns is never touched. It holds the credentials, signs Claude Code's requests with SigV4, and forwards only model-inference paths to one fixed endpoint, `bedrock-runtime.<region>.amazonaws.com`. Claude Code runs with `CLAUDE_CODE_USE_BEDROCK=1`, `ANTHROPIC_BEDROCK_BASE_URL=http://abx-gateway:8787`, `CLAUDE_CODE_SKIP_BEDROCK_AUTH=1`, and `abx-gateway` appended to the container's existing `NO_PROXY`. On the host, `aws configure export-credentials --format process` writes the credentials to `${XDG_RUNTIME_DIR:-~/.cache}/abx/<project>/creds/` (mode `700`, outside the project), refreshed every 10 minutes (`ABX_BEDROCK_REFRESH`); the signer re-reads the file when it changes. Concurrent sessions share one gateway, tracked by PID files beside the credentials, and the last to exit removes it and the credentials. No AWS credentials ever enter the agent container, and Bedrock needs no allowlist entries because its traffic bypasses agentbox's proxy |
| Time zone | The agent's `TZ` is the host's: `TZ` if set, else the zone `/etc/localtime` links to, else `/etc/timezone`, else UTC with a warning. agentbox's compose file defaults `TZ` to `America/Los_Angeles` when it's unset, so abx exports the zone for compose to pass on. A sandbox whose agent was made with another zone is removed on the next run, and the next `agentbox exec` recreates it |
| Image extras | `~/.config/agent-sandbox/abx/Dockerfile.extra` (or `ABX_IMAGE_EXTRAS`, or `off`) is layered into the agent image, running as root. Changes trigger a rebuild on the next run |
| Claude Code configuration | Two sources. abx's instructions, `resources/claude/CLAUDE.md`, are always passed with `--append-system-prompt-file`, from a read-only mount at `/opt/abx-base`. The user's `~/.config/agent-sandbox/abx/claude/` (or `ABX_CLAUDE_DIR`, or `off`), laid out as a `.claude` directory, is mounted read-only at `/opt/abx/.claude`, and `/opt/abx` is passed with `--add-dir`. Its `CLAUDE.md` is read as memory, which needs `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD`, set in `.abx/settings.json`. Its `statusline.sh` is the statusline, run from the mount. Nothing is copied into the image or the project, so an edit takes effect on the next run without a rebuild. The mounts are part of the override every run writes, so adding or removing the directory recreates the containers. `--add-dir` comes before `--settings`, since it takes several values. A resumed conversation reuses the system prompt recorded at its first request (`--system-prompt-snapshot`, on by default), so after abx's instructions change, resume with `--system-prompt-snapshot off` |
| Generated build contexts | The Dockerfiles abx generates for the derived image, port forwarder and Bedrock signer live in `${XDG_CACHE_HOME:-~/.cache}/abx/`, rewritten whenever they're needed, never in the configuration directory |
| Port publishing | `--ports[=SPEC]`, `--ports-lan` or `ABX_PORTS` start a forwarding container (`abx-ports-<project>`, built from `alpine` plus `socat`) for the length of the session. It publishes the ports on the host (localhost by default) and relays each connection to the same port on the `agent` service, so agentbox's configuration is untouched and nothing stays exposed after exit. It's labelled with its owner's PID, so a forwarder left by a crashed session is replaced, and concurrent sessions share one. It's also labelled with `abx.project-dir`, and one that another directory owns is left alone. Claude learns the ports from `ABX_PUBLISHED_PORTS` in `.abx/settings.json` |
| `abx rebuild` | Rebuilds the derived image from the latest upstream image (`--pull`) |
| Project names | A new project's Compose name is its directory's name and eight hex digits of a hash of its path, so two directories with the same name never share containers or volumes. The name is recorded in the state directory when the sandbox is initialised. A project set up earlier keeps its recorded name, or its directory's name when none is recorded, so its containers and volumes carry on |
| `abx clean` | Removes this project's sandbox: its owned containers, its own gateway and port-forwarder containers, its networks once they're empty, and its Bedrock credentials. `--volumes` also removes its Compose volumes, and is refused while another directory uses the project's name. `--all` covers every agentbox project on the machine, found from the images its containers run, and with `--images` also removes `abx/` images and prunes dangling ones. `--dry-run` lists what would go and removes nothing; without `--yes`, abx asks, and on non-interactive input it refuses. The state directory and `.agent-sandbox/` and `.abx/` are kept |
| Pass-through commands | `abx shell`, `logs`, `status` and `check` call the corresponding agentbox commands. `abx policy` and `abx reload` do too, then check the proxy (see the next row) |
| Policy reload | agentbox mounts each policy file into the proxy as a single-file bind mount, which Docker pins to the file's inode. An editor that saves by renaming a new file over the old one leaves the proxy reading the old content, and SIGHUP then reports `applied` with nothing changed. After `abx policy`'s editor exits, and before `abx reload` sends SIGHUP, abx reads each policy file back from the proxy with `docker exec … cat` and compares it with the host's. If one differs it validates the policy with `agentbox policy config`, restarts the proxy (a restart re-resolves the path) and waits for it to be healthy. An invalid policy is left alone, since a proxy that restarts with one exits at startup, whereas SIGHUP keeps the last good policy. Only running proxies this project owns are read or restarted. Code: `lib/policy.sh` |

Environment variables are documented in `abx help`. Any new variable must be added there.

## Workarounds pending upstream issues

Each of these exists only because of an open agentbox issue. When the issue is resolved, simplify rather than keep both paths.

### #206: the agent can't write to the workspace on Linux

[agent-sandbox#206](https://github.com/mattolson/agent-sandbox/issues/206). The agent's UID is 501, the macOS default. Linux bind mounts keep numeric ownership as-is, so for any other host UID the workspace is read-only to the agent.

abx's workaround (`_ensure_uid_match` and the functions near it):

1. **Probe.** abx runs a shell inside the container that reports the agent's UID, username and GID, and whether it can create a file in `/workspace`. Everything agentbox prints goes to the state directory's `probe.log`.
2. **Mismatch found.** It builds a derived image from the running container's upstream image:
   - The agent user is renumbered to the host UID, and its group to the host GID (`id -g`). Any account already holding that UID is moved to 59999 first, and files the old UID owned are re-owned. The same goes for a group holding the host GID, and files with the old GID get the new one. A macOS host's UID already matches, so its group is left alone.
   - The image's original `USER` is restored at the end.
3. **Point the project at it.** `image:` and `pull_policy: never` are merged into `services.agent` in agentbox's override, with each line tagged `# abx: uid-remap`. After merging, abx checks the result appears in `agentbox compose config`, restoring the file from backup if it doesn't.
4. **Restart and re-own.** It stops the project's containers and re-owns files in volumes **only the agent mounts**.
5. **Record.** `uid-ok` in the state directory records that the check passed for this host UID and GID. `uid-remap.env` records the base image, user, UIDs and GIDs and a hash of the image additions. A record from before the group was renumbered has no GID keys; a derived image of that kind is realigned once, on a Linux host, when its group is wrong.

The derived image also carries `abx.base`, `abx.user`, `abx.orig-user`, `abx.old-uid`, `abx.target-uid` and the `abx.old-gid` and `abx.target-gid` labels, written at build time. If the state record is lost, a running agent on an `abx/` image gets its record back from those labels, checked the same way as a state file (`_recover_derived_record`). Labels that are missing or invalid stop abx and point at `abx clean`.

The same derived image carries the image extras, so abx builds it on macOS too whenever there are extras (with no renumbering). The sandbox instructions are mounted, not baked in (see `lib/claude.sh`).

When #206 is fixed upstream, keep the derived image for additions, but drop the renumbering, the volume re-owning and the mismatch path.

### #177: templates for user files

[agent-sandbox#177](https://github.com/mattolson/agent-sandbox/issues/177) proposes seeding user-owned files from `~/.config/agent-sandbox/templates/` at `init`. Until then, abx:

- **Copies the policy template** (`templates/user.policy.yaml`, a flat path) over the generated policy after `init`, keeping the original as `user.policy.yaml.generated`.
- **Finds the override file** by running `agentbox edit compose` with a stand-in `$EDITOR` that records the path it's given.
- **Merges its keys** into whatever agentbox seeded.

When #177 lands, move the template to `templates/policy/user.policy.yaml` and drop the copy step. The derived-image override could then be seeded from `templates/compose/user.override.yml` rather than merged after the fact. Note that the proposed layout lives in the same directory abx already uses.

### #201: policy reloads see stale content

[agent-sandbox#201](https://github.com/mattolson/agent-sandbox/issues/201). The proxy gets each policy file as a single-file bind mount, which Docker pins to the file's inode. An edit that replaces the file (an editor's atomic save, `sed -i`, `git checkout`) leaves the proxy reading the old content, and SIGHUP logs `applied` without changing anything. It happens on macOS as well as Linux. `agentbox edit policy` sends SIGHUP itself, so it has the same exposure.

abx's workaround is `lib/policy.sh` (see Policy reload): `abx policy` and `abx reload` compare the proxy's copy of each file with the host's, and restart the proxy when they differ. The issue proposes the same check in `agentbox proxy reload`, as well as mounting the `policy/` directory instead of the files.

When the issue is resolved, drop `lib/policy.sh` and make `abx policy` and `abx reload` plain pass-throughs again.

### Other upstream behaviour abx works around

| Behaviour | Workaround |
| --- | --- |
| `agentbox exec` passes arguments verbatim, with no working-directory option | Launch through `sh -c 'cd "$1" && shift && exec claude "$@"'` |
| Claude Code loads `.claude/settings.local.json` from the git root, but from the starting directory in non-git projects | abx's settings go through `--settings` instead |
| runc refuses to `exec` when the project directory was deleted and recreated while containers ran ("outside of container mount namespace root") | abx detects that in the probe output, recreates the containers and retries once |

## Security model and rules for changes

The agent can write anything in the project directory. Treat every file there as untrusted.

- **The host never trusts a file the agent can write.** Everything abx reads back on the host lives in its state directory, `${XDG_STATE_HOME:-~/.local/state}/abx/<project>-<hash>`, mode `700`, outside the project. The project's `.abx/` holds only files for the container (settings, the statusline, the project name); it's mounted read-only in the agent, and abx never reads it back for a decision. Anything read from a file is checked against a pattern in `lib/state.sh` and never sourced or evaluated, and one bad value discards the file with a message. Every Python program runs with `python3 -I`, so neither the working directory, `PYTHONPATH` nor the user's site-packages can supply a module.
- **Keep credentials out of the agent container and the project.** Anything that authenticates belongs in a sidecar the agent can only send requests to, like the Bedrock gateway, with its secrets outside the project directory. Gateways forward to fixed upstreams and fixed paths only; a gateway that follows the request's `Host` header or exposes a management API would let the agent escape the allowlist.
- **Never execute project files on the host.** Anything abx runs or reads with consequences must come from abx itself, the user's config directory, or be regenerated by abx before use.
- **Sanitise anything read from the project before printing it.** The statusline strips control characters from names it reads, because a crafted file could otherwise send escape sequences to the terminal.
- **No per-project Dockerfile fragments.** Build steps run with unrestricted network access, bypassing the proxy. Image extras live only in the user's config directory.
- **Never re-own volumes shared with another container.** Re-owning the proxy's CA and run volumes broke the proxy at startup.
- **Don't set CA or proxy environment variables in the image.** Setting `NODE_EXTRA_CA_CERTS` in `examples/Dockerfile.extra` replaced agentbox's own setting and broke Claude Code's TLS connection to Bedrock. The upstream image already configures trust for the proxy.
- **Don't widen isolation by default.** Port publishing is opt-in per session and binds to localhost unless `--ports-lan` is given, with a warning. Extra mounts and broader allowlists are per-project decisions for the user.
- **Never run as root.** abx refuses unless `ABX_ALLOW_ROOT=true`. Docker access should come from the `docker` group or rootless Docker; `docker` group membership is root-equivalent on the host, and the user should know that.
- **Leave user content alone.** Edit only keys abx owns, mark anything abx adds, and refuse with clear instructions when a file already contains the user's own setting for the same thing.
- **Act only on containers this project owns.** A container is this project's when its Compose project label is the project's name and its `com.docker.compose.project.working_dir` label is the project's `.agent-sandbox/`, or inside it. Every lookup goes through `_owned_containers` and the helpers in `lib/containers.sh`. abx never finds containers with `docker ps --filter ancestor=`: that resolves an image name to the image it names now, so it misses containers made from earlier pulls. Sidecars have no Compose labels, so abx marks each one with `abx.project-dir`, and one that another directory owns is never stopped, re-owned or connected to a network; abx reads its labels only to classify it. Labels read from Docker are validated before use, as files are.

## Coding conventions

- **Bash 3.2 compatibility**, since macOS ships it:
  - Expand possibly-empty arrays as `${arr[@]+"${arr[@]}"}`.
  - No `mapfile`, `${var,,}` or associative arrays.
  - Keep regular expressions in variables for `[[ =~ ]]`.
- **The script runs under `set -euo pipefail`.** Two traps have already caused bugs:
  - A failing pipeline inside a command substitution exits the script *silently*. Add `|| true` and handle the empty result explicitly, with a message saying what failed and where its log is.
  - `grep -q` in a pipeline can cause a SIGPIPE upstream, which `pipefail` reports as failure. Use `grep … >/dev/null` instead.
- **Output** goes through `info`, `debug` and `die`. Error messages say what happened and what to do next. Keep build output in the state directory's `build.log`, shown only on failure.
- **Edits to user files** are structural: merge and preserve, write a temporary file and `mv` it into place, and keep a backup when validating afterwards. Use Python for JSON and the Compose override (`python3` is required on the host).
- **Comments** explain why: a constraint, a workaround, a security reason. They never restate the code or narrate a change.
- **Library files** (`lib/*.sh`) contain only functions and constants; anything that depends on the project or environment is set up by a `_<module>_init_vars` function that `abx.sh` calls.

## Testing

`tests/run.sh` runs everything: syntax checks, ShellCheck (if installed), the scenario tests and the Python tests. It takes two to three minutes. `tests/run.sh <filter>` runs only tests whose file or function name contains the filter, e.g. `tests/run.sh bedrock`. It needs bash, git and Python 3; neither Docker nor a network is involved. The statusline example's tests also need `jq` and are skipped without it.

| Path | Content |
| --- | --- |
| `tests/stubs/` | Stand-ins for `agentbox`, `docker`, `aws` and `id`. They record every call in `calls.log` and take their behaviour from files in `$ABX_TEST_STATE`; each stub's header lists the files it reads. The docker stub answers `ps`, `inspect`, `rm`, `logs` and `run -d` from a container table, and the agentbox stub adds the stack's containers to it when it starts |
| `tests/lib/harness.sh` | Gives each test its own home, runtime directory and project, with `abx` installed by symlink. Provides `run_abx` (sets `$OUT` and `$STATUS`), `state`, `calls`, `settings_json`, `listen_on` and assertions |
| `tests/shell/test_*.sh` | Scenario tests by area: project, image, settings, Bedrock, ports, containers, terminal, statusline example |
| `tests/python/test_signer.py` | The signer: AWS's SigV4 test-suite vectors, and its proxy behaviour against a local Bedrock stand-in that re-verifies every signature |

The tests treat `abx` as a black box, through its command line, the files it writes and the commands it calls, so they should pass unchanged through refactoring. A test that needs changing during a pure refactor is a sign that behaviour changed.

When adding a feature or fixing a bug:

- **Add a test that fails without the change.** Check it does by reverting the change; every regression class from the project's history (silent exits, re-owned shared volumes, credentials in the project, examples used as defaults) is covered this way.
- **Extend the stubs rather than special-casing tests.** New behaviour goes into the stub's state files, documented in the stub's header.
- **Things only a real run can confirm,** such as Docker networking, real AWS signing, or Claude Code's handling of a setting, should be listed in the change description for the user to check, not assumed.

## Ideas for future work

| Idea | Notes |
| --- | --- |
| Open-weight models on Bedrock | Phase 2 of the gateway: a translator from Anthropic Messages to Mantle's Chat Completions (`bedrock-mantle.<region>.api.aws`) for models such as Qwen. It must expose only inference routes; LiteLLM and claude-code-router both have management APIs. Claude Code can list gateway models in `/model` via `/v1/models` |
| Dependency vetting | A `dep-check` script (OSV vulnerabilities plus a seven-day minimum release age) and a `PreToolUse` hook, layered in through the image extras and managed settings. Worth proposing upstream as a proxy-level package policy |
| Protecting host-executed files | Read-only mounts for `.git/hooks`, `.git/config`, `.claude/` and similar, which run on the host when the user later works there |
| Review-before-merge mode | The agent works on a copy, and changes reach the project only after review |
| Upstreaming | Most of the #206 and #177 workarounds, and the dependency vetting, belong in agentbox. Prefer contributing them over growing abx |
