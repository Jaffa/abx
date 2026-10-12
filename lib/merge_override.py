# Run as a file rather than from stdin, so the working directory (the project, which the agent can write to) isn't first on sys.path.
# Merges abx's settings into agentbox's compose override, for the agent service only. The file is edited as text,
# since the standard library has no YAML parser, so every line abx adds carries MARK, and the user's own keys are
# left alone. usage: merge_override.py FILE IMAGE SOURCE
#   IMAGE is the derived image to run, or empty to leave the agent's image alone.
#   SOURCE is the absolute path of the project's .abx/ directory, mounted read-only in the agent.
# Prints 'unchanged', 'changed' or 'conflict' (the user already sets the agent's image or build).
import json
import os
import re
import sys

MARK = "# abx: uid-remap"
MOUNT_TARGET = "/workspace/.abx"


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def is_content(line):
    s = line.strip()
    return bool(s) and not s.startswith("#")


def block_end(lines, start, indent):
    """The first content line after START whose indentation is no deeper than INDENT."""
    for j in range(start + 1, len(lines)):
        if is_content(lines[j]) and indent_of(lines[j]) <= indent:
            return j
    return len(lines)


def locate(lines):
    """Finds services and the agent service, and the indentation of their keys: (services, agent, child, key)."""
    svc = next((i for i, l in enumerate(lines) if re.match(r"^services:\s*(\{\s*\})?\s*(#.*)?$", l)), None)
    if svc is None:
        return None, None, None, None
    end = block_end(lines, svc, 0)
    child = next((indent_of(lines[j]) for j in range(svc + 1, end) if is_content(lines[j])), 2)
    pattern = r"^%sagent:\s*(\{\s*\})?\s*(#.*)?$" % (" " * child)
    agent = next((j for j in range(svc + 1, end) if re.match(pattern, lines[j])), None)
    if agent is None:
        return svc, None, child, None
    a_end = block_end(lines, agent, child)
    key = next((indent_of(lines[j]) for j in range(agent + 1, a_end) if is_content(lines[j])), child + 2)
    return svc, agent, child, key


def mount_lines(indent, source):
    return [
        indent + "- type: bind  " + MARK,
        indent + "  source: " + json.dumps(source) + "  " + MARK,
        indent + "  target: " + MOUNT_TARGET + "  " + MARK,
        indent + "  read_only: true  " + MARK,
    ]


class Conflict(Exception):
    pass


def merge(text, image, source):
    """Returns the merged text, or raises Conflict."""
    lines = text.rstrip("\n").split("\n") if text.strip() else []
    svc, agent, child, key = locate(lines)
    if svc is None:
        lines.append("services:")
    elif re.match(r"^services:\s*\{\s*\}", lines[svc]):
        lines[svc] = "services:"
    svc, agent, child, key = locate(lines)
    if agent is None:
        lines.insert(svc + 1, " " * child + "agent:")
    elif re.match(r"^\s*agent:\s*\{\s*\}", lines[agent]):
        lines[agent] = " " * child + "agent:"
    svc, agent, child, key = locate(lines)
    a_end = block_end(lines, agent, child)

    if image:
        for j in range(agent + 1, a_end):
            if re.match(r"^%s(image|build|pull_policy):" % (" " * key), lines[j]) and MARK not in lines[j]:
                raise Conflict()
        marked = [j for j in range(agent + 1, a_end) if MARK in lines[j] and re.match(r"^\s*image:", lines[j])]
        if marked:
            for j in marked:
                lines[j] = re.sub(r"^(\s*image:\s*)\S+", lambda m: m.group(1) + image, lines[j], count=1)
        else:
            lines[agent + 1:agent + 1] = [" " * key + "image: " + image + "  " + MARK,
                                          " " * key + "pull_policy: never  " + MARK]
            a_end += 2

    if source:
        target = next((j for j in range(agent + 1, a_end)
                       if MARK in lines[j] and re.match(r"^\s*(- )?target: %s\s" % re.escape(MOUNT_TARGET), lines[j])),
                      None)
        if target is not None:
            # abx's own four lines, written together: type, source, target, read_only.
            start = target - 2
            if not (re.match(r"^\s*- type: bind", lines[start]) and re.match(r"^\s*source:", lines[start + 1])
                    and re.match(r"^\s*read_only:", lines[start + 3])):
                raise Conflict()
            lines[start:start + 4] = mount_lines(" " * indent_of(lines[start]), source)
        else:
            vol = next((j for j in range(agent + 1, a_end) if re.match(r"^%svolumes:" % (" " * key), lines[j])), None)
            if vol is None:
                lines[agent + 1:agent + 1] = [" " * key + "volumes:"] + mount_lines(" " * (key + 2), source)
            else:
                if not re.match(r"^\s*volumes:\s*(\[\s*\]|\{\s*\})?\s*(#.*)?$", lines[vol]):
                    raise Conflict()
                if re.match(r"^\s*volumes:\s*(\[\s*\]|\{\s*\})", lines[vol]):
                    lines[vol] = " " * key + "volumes:"
                last, item = vol, None
                for j in range(vol + 1, a_end):
                    if not is_content(lines[j]):
                        continue
                    stripped = lines[j].strip()
                    if indent_of(lines[j]) > key or (indent_of(lines[j]) == key and stripped.startswith("-")):
                        last = j
                        if item is None and stripped.startswith("-"):
                            item = indent_of(lines[j])
                    else:
                        break
                indent = item if item is not None else key + 2
                lines[last + 1:last + 1] = mount_lines(" " * indent, source)

    return "\n".join(lines) + "\n"


path, image, source = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    text = open(path, encoding="utf-8").read()
except FileNotFoundError:
    text = ""
try:
    new = merge(text, image, source)
except Conflict:
    print("conflict")
    sys.exit(0)
if new == text:
    print("unchanged")
    sys.exit(0)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(new)
os.replace(tmp, path)
print("changed")
