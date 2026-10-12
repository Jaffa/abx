# Run as a file rather than from stdin, so the working directory (the project, which the agent can write to) isn't first on sys.path.
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
