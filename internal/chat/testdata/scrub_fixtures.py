#!/usr/bin/env python3
"""Scrubs recorded Claude stream-json fixtures of the recording developer's
environment (public repo). Every system/init line is reduced to the fields the
translator tests can use — session id, model, a neutral cwd, the Watchtower
MCP server and its tools (plus Claude's own ToolSearch) — dropping connectors,
slash commands, skills, agents, plugins, memory paths and socket paths.
Usage: scrub_fixtures.py FILE...  (rewrites each file in place)
"""
import json
import sys

KEEP = ("type", "subtype", "session_id", "model", "permissionMode", "claude_code_version")


def scrub_init(d):
    out = {k: d[k] for k in KEEP if k in d}
    out["cwd"] = "/work"
    out["tools"] = [t for t in d.get("tools", []) if t == "ToolSearch" or t.startswith("mcp__watchtower__")]
    out["mcp_servers"] = [s for s in d.get("mcp_servers", []) if s.get("name") == "watchtower"]
    return out


def scrub_values(v, counter):
    """Neutralizes account-linked values anywhere in a line: thinking-block
    signatures, API request ids, and the rate-limit details (plan/org state,
    utilization) — keeping only the rate-limit status."""
    if isinstance(v, list):
        return [scrub_values(x, counter) for x in v]
    if not isinstance(v, dict):
        return v
    out = {}
    for k, x in v.items():
        if k == "signature" and isinstance(x, str) and x:
            x = "fixture-signature"
        elif k == "request_id" and isinstance(x, str) and x.startswith("req_"):
            counter[0] += 1
            x = "req_fixture_%d" % counter[0]
        elif k == "rate_limit_info" and isinstance(x, dict):
            x = {"status": x.get("status", "allowed")}
        else:
            x = scrub_values(x, counter)
        out[k] = x
    return out


def main(paths):
    for path in paths:
        lines = []
        counter = [0]
        with open(path) as f:
            for line in f:
                if not line.strip():
                    lines.append(line)
                    continue
                d = json.loads(line)
                if d.get("type") == "system" and d.get("subtype") == "init":
                    d = scrub_init(d)
                scrubbed = scrub_values(d, counter)
                if scrubbed != json.loads(line):
                    line = json.dumps(scrubbed, separators=(",", ":"), ensure_ascii=False) + "\n"
                lines.append(line)
        with open(path, "w") as f:
            f.writelines(lines)


if __name__ == "__main__":
    main(sys.argv[1:])
