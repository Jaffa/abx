# abx

Run [Claude Code](https://code.claude.com) in a sandbox for the project you're in, with one command.

```bash
cd ~/src/my-project
abx
```

abx is a launcher for [agent-sandbox](https://github.com/mattolson/agent-sandbox) (`agentbox`), which provides the isolation: a container that sees only your project, and a proxy that lets it reach only the domains you allow. abx adds the workflow around it: one command from anywhere in a project, a persistent setup per project, and some things agentbox doesn't do itself (yet).

> **Status:** early and developed on Linux with Docker. It's written to work on macOS too, but has had less testing there. Issues and pull requests are welcome.

## What you get

| Feature | Detail |
| --- | --- |
| One command | `abx` from anywhere in a project initialises its sandbox on first use, then starts Claude Code in the directory you're in |
| Isolation | From agentbox: only the project is mounted, and all traffic goes through an allowlisting proxy, except the Bedrock gateway's |
| Works on Linux | agentbox's agent user is UID 501 (the macOS default); on Linux, abx builds a local image with the user renumbered to yours, so the agent can write to your project ([agent-sandbox#206](https://github.com/mattolson/agent-sandbox/issues/206)) |
| Your tools in the image | A Dockerfile fragment you write is layered into the agent image, e.g. Node.js, pnpm and Python |
| Amazon Bedrock without credentials in the sandbox | A signing gateway beside the sandbox holds short-lived AWS credentials and signs Claude Code's requests, so the agent never sees them |
| Dev servers you can open | `--ports` publishes ports from the sandbox for the length of the session, on localhost by default |
| Sandbox instructions | Claude is told how the sandbox works: the network policy, installing packages, not approving install scripts wholesale, published ports |
| Clean-up | `abx clean` removes a project's containers and sidecars, or every agentbox project on the machine |

## Requirements

| Requirement | Notes |
| --- | --- |
| [agentbox](https://github.com/mattolson/agent-sandbox/releases) | On your `PATH` |
| Docker | Your user must be able to use it without `sudo`: rootless Docker, or membership of the `docker` group (which is root-equivalent on the host). Rancher Desktop and Colima work on macOS. abx refuses to run as root |
| bash, git, Python 3 | On the host. Python needs only its standard library |
| AWS CLI v2 | Only for Bedrock mode |

## Installation

```bash
git clone https://github.com/Jaffa/abx.git ~/src/abx
mkdir -p ~/.local/bin
ln -s ~/src/abx/abx.sh ~/.local/bin/abx      # anywhere on your PATH
abx check                                     # confirms agentbox's version and the flags abx uses
```

Keep the clone where it is: `abx` finds its `lib/` and `resources/` directories through the symlink.

### Optional configuration

abx reads your configuration from `~/.config/agent-sandbox/`. Nothing here is required, and `examples/` has starting points to copy:

| File | Purpose |
| --- | --- |
| `templates/user.policy.yaml` | The network policy applied to each new project. If it doesn't exist, new projects keep agentbox's own policy. [`examples/user.policy.yaml`](examples/user.policy.yaml) is a starting point |
| `abx/Dockerfile.extra` | Extra build steps for the agent image, run as root. [`examples/Dockerfile.extra`](examples/Dockerfile.extra) adds Node.js, npm, pnpm, Yarn and Python |
| `abx/statusline.sh` | A Claude Code statusline for the sandbox. [`examples/statusline.sh`](examples/statusline.sh) shows the project's name rather than `/workspace` |
| `abx/CLAUDE.md` | Replaces abx's default sandbox instructions ([`resources/abx-CLAUDE.md`](resources/abx-CLAUDE.md)) |

agentbox reads its own configuration from the same directory, such as its dotfiles; [Git](#git) covers the one most people need.

```bash
mkdir -p ~/.config/agent-sandbox/abx
cp ~/src/abx/examples/Dockerfile.extra ~/src/abx/examples/statusline.sh ~/.config/agent-sandbox/abx/
```

abx rebuilds the image automatically on the next run whenever `Dockerfile.extra` or the instructions change.

## Usage

```bash
abx                      # start Claude Code for this project
abx --continue           # anything abx doesn't recognise goes to Claude Code
abx -p "summarise the open TODOs"
abx -- shell             # pass a word abx would otherwise treat as a command
```

The first run in a project initialises its sandbox, pulls agentbox's images and, where needed, builds the local image, which takes a few minutes. After that, starting takes seconds. Claude Code asks once per project for its theme and whether to trust the folder, because each project keeps its own Claude state.

Run abx from a subdirectory and Claude starts there, using the enclosing project's sandbox. abx finds the project by looking upwards for an existing sandbox, then for the git repository root, and otherwise uses the current directory.

### Commands

| Command | Does |
| --- | --- |
| `abx [claude args]` | Starts Claude Code in the project's sandbox |
| `abx shell` | Opens a shell in the sandbox instead |
| `abx policy` | Edits the project's network policy; a running proxy reloads it |
| `abx logs` | Follows the proxy log, e.g. to see which domains were refused |
| `abx reload` | Reloads the proxy after editing policy files directly |
| `abx status` | Shows the effective policy and Compose configuration |
| `abx rebuild` | Rebuilds the local agent image from the latest upstream image |
| `abx clean` | Removes the project's containers, sidecars and networks (options below) |
| `abx check` | Shows agentbox's version and the help for the flags abx relies on |
| `abx help` | Lists all commands, options and environment variables |

### Options

| Option | Effect |
| --- | --- |
| `--bedrock` / `--no-bedrock` | Use Amazon Bedrock for this project, or stop. Remembered per project |
| `--ports[=SPEC]` | Publish ports from the sandbox on localhost for this session. Default `3000-3010,4173,5170-5190,6006,8080-8090` |
| `--ports-lan[=SPEC]` | The same, on all network interfaces |
| `--no-ports` | Don't publish ports, even if `ABX_PORTS` is set |
| `--debug` / `--quiet` | More or less of abx's own output |

`abx help` lists the environment variables, such as `ABX_PORTS` for ports in every session, and `ABX_BEDROCK_PROFILE` for the AWS profile Bedrock mode uses.

## Network access

The sandbox can reach only the domains in the project's policy. When Claude needs another one, it says which and why; allow it with `abx policy`, which takes effect without restarting the session. `abx logs` shows what's being refused.

Claude Code's WebSearch tool runs on Anthropic's side, so it works regardless of the policy (except on Bedrock, which doesn't offer it). WebFetch and anything Claude runs, such as `curl`, `npm` or `git`, can reach only allowed domains.

To change the defaults for new projects, edit `~/.config/agent-sandbox/templates/user.policy.yaml`. abx checks the template with agentbox when it applies it, and keeps agentbox's own policy if the template is invalid. See agentbox's documentation for the policy format, including per-path rules and GitHub repository scoping.

## Amazon Bedrock

Bedrock mode runs a small signing gateway beside the sandbox. Claude Code sends its Bedrock requests to the gateway unsigned; the gateway signs them with short-lived credentials and forwards only model-inference requests to Bedrock. The credentials stay in a private directory on your machine, never in the project or the container, and Bedrock traffic bypasses agentbox's proxy, so it needs no allowlist entries.

**One-off setup:**

1. In the Bedrock console, open an Anthropic model in the model catalogue and submit the use-case form (once per AWS account).
2. Create a least-privilege role and CLI profile with [`resources/bedrock-bootstrap.sh`](resources/bedrock-bootstrap.sh). It creates a role that can invoke Anthropic models, list their inference profiles and subscribe to them through AWS Marketplace, and nothing else; a `claude-bedrock` profile that assumes it; and optionally a monthly budget alert:

   ```bash
   aws sso login --profile admin        # or however you sign in as an administrator
   ~/src/abx/resources/bedrock-bootstrap.sh --admin-profile admin --region eu-west-1 --budget-email you@example.com
   ```

**Per project:**

```bash
abx --bedrock            # remembered from now on; 'abx --no-bedrock' switches back
```

If your administrator login uses SSO and has expired, abx tells you to run `aws sso login`. Credentials are refreshed in the background, but only while that login is valid.

**Models:** newer Claude models on Bedrock can only be invoked through an inference profile, an ID with a routing prefix such as `eu.` or `global.`. Choose one with `/model`, e.g. `/model eu.anthropic.claude-haiku-5-5`; Claude Code remembers it for the project. To list the profiles available to you:

```bash
aws bedrock list-inference-profiles --profile claude-bedrock \
  --query "inferenceProfileSummaries[?contains(inferenceProfileId, 'anthropic')].inferenceProfileId" --output text
```

## Dev servers and ports

```bash
abx --ports              # the default set
abx --ports=5173,8080    # your own selection
```

Ports are published on localhost for the session and removed when it ends. Ports already in use on your machine are skipped, and abx says which. Claude is told which ports are published, and that servers must listen on `0.0.0.0` inside the sandbox (for Vite: `--host 0.0.0.0`), because a server listening only on the container's own localhost can't be reached.

`--ports-lan` publishes on all network interfaces instead. On Linux, Docker's published ports can bypass host firewalls such as ufw, so only use it when you mean to expose the server.

## Git

Commits made in the sandbox need an identity. The agentbox way is a `.gitconfig` in its dotfiles directory, mounted read-only into the sandbox:

```bash
mkdir -p ~/.config/agent-sandbox/dotfiles
printf '[user]\n\tname = %s\n\temail = %s\n' "$(git config user.name)" "$(git config user.email)" \
  > ~/.config/agent-sandbox/dotfiles/.gitconfig
```

Dotfiles are opt-in in agentbox; see its documentation for enabling them. Without an identity, commits made in the sandbox are attributed to `dev`.

## Files abx creates

| Where | What |
| --- | --- |
| `<project>/.agent-sandbox/` | agentbox's per-project configuration, including the network policy |
| `<project>/.abx/` | Files for the sandbox: abx's Claude Code settings, the statusline and the project's name. Read-only inside the container, and rewritten on every run |
| `<project>/.git/info/exclude` | Entries for `.agent-sandbox/`, `.abx/` and `.pnpm-store/`, so they stay out of git without changing the project's shared `.gitignore` |
| `~/.local/state/abx/` | abx's state for each project, which it never keeps where the agent could change it |
| `$XDG_RUNTIME_DIR/abx/` (or `~/.cache/abx/`) | Bedrock credentials while a session runs, removed afterwards |
| Docker | Each project's containers and state volumes, abx's local images, and the gateway and port-forwarder sidecars while in use |

`abx clean --all --volumes --images` removes the containers, networks and state volumes of every agentbox project, and abx's images and dangling images, but keeps the state directories and each project's `.agent-sandbox/` and `.abx/`. `--dry-run` lists it first.

## Security model

abx relies on agentbox for the main boundary: the agent sees only the project directory, and reaches only allowlisted domains. On top of that, abx:

- **Keeps credentials out of the sandbox.** Bedrock credentials stay in the gateway, outside the project.
- **Doesn't trust what the agent can write.** abx's own state lives outside the project, files it puts in `.abx/` are read-only inside the sandbox, and nothing read from them is executed.
- **Only acts on its own containers.** abx checks which directory a container belongs to before acting on it, and never touches containers from other projects.
- **Asks Claude to be careful.** The sandbox instructions say not to approve package install scripts wholesale or pipe downloads into a shell, and to report failed commands honestly.

What it can't prevent:

- **Exfiltration to allowed domains.** Anything the sandbox can reach, it can send data to. Keep the policy narrow.
- **Code that later runs on your host.** The agent can change any file in the project: `package.json` scripts, `.vscode/` tasks, `Makefile`s, git hooks, Claude Code settings. Review changes before running project commands outside the sandbox.

## Development

[`CLAUDE.md`](CLAUDE.md) is the guide to working on abx, whether by hand or with Claude Code: its architecture, the upstream agentbox issues it works around, its security rules, coding conventions and test approach. Start there before making changes.

In short, `tests/run.sh` runs the full suite; it needs bash, git and Python 3, but no Docker or network.

## Licence

[Apache License 2.0](LICENSE). abx is an independent project, not affiliated with agent-sandbox or Anthropic.
