#!/usr/bin/env python3
"""Scrubs recorded Claude stream-json fixtures of the recording developer's
environment (public repo). Every system/init line is reduced to the fields the
translator tests can use — session id, model, a neutral cwd, the Watchtower
MCP server and its tools (plus Claude's own ToolSearch) — dropping connectors,
slash commands, skills, agents, plugins, memory paths and socket paths.
Usage: scrub_fixtures.py FILE...  (rewrites each file in place)
       scrub_fixtures.py --claude-ai RAW OUTDIR
The --claude-ai form splits the live claude.ai probe's raw transcript
(claude_ai_live_test.go) into the claude_ai_* fixtures: connector display
names become "Connector A/B…" (Claude Docs, a first-party connector the gate
has rules for, keeps its name), connector ids become fixture ids, connector
URLs are dropped, and init lines lose the recording machine's details.
"""
import json
import re
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


DOCS = "claude.ai Claude Docs"
TOKEN_RE = re.compile(r"[^A-Za-z0-9_-]+")
INIT_KEEP_AI = KEEP + ("apiKeySource",)


def server_token(name):
    """The mcp__<token>__ prefix the CLI derives from a display name."""
    return TOKEN_RE.sub("_", name).strip("_")


class ClaudeAIScrubber:
    def __init__(self):
        self.names = {}
        self.ids = {}

    def learn(self, servers):
        for s in servers:
            n = s.get("name", "")
            if n != DOCS and n not in self.names:
                self.names[n] = "claude.ai Connector " + chr(ord("A") + len(self.names))

    def server(self, s):
        out = dict(s)
        out["name"] = self.names.get(s.get("name"), s.get("name"))
        if "config" in out:
            out["config"] = {"type": out["config"].get("type")}
        return out

    def text(self, raw):
        for real, fake in self.names.items():
            raw = raw.replace(server_token(real), server_token(fake)).replace(real, fake)

        def fixture_id(m):
            self.ids.setdefault(m.group(0), "mcpsrv_fixture_%d" % (len(self.ids) + 1))
            return self.ids[m.group(0)]

        return re.sub(r"mcpsrv_[A-Za-z0-9]+", fixture_id, raw)

    def line(self, d):
        if d.get("type") == "system" and d.get("subtype") == "init":
            out = {k: d[k] for k in INIT_KEEP_AI if k in d}
            out["cwd"] = d.get("cwd")
            out["tools"] = [t for t in d.get("tools", []) if not t.startswith("mcp__") or t.startswith("mcp__claude_ai_")]
            out["mcp_servers"] = [self.server(s) for s in d.get("mcp_servers", [])]
            d = out
        elif d.get("type") == "control_response" and "mcpServers" in d["response"].get("response", {}):
            d = json.loads(json.dumps(d))
            body = d["response"]["response"]
            body["mcpServers"] = [self.server(s) for s in body["mcpServers"]]
        elif d.get("type") == "result":
            d = {k: d[k] for k in ("type", "subtype", "is_error", "session_id", "permission_denials", "terminal_reason") if k in d}
        d = scrub_values(d, [0])
        return json.loads(self.text(json.dumps(d, ensure_ascii=False)))


def is_mcp_status(x):
    return x.get("type") == "control_response" and "mcpServers" in x.get("response", {}).get("response", {})


def claude_ai(raw_path, out_dir):
    rows = [json.loads(l) for l in open(raw_path) if l.strip()]
    sc = ClaudeAIScrubber()
    for r in rows:
        x = r["line"]
        if is_mcp_status(x):
            sc.learn(x["response"]["response"]["mcpServers"])
        if x.get("type") == "system" and x.get("subtype") == "init":
            sc.learn(x.get("mcp_servers", []))

    files = {k: [] for k in ("init", "mcp_status", "can_use_tool", "control_responses", "control_other")}
    seen_init = set()
    status_req = {}
    statuses = {}
    for r in rows:
        x, sc_name, inbound = r["line"], r["scenario"], r["dir"] == "in"
        typ, sub = x.get("type"), x.get("subtype")
        if inbound and typ == "system" and sub == "init" and sc_name not in seen_init:
            seen_init.add(sc_name)
            files["init"].append(x)
        elif not inbound and typ == "control_request" and x["request"].get("subtype") == "mcp_status":
            status_req[x["request_id"]] = x
        elif inbound and is_mcp_status(x):
            statuses.setdefault(sc_name, []).append(x)
        elif inbound and typ == "control_request" and x["request"].get("subtype") == "can_use_tool":
            files["can_use_tool"].append(x)
        elif not inbound and typ == "control_response":
            files["control_responses"].append(x)
        elif inbound and (typ == "control_cancel_request"
                          or (typ == "control_response" and not is_mcp_status(x))
                          or (typ == "system" and sub == "permission_denied")
                          or (typ == "result" and x.get("permission_denials"))):
            files["control_other"].append(x)
        elif inbound and typ == "user":
            errs = [c for c in x["message"]["content"] if isinstance(c, dict) and c.get("type") == "tool_result" and c.get("is_error")]
            if errs:
                files["control_other"].append(x)
    # Per scenario: the first answer (often still empty), the first one that
    # lists servers while some are pending, and the settled last one.
    for sc_name, resps in statuses.items():
        keep = [resps[0]]
        pending = [x for x in resps if any(s.get("status") == "pending" for s in x["response"]["response"]["mcpServers"])]
        keep += pending[:1] + [resps[-1]]
        done = set()
        for x in keep:
            rid = x["response"]["request_id"]
            if rid in done:
                continue
            done.add(rid)
            files["mcp_status"] += [status_req[rid], x]

    names = {"init": "claude_ai_init.jsonl", "mcp_status": "claude_ai_mcp_status.jsonl",
             "can_use_tool": "claude_ai_can_use_tool.jsonl",
             "control_responses": "claude_ai_control_responses.jsonl",
             "control_other": "claude_ai_control_other.jsonl"}
    leaks = re.compile(r"/Users/|/private/var/|/var/folders/|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|mcpsrv_0")
    for key, fname in names.items():
        text = "".join(json.dumps(sc.line(x), separators=(",", ":"), ensure_ascii=False) + "\n" for x in files[key])
        bad = [n for n in sc.names if n in text] + leaks.findall(text)
        if bad:
            sys.exit("scrub: %s still carries %d account-specific value(s)" % (fname, len(bad)))
        with open("%s/%s" % (out_dir, fname), "w") as f:
            f.write(text)


if __name__ == "__main__":
    if sys.argv[1:2] == ["--claude-ai"]:
        claude_ai(sys.argv[2], sys.argv[3])
    else:
        main(sys.argv[1:])
