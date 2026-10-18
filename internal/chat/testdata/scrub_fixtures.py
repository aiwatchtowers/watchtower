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
        """Claude Docs keeps its tools and serverInfo (public, first-party);
        any other connector keeps only an allowlist — its tools, serverInfo
        and descriptions could name a company or a workspace."""
        if s.get("name") == DOCS:
            out = dict(s)
        else:
            out = {k: s[k] for k in ("name", "status", "scope", "source") if k in s}
            out["name"] = self.names.get(s.get("name"), s.get("name"))
        if "config" in s:
            out["config"] = {"type": s["config"].get("type")}
        return out

    def text(self, raw):
        # Longest first and whole names only, so "X (2)" is never rewritten
        # through its prefix "X"; a token only inside mcp__<token>__.
        for real, fake in sorted(self.names.items(), key=lambda kv: -len(kv[0])):
            raw = re.sub(r"(?<=mcp__)%s(?=__)" % re.escape(server_token(real)), lambda _: server_token(fake), raw)
            raw = re.sub(r"%s(?![A-Za-z0-9])" % re.escape(real), lambda _: fake, raw)

        def fixture_id(m):
            self.ids.setdefault(m.group(0), "mcpsrv_fixture_%d" % (len(self.ids) + 1))
            return self.ids[m.group(0)]

        return re.sub(r"mcpsrv_[A-Za-z0-9]+", fixture_id, raw)

    def line(self, d):
        if d.get("type") == "system" and d.get("subtype") == "init":
            out = {k: d[k] for k in INIT_KEEP_AI if k in d}
            out["cwd"] = d.get("cwd")
            # Built-ins and Claude Docs only: another connector's tool names
            # could name a company or a workspace.
            out["tools"] = [t for t in d.get("tools", []) if not t.startswith("mcp__") or t.startswith("mcp__claude_ai_Claude_Docs__")]
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


def outbound_bucket(x):
    """The fixture of a line the host sent: an mcp_status request (kept with
    its answer) or a control response."""
    if x.get("type") == "control_request" and x["request"].get("subtype") == "mcp_status":
        return "status_req"
    return "control_responses" if x.get("type") == "control_response" else None


def has_error_result(x):
    return any(isinstance(c, dict) and c.get("type") == "tool_result" and c.get("is_error")
               for c in x["message"]["content"])


def is_control_other(x):
    typ, sub = x.get("type"), x.get("subtype")
    return (typ in ("control_cancel_request", "control_response")
            or (typ == "system" and sub == "permission_denied")
            or (typ == "result" and bool(x.get("permission_denials")))
            or (typ == "user" and has_error_result(x)))


def inbound_bucket(x):
    """The fixture of a line the CLI sent: its init (first per scenario), an
    mcp_status answer, a permission request, or another control line."""
    if x.get("type") == "system" and x.get("subtype") == "init":
        return "init"
    if is_mcp_status(x):
        return "status"
    if x.get("type") == "control_request" and x["request"].get("subtype") == "can_use_tool":
        return "can_use_tool"
    return "control_other" if is_control_other(x) else None


def kept_status_lines(statuses, status_req):
    """Per scenario: the first mcp_status answer (often still empty), the
    first one that lists servers while some are pending, and the settled last
    one, each after its request."""
    out = []
    for resps in statuses.values():
        pending = [x for x in resps if any(s.get("status") == "pending" for s in x["response"]["response"]["mcpServers"])]
        done = set()
        for x in [resps[0]] + pending[:1] + [resps[-1]]:
            rid = x["response"]["request_id"]
            if rid not in done:
                done.add(rid)
                out += [status_req[rid], x]
    return out


def route_lines(rows):
    """Sorts the transcript's lines into the fixture files."""
    files = {k: [] for k in ("init", "mcp_status", "can_use_tool", "control_responses", "control_other")}
    seen_init, status_req, statuses = set(), {}, {}
    for r in rows:
        x, sc_name = r["line"], r["scenario"]
        bucket = inbound_bucket(x) if r["dir"] == "in" else outbound_bucket(x)
        if bucket == "init":
            if sc_name not in seen_init:
                seen_init.add(sc_name)
                files["init"].append(x)
        elif bucket == "status_req":
            status_req[x["request_id"]] = x
        elif bucket == "status":
            statuses.setdefault(sc_name, []).append(x)
        elif bucket:
            files[bucket].append(x)
    files["mcp_status"] = kept_status_lines(statuses, status_req)
    return files


def write_fixtures(sc, files, names, out_dir):
    """Writes the fixture files once every one is free of account-specific
    values; exits without writing anything otherwise."""
    if not any(x["request"].get("mcp_server") for x in files["can_use_tool"]):
        sys.exit("scrub: no connector can_use_tool recorded (Claude Docs not probed); not writing fixtures")
    # Every class of value that must not reach the public repo; hits are
    # reported by class, never echoed.
    checks = {
        "path": re.compile(r"/Users/|/private/var/|/var/folders/"),
        "email": re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"),
        "connector id": re.compile(r"mcpsrv_(?!fixture_)"),
        "host": re.compile(r"https?://(?!claude\.ai/)[^\s\"]+"),
    }
    real = set()
    for n in sc.names:
        real |= {n, n[len("claude.ai "):] if n.startswith("claude.ai ") else n, server_token(n)}
    texts = {}
    for key, fname in names.items():
        if not files[key]:
            sys.exit("scrub: nothing recorded for %s; not writing fixtures" % fname)
        text = "".join(json.dumps(sc.line(x), separators=(",", ":"), ensure_ascii=False) + "\n" for x in files[key])
        hits = [cls for cls, rx in checks.items() if rx.search(text)]
        if any(n.lower() in text.lower() for n in real):
            hits.append("connector name")
        if hits:
            sys.exit("scrub: %s still carries account-specific values (%s); nothing written" % (fname, ", ".join(hits)))
        texts[fname] = text
    for fname, text in texts.items():  # all checked first: no half-updated set
        with open("%s/%s" % (out_dir, fname), "w") as f:
            f.write(text)



def claude_ai(raw_path, out_dir):
    rows = [json.loads(l) for l in open(raw_path) if l.strip()]
    if not rows:
        sys.exit("scrub: %s has no rows: did the probe skip?" % raw_path)
    if any("non_json" in r["line"] for r in rows):
        sys.exit("scrub: the raw transcript has a non-JSON CLI line; check the probe log")
    sc = ClaudeAIScrubber()
    for r in rows:
        x = r["line"]
        if is_mcp_status(x):
            sc.learn(x["response"]["response"]["mcpServers"])
        if x.get("type") == "system" and x.get("subtype") == "init":
            sc.learn(x.get("mcp_servers", []))

    files = route_lines(rows)

    names = {"init": "claude_ai_init.jsonl", "mcp_status": "claude_ai_mcp_status.jsonl",
             "can_use_tool": "claude_ai_can_use_tool.jsonl",
             "control_responses": "claude_ai_control_responses.jsonl",
             "control_other": "claude_ai_control_other.jsonl"}
    write_fixtures(sc, files, names, out_dir)


if __name__ == "__main__":
    if sys.argv[1:2] == ["--claude-ai"]:
        claude_ai(sys.argv[2], sys.argv[3])
    else:
        main(sys.argv[1:])
