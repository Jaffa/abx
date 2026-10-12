# Run as a file rather than from stdin, so the working directory (the project, which the agent can write to) isn't first on sys.path.
import json, os, sys
path, ws, statusline, bedrock, region, ports, gateway, no_proxy = sys.argv[1:9]
data = {}
env = {}
if statusline == "true":
    data["statusLine"] = {"type": "command", "command": "bash %s/.abx/statusline.sh" % ws, "padding": 0}
if bedrock == "true":
    env.update({"CLAUDE_CODE_USE_BEDROCK": "1", "AWS_REGION": region,
                "ANTHROPIC_BEDROCK_BASE_URL": gateway, "CLAUDE_CODE_SKIP_BEDROCK_AUTH": "1",
                "NO_PROXY": no_proxy, "no_proxy": no_proxy})
if ports:
    env["ABX_PUBLISHED_PORTS"] = ports
if env:
    data["env"] = env
with open(path + ".tmp", "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(path + ".tmp", path)
