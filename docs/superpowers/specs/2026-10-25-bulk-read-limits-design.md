# Bulk-read limits and an audit log — design (board #606)

Part of board group #595 (corporate data on the Mac). Siblings: #603 encrypts
the database, #601 purges revoked accounts, #608 adds an MDM policy (managed
preferences) that may set the limits defined here. Status: approved by the
owner 2026-10-25 (ask #567) with the recommended answer to every question:
Q1 300 calls / 5 000 rows per session, 200 rows / 256 KB per response; Q2
refuse, a new session starts a fresh budget; Q3 the same limits on every
surface, the owner's chat included; Q4 limits and the log on for every
install. The AUTO-08 amendment and the new READ-01..02 inventory entries in
"Contracts that change" are approved with it.

## Goal

Watchtower holds a company's correspondence, and several things inside it can
read that correspondence on a model's say-so: the workbench agent ("dump all
correspondence with X into a file"), the chat's MCP tools, automations
(`tool()`, `agent()`, `session()`, `mcp()`, with `output.slack` and `shell()` as
ways out), and any MCP client registered with plain `watchtower mcp`. A prompt
injection in synced content, or a person who wants a copy, can page through
the data one tool call at a time.

After this change:

- every read of company data through Watchtower's own tools is bounded per
  response and per session/run, and a session that hits the bound is refused,
  not slowed;
- every such read leaves one line in the macOS unified log under Watchtower's
  own subsystem — tool, surface, session, row count, never content — so the
  company's EDR or Jamf collects it on its own. Watchtower sends nothing
  anywhere.

Not a goal: making exfiltration impossible (see "What cannot be capped"), and
no export or dump command — the CLI has none and gets none.

## What exists today

- **One read path.** Every Watchtower read tool is a `tools.Tool{Access:
  AccessRead}` in the registry (`tools.ReadTools()` plus
  `DependentReadTools` — memory, `load_skill` — plus the automation reads and
  the workbench tools), and every surface dispatches it through
  `Registry.CallRead` (`internal/tools/registry.go`): the MCP adapter
  (`internal/mcp/actions.go` `readToolHandler`, all server modes), the
  runtime-B loop (`internal/agentloop`), and automations' `tool()`
  (`internal/automations/sdk_tool.go`). `CallRead` writes nothing (DEV-01,
  AGENT-02: plain `watchtower mcp` runs under `query_only`).
- **Per-response caps already exist, tool by tool.** List tools clamp `limit`
  to `tools.MaxListLimit` (200; default 50, `list_messages` 30);
  `search_knowledge` to 25 hits; `get_knowledge_document` to 50 000
  characters; `get_email` clips the body (`tools.MaxEmailBodyBytes`).
  Automations refuse any SDK result over `MaxSDKResultBytes` (256 KB,
  `ResultTooLarge`). Nothing caps the number of calls, and nothing caps the
  plain `get_*` tools' size outside automations (`get_transcript` returns a
  whole transcript).
- **Per-run bounds in automations only:** `MaxStepsPerRun` (2000 SDK calls),
  tokens and minutes (AUTO-08), 12 model calls per `agent()`,
  `MaxSessionCalls` (10). No surface counts rows.
- **Logging.** The Go side logs to files (`daemon.log`, `dblock.jsonl`); the
  Desktop uses `os.Logger` with subsystem `com.watchtower.desktop`. Nothing
  writes an audit trail of reads, and no Go code talks to the unified log.

### What a "session" is on each surface

Every surface below already gives the registry one `Binding` per process or
per run, so a session is a key the registry can derive from the binding:

| Surface | Process | Session key |
| --- | --- | --- |
| plain `watchtower mcp` (any MCP client) | one per client session | `pid:<pid>` |
| `mcp --workbench N` (Claude Code / Codex in a workbench terminal, also an automation's `session()`) | one per agent session | `terminal:<WATCHTOWER_TERMINAL_SESSION_ID>`, else `pid:<pid>` |
| `mcp --chat --surface main\|target\|automation_editor` (warm `ai session`) and the runtime-B loop | one per chat session process | `conversation:<id>` |
| automations `tool()` (in the daemon) | the daemon, many runs | `run:<run id>` |
| `mcp --chat --surface automation --automation-run N` (an `agent()` CLI child) | one per `agent()` call | `run:<N>` (own counter, see Design §2) |

## Design

### 1. One gate in `Registry.CallRead`

A new optional field on `tools.Tool`, `CompanyData bool`, marks the read tools
that return synced source content: messages, email, calendar, Jira, Linear,
Confluence/knowledge, transcripts and recaps, digests, tracks, people cards,
memory, ideas, briefings, day plans, inbox, task context, experts. Workbench
board/asks/review tools, `load_skill`, `get_action` and the like stay
unmarked — they read the owner's own board, not the company's mail, and
counting them would break long coding sessions for no gain. A registry test
fails when a new read tool is registered without an explicit decision (a
listed allowlist of unmarked tools), so a future tool cannot slip past by
default.

`CallRead` wraps a `CompanyData` tool's `Execute`:

1. **Before:** if the session's budget is spent, refuse with a model-facing
   `ValidationError`: "this session's read limit is reached (N calls / M rows);
   the owner can start a new session". No `Execute` runs.
2. **After:** count the result's rows — the length of a top-level array, or
   the sum of the lengths of a result object's top-level arrays, else 1 —
   and its marshalled size. Over the per-response byte cap the result is
   refused as `ResultTooLarge` with "narrow the request" (the same rule and
   number automations use today, moved to `tools` as the one copy). The row
   cap per response is the existing `MaxListLimit` clamp; a registry test pins
   that every `CompanyData` list tool's `limit` is clamped to it.
3. **Debit** the call and its rows to the session, then write the log line
   (§3).

Because every surface reaches company data only through `CallRead`, this is
the one place for Go; automations keep their own result-size check as a
second fence only where they already have it.

### 2. Budgets

Per session (the keys above), in memory, owned by the `Registry`:

- **calls:** `CompanyData` read calls per session (proposed 300);
- **rows:** rows returned per session (proposed 5 000);
- **per response:** 200 rows (today's clamp) and 256 KB.

The numbers are one `tools.ReadLimits` value with these defaults. #608's
policy, when present, replaces it (the same seam order as `purge.Enabled`:
policy > built-in default); there is no config key in v1, so an agent cannot
raise its own budget by writing `config.yaml`.

In memory is enough because each session key lives in one process — except
`run:<N>`, which an `agent()` CLI child shares with its daemon run. The child
gets its own counter under the same key, so a run can read its own budget plus
one budget per `agent()` call (and a `session()` child is a workbench session
with its own); the log ties all of them to one run id. Restarting a process (a reconnected MCP server) starts
a fresh counter; the log shows both.

### 3. The unified log

A new package `internal/auditlog` with one function, `Read(Event)`, and a
darwin cgo file (cgo is already required by `internal/sqlcipher`):

- `os_log_create("com.watchtower.audit", "read")`, created once;
- a C helper `wt_audit(os_log_t, const char *line)` calling
  `os_log(l, "%{public}s", line)` — default level, so it is persisted by the
  system log without any profile; `%{public}` because the line holds no
  content (without it the system log stores `<private>`);
- a no-op build for other platforms (Linux CI).

`logger(1)` was considered and dropped: it writes through syslog without our
subsystem, so an EDR cannot filter on it, and it forks a process per call.

One line per `CompanyData` read call (and per refusal), as one-line JSON with
pinned keys:

```json
{"v":1,"proc":"mcp","surface":"workbench","session":"terminal:42","workbench":7,
 "agent":"claude","tool":"list_messages","filters":["person","query"],
 "rows":200,"bytes":61234,"calls":17,"rows_total":2410,"result":"ok"}
```

- `filters` lists the argument **names** that were set, never their values:
  a query text or a person's name is content.
- `result`: `ok`, `limit_reached` (refused by §1.1), `too_large`, `error`.
- No message text, subject, name, email, id of a Slack/Jira object, or file
  path ever enters the line. A test feeds a result carrying a marker string
  and asserts the line never contains it.

The company reads it with `log show --predicate 'subsystem ==
"com.watchtower.audit"'` or its EDR's own collector; the user guide's privacy
page says so. Retention is the system's (a few days on a normal Mac);
collecting is the EDR's job.

### 4. Other reads that get a log line, without a cap

- **Automations `mcp()`** (`externalmcp.CallTool`): one line with
  `tool: "mcp:<connection>/<tool>"`, bytes, no rows; counted as a call in the
  run's budget.
- **CLI commands that print synced content** (`kb search`, `digest`,
  `gmail`, `jira`, `people`, `tracks`, `catchup`, `briefing`, `memory`, …):
  one line with `proc: "cli:<path>"` (the path's words joined by `/`, e.g.
  `cli:kb/search`) when the command actually ran under an agent marker
  (`WATCHTOWER_TERMINAL_SESSION_ID` or `WATCHTOWER_AUTOMATION_RUN_ID`),
  i.e. when an agent's Bash ran them — not for `--help`, a usage error or
  an unknown command. No cap: the CLI is the owner's tool and
  the owner said no export commands, not no reads.

### 5. What cannot be capped (honestly)

- **The agent's own shell.** A workbench agent with Bash, or an automation's
  `shell()` command, can open the database file with `sqlite3`, read the
  memory vault or the transcript files directly. Today that is unbounded and
  unlogged. #603 helps: once the database is encrypted with a key the agent
  does not hold, a raw read gets nothing. Files outside the database (vault,
  recordings) stay readable to anything running as the user.
- **The CLI under an agent** is logged (§4) but not capped.
- **Quick Connections in the chat** are called by the vendor CLI directly
  (QC-02) and never pass through Go; the data comes from the external server,
  whose own logs are the company's record. claude.ai connectors in the chat
  go through the permission gate but read from Anthropic-side services, not
  from Watchtower's database.
- **Everything a model reads goes to its provider.** The caps limit how much
  a session can read; they do not change where a provider sends it.
- **Ways out after a read** — `send_slack_message`/`output.slack`
  (owner-approved or bound to a grant), private publishing to claude.ai, a
  file the agent writes in the workbench folder, the mobile companion's
  slices — are bounded only by what the session could read.
- **A new session resets the budget.** The caps stop a runaway loop or an
  injection inside one session; a determined person opens another one. The
  log is the control against that.

## Contracts that change

- **DEV-01 / AGENT-02** — unchanged: the gate refuses or logs, it writes no
  row, and plain `watchtower mcp` stays under `query_only` (the counter is in
  memory, the log is not the database).
- **AUTO-08** — amended: a run is also bounded by the read budget; reaching
  it is a catchable `ValidationError` on that call, not an interrupt.
- **AGENT-06** and the surfaces' tool lists — unchanged: no tool is added,
  removed or re-classed.
- New inventory entries `READ-01..02` (in `agent-actions.md`): every
  `CompanyData` read goes through the one budget gate and is refused past it;
  every such read writes exactly one content-free audit line.

## Questions for the owner

- **Q1. The numbers** — 300 calls and 5 000 rows per session/run, 200 rows
  and 256 KB per response (recommended); tighter: 100 calls / 2 000 rows;
  looser: 1 000 calls / 20 000 rows.
- **Q2. Past the limit** — refuse with a clear message, a new session starts
  a fresh budget (recommended); file an owner ask that grants one more
  budget; never refuse, only log.
- **Q3. The owner's own chat** — the same limits on every surface, the main
  chat included: an injection reaches the chat's model too (recommended);
  agents only (workbench, automations, plain `mcp`), the chat only logged;
  the chat with limits three times higher.
- **Q4. Who has it on** — limits and the log on for every install
  (recommended: the numbers are generous for a person, the log stays on the
  Mac); the log for everyone, limits only in the corp build and under MDM;
  both only in the corp build and under MDM.

## Later

- #608: the managed policy sets `ReadLimits` (and can lower them per surface).
- A per-install daily budget across sessions needs a writable counter that
  plain `mcp` (`query_only`) cannot keep; a sidecar file under a flock, like
  `dblock.jsonl`, is the likely shape if a session budget proves too easy to
  reset.
- With #603 in place, a workbench agent's raw `sqlite3` read stops working;
  the vault and recordings would need the same treatment to close that path.
