# Bulk-read limits and the audit log (2026-10-25, board #606)

Every read of company data through Watchtower's own tools is capped per
response and per session, refused past the cap, and leaves one content-free
line in the macOS unified log. Spec:
`docs/superpowers/specs/2026-10-25-bulk-read-limits-design.md` (approved
2026-10-25, ask #567). Inventory: READ-01..02 in
`docs/inventory/agent-actions.md`, AUTO-08 amended in
`docs/inventory/automations.md`.

## Which tools count

`tools.Tool.CompanyData` marks the read tools that return synced source
content (messages, email, calendar, Jira, Linear, Confluence/knowledge,
transcripts and recaps, digests, tracks, people cards, memory, ideas,
briefings, day plans, inbox, reminders, task context, experts, the writing
style, automation run details). Every other read tool is in
`unmarkedReadTools` (`internal/tools/company_data.go`) with a reason — the
owner's own board, asks, review, skills, names-only listings, the owner's
recipes. `tools.UndecidedReadTools` is the guard; it runs over the tools
package's list (`TestRead01_EveryReadToolDecided`) and over the registries
cmd really mounts (`TestRead01_BuildRegistryReadToolsDecided`), so a new read
tool must be decided.

## The gate

`Registry.CallRead` sends a `CompanyData` tool through `callCompanyRead`
(`internal/tools/readbudget.go`); an unmarked tool skips it entirely and
writes no line. In order:

1. Compute the session key once; `admitRead` reserves a call slot or refuses a
   spent session (calls ≥ `Calls` or rows ≥ `Rows`) with
   `*ValidationError{Err: ErrReadLimit}`, text
   `this session's read limit is reached (<calls> calls / <rows> rows); the owner can start a new session`.
   No `Execute` runs; the refusal writes a `limit_reached` line.
2. Schema check; a refusal still counts (failed calls spend the budget).
3. `Execute` — an error is recorded `error` (rows 0) and returned unchanged; a
   panic is recorded `error` in a defer and re-raised.
4. Marshal and measure: rows = a top-level array's length, or the sum of an
   object's top-level arrays, else 1 (`null` = 0); bytes = marshalled size.
5. Too large: bytes > `ResponseBytes`, or — for a tool whose schema takes
   `limit` — the largest single array > `ResponseRows` (the backstop behind
   the `listLimit` clamp). Refused with `ErrResultTooLarge`; the rows read are
   still debited.
6. Debit the rows and write the `ok` line.

The call cap is exact (the slot is reserved before `Execute`); the row cap is
soft — rows are debited after the read, so parallel calls admitted under the
cap may together pass it.

## Limits

`tools.DefaultReadLimits`: `Calls 300`, `Rows 5000` per session,
`ResponseRows 200` (`MaxListLimit`), `ResponseBytes 256 KiB`
(`tools.MaxReadResultBytes`, the one copy — `automations.MaxSDKResultBytes`
refers to it). On for every install and surface, the main chat included. No
config key: `Registry.SetReadLimits` is the seam for #608's managed policy.

## draft_automation's dry run

Each draft builds its own backends (a fresh registry), so
`automationAuthoringDeps(cfg, db, reg)` makes that registry spend the
calling registry's budget (`Registry.ShareReadBudget`), and the dry run's
binding carries the caller's `ConversationID` (`DryRunOptions` →
`Env.ConversationID`): drafts in one conversation share one budget.

## Session keys

| Binding | Key |
| --- | --- |
| `AutomationRunID` set (daemon `tool()`/`mcp()`, an `agent()` CLI child's `--automation-run N` server) | `run:<N>` |
| `ConversationID` set (`mcp --chat`, one conversation per warm `ai session` child; runtime-B loop) | `conversation:<id>` |
| neither, inside a Desktop terminal session (`mcp --workbench N`, a `session()` child) | `terminal:<WATCHTOWER_TERMINAL_SESSION_ID>` |
| neither (plain `watchtower mcp` for any client) | `pid:<pid>` |

The process key is set by `internalmcp.WithReadSession` (every `mcp` mode,
`mcpProcessSessionKey`). Counters live in memory: a restarted process starts
fresh, and an `agent()` child keeps its own counter under its run's key. No
database row is written, so a `query_only` handle serves the gate (DEV-01,
AGENT-02).

## The audit log

`internal/auditlog`: `os_log_create("com.watchtower.audit", "read")` once,
`os_log(l, "%{public}s", line)` at the default level (persisted without a
profile; `%{public}` because the line holds no content). A no-op off darwin.
`auditlog.SetProcess` records the process role (`daemon`, `mcp`,
`cli:<path>` with `/` between words) for lines with no `proc`.

One line per counted call and per refusal, one-line JSON in the pinned key
order `v proc surface session workbench agent tool filters rows bytes calls
rows_total result` (`v` = 1, `workbench`/`agent` omitted when unset,
`result` ∈ `ok`, `limit_reached`, `too_large`, `error`). `filters` holds the
names of the set arguments the tool's schema declares, sorted, never values;
any other key shows as one `_other` (a key may itself be content). Strings are clipped and
keep only `[A-Za-z0-9_.:/-]`, at most 8 filter names: a line stays under
~760 bytes, well inside os_log's public-argument limit. Read it with
`log show --predicate 'subsystem == "com.watchtower.audit"'`; retention is
the system's. Tests replace the sink (`auditlog.SetSinkForTest`) in every
package TestMain whose tests reach `CallRead`.

## Other reads with a line

- **Automations `mcp()`** — `Registry.ReadExternal` admits the call in the
  run's budget (a refusal is a catchable `ValidationError`, nothing is sent),
  runs it and records `mcp:<server>/<tool>` with bytes and no rows (`error`
  on a failure or panic; past the byte cap `too_large`, and the result is
  refused like a registry read). A registry
  `ErrResultTooLarge` reaches a script as `ResultTooLarge`, `ErrReadLimit` as
  `ValidationError` (AUTO-08).
- **CLI content commands** (`cliContentCommands` in `cmd/audit_cli.go`) —
  one line, uncapped, only when the command's Run started (not `--help`, a
  usage error or an unknown command) and `WATCHTOWER_TERMINAL_SESSION_ID` or
  `WATCHTOWER_AUTOMATION_RUN_ID` is set (`terminal:` wins). Commands that
  print something but are left out are listed with a reason in
  `cliExcludedCommands` (`cmd/audit_cli_test.go`); `tools call` is one of
  them because it reads through the registry gate.

## What cannot be capped

- The agent's own shell can read the database, the vault and the recordings
  directly (#603's encryption closes the database path once the agent lacks
  the key).
- The CLI under an agent is logged, not capped.
- Quick Connections in the chat and claude.ai connectors never pass through
  Go.
- Everything a model reads goes to its provider; the caps bound how much,
  not where.
- Ways out after a read (Slack send, publishing, files, the phone slices) are
  bounded only by what the session could read.
- A new session resets the budget; the log is the control against that.
