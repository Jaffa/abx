# Run as a file rather than from stdin, so the working directory (the project, which the agent can write to) isn't first on sys.path.
# usage: write_settings.py PATH STATUSLINE BEDROCK REGION PORTS GATEWAY NO_PROXY
import json, os, sys
path, statusline, bedrock, region, ports, gateway, no_proxy = sys.argv[1:8]
data = {}
# Claude Code reads CLAUDE.md from --add-dir directories only when this is set, and abx's directories are added that way.
env = {"CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD": "1"}
if statusline:
    data["statusLine"] = {"type": "command", "command": statusline, "padding": 0}
if bedrock == "true":
    env.update({"CLAUDE_CODE_USE_BEDROCK": "1", "AWS_REGION": region,
                "ANTHROPIC_BEDROCK_BASE_URL": gateway, "CLAUDE_CODE_SKIP_BEDROCK_AUTH": "1",
                "NO_PROXY": no_proxy, "no_proxy": no_proxy})
if ports:
    env["ABX_PUBLISHED_PORTS"] = ports
data["env"] = env
with open(path + ".tmp", "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(path + ".tmp", path)
