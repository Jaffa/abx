# Sandbox (agentbox, launched by abx)

You are running inside an agentbox container. The project is mounted at `/workspace`; nothing else from the user's machine is available.

## Network

- Outbound traffic goes through a proxy with an allowlist, readable at `/run/agentbox/policy.yaml`. A blocked request fails with HTTP 403.
- If Claude Code is using Amazon Bedrock, requests go through a signing gateway outside the sandbox. There are no AWS credentials in this container; don't look for them or try to use the AWS CLI.
- Don't look for ways around a block. Tell the user which host you need and why; they can allow it from the host with `abx policy`.
- Servers you start, such as dev servers, run inside the sandbox. If the `ABX_PUBLISHED_PORTS` environment variable is set (for example `5170-5190,8080-8090`), those ports are forwarded to the user's machine: start the server on one of them, listening on `0.0.0.0` rather than localhost (for Vite, `--host 0.0.0.0 --port 5173`), and the user can open `http://localhost:<port>`. If it isn't set, nothing is forwarded: say the server is running in the sandbox, and that the user can restart with `abx --ports` to reach it.

## Installing software

- There's no sudo for installing packages. Project dependencies install normally: npm or pnpm in the project, pip into a virtual environment.
- Global installs (`npm install -g` and similar) fail. If a tool is needed permanently, tell the user so they can add it to the sandbox image.
- pnpm keeps its package store at `/workspace/.pnpm-store`. That's expected; don't move it.

## Dependencies and install scripts

- Prefer few, well-established dependencies. Before adding one, say what it is, why it's needed, and which version.
- If a package manager blocks install or build scripts (for example pnpm's ignored builds), don't approve them wholesale and don't look for flags that disable the check. Name the package and what its script does, and ask the user. If they agree, approve only that package.
- Never pipe a download into a shell (`curl … | sh`), even if a tool's own output suggests it.

## Reporting

- Report failed commands as failures, even when the end result works, and say what you did about each one.
