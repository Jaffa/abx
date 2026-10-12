# Run as a file rather than from stdin, so the working directory (the project, which the agent can write to) isn't first on sys.path.
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
if data.get("awsCredentialExport") == "cat .abx/aws-credentials.json":
    del data["awsCredentialExport"]
    env = data.get("env", {})
    for key in ("CLAUDE_CODE_USE_BEDROCK", "AWS_REGION"):
        env.pop(key, None)
    if not env:
        data.pop("env", None)
status = data.get("statusLine")
if isinstance(status, dict) and ".abx/statusline.sh" in str(status.get("command", "")):
    del data["statusLine"]
with open(path + ".tmp", "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(path + ".tmp", path)
