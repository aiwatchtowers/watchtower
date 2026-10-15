# Automations — design

**Status:** Approved, 2026-10-14. Owner-approved shape: asks #259–#267; business spec approved in ask #269; the
open questions decided in ask #270 (§20); the questions the phase plans raised decided in asks #271–#273, the extra local-store read tools in ask #277
(§20.1); the rulings made while P1 was built in asks #280 and #287 (§20.2); the rulings after P1 in asks #293, #294
and #295 (§20.3). The Desktop UI mockups (seven screens: tab, describe-in-words, confirm, edit form, templates, quick run
(drawn with ⌘K, bound to ⌃⌘R by the owner's ruling), menu-bar run) were approved by the owner on 2026-10-15; §12 describes them in words.
The AGENT-03 amendment (§14.2) is owner-approved (ask #265); the STRIP-01 and AGENT-04 amendments (§14.4, §14.5)
are approved with §20 (ask #270); the PROJ-03 and QC-02 amendments (§14.6, §14.7) are approved in ask #272.
**Business spec:** `2026-10-14-automations-business.md`. **Plans:** one per phase,
`docs/superpowers/plans/2026-10-14-automations-p1.md` … `-p6.md`.
**Branch:** `feature/automations`; each phase is its own plan and PR into it; `main` only by one PR with the
owner's approval.
**Related:** Agent Actions (`docs/features/agent-actions.md`, AGENT-01..07), Workbench owner asks and sessions
(`docs/features/workbench.md`, PROJ-11/12/13), embedded chat (`docs/features/embedded-chat.md`), Quick
Connections (QC-01..04), Reaction Commands (STRIP-01..03), Model & Provider Registry, strong-tier cost fixes.
**Touches:** new `internal/automations/` (recipe, manifest, sandbox, sdk, executor, scheduler, events), new
`cmd/automations*.go`, `internal/tools/registry.go` (surface + binding + trust order), `cmd/actions_registry.go`,
`internal/daemon/` (scheduler/executor goroutines, wake signal, event publishing from sync phases),
`internal/digest/models.go` + `tier_scan_test.go` (source tags), `internal/briefing/` (P2), `internal/skills/shipped/`
(P3), `internal/config/` (one key), migrations 00113 and 00116–00117 (00114 and 00115 are unrelated main migrations), `internal/db/schema.sql`; Desktop: new Automations
tab, `AgentActionCardView` label, Inbox strip (P3), workbench header buttons and session requests (P5); new
`docs/inventory/automations.md`. New Go dependencies: `github.com/dop251/goja` (sandbox) and
`github.com/robfig/cron/v3` (its standard 5-field parser only; its scheduler is not used).

## 1. Vocabulary and scope

- **Automation** — one recipe file plus its index row. **Recipe** — the file. **Run** — one execution, a row of
  `automation_runs`. **Step** — one SDK call inside a run, a row of `automation_run_steps`.
- **Personal automation** — recipe in the owner's data folder, bound to no workbench, headless (managers' use).
- **Workbench automation** — recipe in a workbench repository, bound to that workbench; may additionally use
  `session()`, `shell()` and `ask()` (developers' use).
- The CLI is `watchtower automations …` (`watchtower actions` is Agent Actions). Package `internal/automations/`.
  Desktop tab "Automations". Registry surface `automation`.

## 2. Recipe file

### 2.1 Location (ask #266)

- Personal: `<workspace dir>/automations/*.md` — `config.WorkspaceDir()` (`~/.local/share/watchtower/<workspace>/`),
  beside `skills/`. Decided in ask #270 (§20 D8): the workspace dir, not
  `~/Library/Application Support`.
- Workbench: `<workbench folder>/.watchtower/automations/*.md`. **Renamed** from the ask's `.watchtower/actions/`
  so the folder matches the feature name. Nothing else lives under `.watchtower/` today.
- The filename stem is the automation's **slug** (`^[a-z0-9][a-z0-9-]{0,63}$`, the skills name rule); a file
  whose stem does not match is reported by `rescan` and not indexed. Other extensions are ignored.
- Max file size 256 KiB; larger → parse error, not indexed as runnable.
- **Only regular files are read (P1 implementation, controller decision).** The indexer lists a folder with lstat
  semantics and never follows an entry: a symlink (inside, outside or dangling) or a special file (FIFO, socket,
  device) named `*.md` is skipped with "symlinks and special files are not read; put the recipe file itself in the
  folder" and never opened; a recipe replaced by a symlink is marked removed; a directory named `*.md` is ignored.
  A regular file is read Lstat → `open(O_NOFOLLOW|O_NONBLOCK)` → fstat (regular, same inode). The folder path itself
  is canonicalised (`Abs` + `EvalSymlinks` on the deepest existing ancestor). A slug already used in the scope by a
  row at another path (a removed one included) is a skip with a message naming that row. P5 follows the same policy.

### 2.2 Shape

~~~
---
name: New mail summary
trigger:
  schedule: "0 9 * * 1-5"
missed: run_once
permissions:
  - gmail:read@work
  - llm:light
outputs: [inbox]
budget: { tokens: 40000, minutes: 5 }
---
Free Markdown description for humans (shown on the card).

```js
const mail = tool("list_emails", { account: "work", since: state.get("since") });
…
```
~~~

Exactly one fenced block with info string `js` (or `javascript`); zero or two+ → parse error, and so is an empty
block (P1: stricter than "exactly one" alone). Text outside the
block is description. Unknown frontmatter keys → parse error (strict, unlike skills: a typo in `permissions`
must not silently grant nothing or everything).

### 2.3 Frontmatter keys

| Key | Type | Default | Rules |
|---|---|---|---|
| `name` | string | required | 1–80 chars |
| `trigger` | map, exactly one of `schedule`, `button`, `event`, `manual` | required | §7.1 |
| `missed` | `run_once` \| `skip` | `run_once` | schedule only; ignored otherwise |
| `concurrency` | int | 1 | 1–4; max active runs of this automation (AUTO-05) |
| `permissions` | list of strings | `[]` | grammar §3 |
| `outputs` | list of `inbox`, `briefing`, `report`, `target`, `slack` | `[]` | the only gate for `output.*` (§5) |
| `budget` | `{tokens: int, minutes: int}` | `{tokens: 50000, minutes: 5}` | `1000 ≤ tokens ≤ 2000000` (input + output tokens across `llm`/`agent` calls), `1 ≤ minutes ≤ 60`; a `usd` key is a parse error |
| `workbench` | — | — | **not allowed in the file**: the binding is the folder the file lives in (§20 D15) |
| `pause_timeout_hours` | int | 72 | 1–168; a run waiting longer ends `expired` |

`trigger.button` = `{label: string (1–24 chars), confirm: bool = false}`; `button` in a personal recipe shows
on the Automations card only, in a workbench recipe also in the workbench header (§12.4).
`trigger.event` = `{type: <event type §8>, where: {<field>: <string|glob>}}`.
`trigger.manual: true` = Run now only.

### 2.4 Hashes

- `content_hash` — sha256 of the file bytes. Change detection only.
- `approval_hash` — sha256 of the canonical JSON `{"permissions": [sorted, normalised], "outputs": [sorted],
  "scope": "personal"|"workbench:<id>", "script": "<exact js block text>", "trigger": <trigger>,
  "missed": "<policy>", "budget": {"tokens": N, "minutes": M}, "concurrency": N}` (keys in that order, no
  whitespace, no HTML escaping; `trigger` in the `trigger_spec` shape of §9.1 with a `where` map's keys sorted and
  without the button's cosmetic `label` — its `confirm` stays; missed, budget and concurrency are the effective
  values after defaults). "What this code may do, when and how much." Owner confirmations and auto grants bind to
  it (§6.4, §2.5), so a schedule, missed-policy, budget or concurrency edit needs the owner's confirmation again
  (§20.3 D26, amending D5). Edits to `name`, description, a button's `label` and `pause_timeout_hours` do not
  change it.
  Upgrading to D26 re-hashes every recipe once: every recipe confirmed before it shows **Needs your
  confirmation** until the owner confirms it again.

### 2.5 Index and confirmation

`automations rescan` (and the scheduler tick, §7.2) parses every recipe and upserts its index row, storing the
**parsed copy** (`recipe_text`). The executor always runs `recipe_text` from the database, never re-reads the file
at run time, so what was confirmed is exactly what runs.

A recipe is **runnable** iff: parsed without error, `enabled = 1`, and `confirmed_hash = approval_hash`.
`confirmed_hash` is set only by (a) the apply of an owner-approved `save_automation` (§11), (b) a Desktop save
carrying `--confirm-hash` (§10), or (c) `automations confirm <id> --hash <sha>` — (b) and (c) refuse under an AI
agent's environment markers (AGENT-07). A recipe new to the index, or one whose `approval_hash` changed by any
other way (a git pull, a hand edit, another tool — a schedule, missed, budget or concurrency edit included, §20.3 D26), is indexed with its old `confirmed_hash` and therefore not
runnable; the Automations tab and the workbench header show it as **Needs your confirmation** (AUTO-06).
The store call is `db.ConfirmAutomation(id, hash, now)` (refuses any hash but the current `approval_hash`,
`ErrHashMismatch`; a missing row `ErrAutomationNotFound`); an insert never sets `confirmed_hash` or `enabled`.

A deleted file → index row `removed_at` set, not runnable; its run history stays until the owner deletes the
automation (`automations delete <id>`, cascades runs/steps/state/outputs/grants).

## 3. Permission manifest

### 3.1 Grammar

```
permission := capability ":" verb [ "@" scope ]          e.g. jira:read@PAY, gmail:read@work, llm:strong
            | "tool:" tool-name                          e.g. tool:create_target
            | "mcp:" server "/" tool-glob                e.g. mcp:github/list_*
            | "shell:" quoted-exact-command              e.g. shell:"make release"
```

| Capability | Verbs | Scope | Grants |
|---|---|---|---|
| `slack`, `gmail`, `jira`, `calendar`, `confluence` | `read`, `write` | required: account label/email (Slack, Gmail, Calendar), project key (Jira), space key (Confluence); `*` = all | the source's read (resp. write) tools whose call scope it covers (§3.2) |
| `targets`, `tracks`, `ideas`, `digests`, `people`, `transcripts` | `read`, `write` | none (`@` refused) | those local read (write) tools |
| `meetings`, `dayplan` | `read` only (`write` refused) | none (`@` refused) | meeting recaps and notes; the day plan (§6.1, §20.1 D23) |
| `tool` | — | — | one registry tool by exact name, read or write, whatever its family |
| `mcp` | — | `server/tool-glob`, `*` only in the tool part | Quick Connection server by name, tools matching the glob that QC-02 allows (read-only; automations are QC-02's second consumer of the same allowed list, §14.7, §20.1 D20) |
| `shell` | — | exact command, double-quoted, JSON string escapes | workbench automations only (AUTO-13) |
| `llm` | `light`, `strong` | none | `llm()`; `strong` implies `light` |
| `agent` | `run` | none | `agent()` (P6) |
| `ask` | `owner` | none | `ask()` (P5, workbench only, §13.3) |
| `session` | `start` | optional agent kind `claude`\|`codex`; none = both | `session()` (P5, workbench only) |

There is **no `knowledge` capability** (§20.1 D21, ask #273): the broad knowledge tools — `search_knowledge`,
`get_knowledge_document`, `get_task_context`, whose results can carry content of any synced source whatever the
account scopes — are admitted only by an explicit `tool:<name>` entry each; `knowledge:read`/`knowledge:write` is a
parse error whose message names the `tool:` entries to use. By the same rule (ask #277 applies D21), the other
cross-source reads are **`tool:`-only** too: `list_inbox` (items from every source), `memory_recall`,
`memory_open`, `memory_map` (memory derived from every source), and the single-purpose `get_writing_style` —
§6.1, §20.1 D23. Confluence content stays reachable locally only through the `tool:`-only knowledge tools;
`get_confluence_page` (a live read) is not on the `automation` surface.

A manifest entry that does not parse, names an unknown capability/verb, or puts `shell:`/`session:`/`ask:` in a
personal recipe → parse error (not runnable). Duplicates are folded. Normalisation (for `approval_hash` and for
the widening diff): lower-case capability, verb and scope (Jira keys and Confluence spaces upper-case), sorted.

### 3.2 Matching

Every SDK call is checked before its backend is touched (AUTO-01):

- **Registry tools.** `internal/automations/manifest.go` holds `toolCapabilities`, a table from tool name to
  `{capability, verb, scopeArg}` (e.g. `list_jira_issues → jira, read, "project"`; `send_slack_message → slack,
  write, "account"`). A `tool(name, args)` call is admitted when the manifest has `tool:<name>`, or the tool's
  capability+verb with a scope that covers `args[scopeArg]`. A call whose scope argument is absent is covered
  only by `@*`. `list_messages` and `list_upcoming_events` take no account argument and read every connected
  workspace/calendar, so their scope is always absent: in v1 only `slack:read@*` (resp. `calendar:read@*`) or
  `tool:<name>` admits them, never `slack:read@<label>` — no narrower scope in v1 (§20.1 D22, ask #273).
  `list_calendar_events` (ask #277) takes an optional `account`, so it has a real scope: with `account` it needs
  `calendar:read@<that account>`, without it `calendar:read@*`. `list_jira_sprints` is scoped by its `project`
  (or the project of its `board_id`), `list_jira_releases` by its `project`; absent → `jira:read@*`. Scope
  matching is case-insensitive equality or `*` glob (`path.Match` semantics). A Jira project grant covers what the
  tool returns with that project's issues, linked issues of other projects included: Jira reads stay scoped by their
  own `project`/key arguments (owner ruling, ask #287, §20.2). A scope argument spelled in another case (`PROJECT`,
  `Key`, `Account`) is not read as the scope, so such a call needs `@*` (P1). A tool missing
  from `toolCapabilities` is admitted only by `tool:<name>`. The tool must also be visible on the `automation`
  surface (`Tool.VisibleOn("automation")`), whatever the manifest says. `TestToolCapabilities_CoversEveryAutomationTool`
  pins that every tool visible on `automation` has an entry or is deliberately `tool:`-only.
- **llm/agent/ask/session/output** — the capability rows above; `output.<k>` needs `k` in `outputs`.
- **mcp** — server name exact, tool name `path.Match` against the glob, then QC-02's `externalmcp.ResolveTools`
  verdict must allow it (a write tool is refused even if the glob matches) — the same allowed read-only list the
  chat consumes (QC-02 amended, §14.7).
- **shell** — byte-exact string equality with one `shell:` entry after JSON-unquoting. No prefix, glob or
  argument matching.

A refusal throws a JS error `PermissionDenied` (`{name, message, needed: "<permission>"}`) into the script and
writes a step row `status='denied'` with the permission it would have needed (AUTO-11). The script may catch it.

### 3.3 Widening

`manifest.Covers(old, new) []string` returns the entries of `new` not covered by `old` (scope `*` covers every
scope of the same capability+verb; `llm:strong` covers `llm:light`). Any save whose result is non-empty shows the
owner the list ("This change lets the automation also: …") and needs confirmation; a save that only narrows or
keeps permissions still re-confirms silently in the same owner gesture (the hash changed). The same function
feeds the `save_automation` card.

### 3.4 Secrets

No SDK function returns a token, a secret file's content, an OAuth grant, or a config value. Backends hold their
clients in Go (`jiraClientFactory`, `slackSenderFactory`, `externalmcp`); the script sees only results. `shell()`
and `agent()` processes get the environment of §13.2, never the secret files' content.

## 4. Sandbox (goja)

- One fresh `goja.Runtime` per run; never reused. Globals: the SDK of §5, `trigger`, `log(...args)` (a step
  row `kind='log'`, clipped 4 KiB), and the ECMAScript builtins. No `require`, no `console`, no timers
  (`setTimeout`/`setInterval`/`Promise` jobs are not installed; `async`/`await` and `Promise` are refused by a
  pre-parse check that fails the recipe with "the script API is synchronous"). The SDK is synchronous: each call
  blocks the script until its backend returns.
- `trigger` (read-only object): `{kind, run_id, scheduled_for?, catch_up?, button?, events?: [...], dry_run}`.
- **Interrupt.** Each run has a context with deadline `started_at + budget.minutes` of **active** time (time
  paused on the owner or the app, §7.6, is excluded: the deadline is re-armed on resume). On deadline, budget
  exhaustion or cancel the executor calls `vm.Interrupt(reason)` and cancels the context, so a pending
  SDK call (network, CLI process) stops too. The run ends `timed_out`, `budget_exceeded` or `cancelled`.
- **Memory.** goja has no heap limit, so size is capped at every edge: an SDK result serialised to more than
  256 KiB fails the call with `ResultTooLarge` (never silently truncated) — the one exception is `shell()`, whose
  output is truncated with the truncation marked in its result and never fails for size (§13.2, §20.1 D19);
  list-type tool calls get `limit`
  default 50, max 200 (the SDK injects/clamps it); `llm()` input after serialisation ≤ 200 KiB; `state` ≤ 64 KiB
  serialised (`state.set` beyond → `StateTooLarge`); `output.*` body ≤ 64 KiB; `log` 4 KiB per call, 200 calls
  per run. Constants live in `internal/automations/limits.go`.
- **Errors.** An uncaught JS exception ends the run `failed` with message and stack; line numbers are mapped to
  the recipe file (block offset added). SDK errors are JS `Error`s with `name` in {`PermissionDenied`,
  `ResultTooLarge`, `StateTooLarge`, `ValidationError`, `ToolError`, `BudgetExceeded`, `NotAvailable`}.
- **Dry run.** `tool` writes, `output.*`, `state.set` commits, `ask`, `session` and `shell` return
  `{status:"dry_run"}` (outputs and the would-be args are shown in the steps) and touch nothing; `llm`, read
  `tool`s and `mcp` reads run for real; `agent` runs with its write tools removed from the effective set (AUTO-12).
- **Determinism** is not promised (Date, Math.random are live). Hence no replay on restart (§7.7).
- **Hardening (P1 implementation).** No `eval`/`Function`; every function prototype's `.constructor` throws
  `EvalError`; a script that breaks out of its wrapper function is a parse error. Regex calls running ≥ 2 s throw
  `RangeError` ("regular expression took too long"); `repeat`, `padStart`/`padEnd`, `String.raw`, `join`, `fill`,
  `Array(n)` and `Array.from(array-like)` are capped at 16 Mi chars/elements; `JSON.stringify` depth ≤ 1000. Native
  builtins are not preemptible: a script still in one 2 s (`AbandonGrace`) after an interrupt is abandoned — the run
  ends with that reason and the automation is disabled ("runaway script — check and re-enable"); the executor
  claims nothing while two abandoned goroutines are alive. The heap itself stays unbounded (v1 limit). An SDK
  argument converts only up to 256 KiB; the script's return value is JSON-serialised inside the run (functions,
  symbols, BigInt → uncaught `ValidationError`; > 256 KiB → `ResultTooLarge`). An interrupt raised before the outcome
  is read wins over a script that just finished; a backend error after the run's context ended is an interrupt.

## 5. SDK

Every call writes one step row (§9.3) — start, result summary, tokens, duration, error (AUTO-11).

| Call | Phase | Permission | Behaviour |
|---|---|---|---|
| `llm(prompt, {input?, schema?, tier?})` | P1 | `llm:<tier>` (default `light`) | One `digest.Generator.Generate` through the resolved provider (`providers.ResolveModelsFor`). Source tag `automation.llm` (light) or `automation.llm.strong` (strong; added to `allowedStrongSources` with reason "the owner chose tier: strong in the recipe"). `input` is JSON-serialised after the prompt; the 200 KiB bound covers prompt + serialised input + serialised schema together (P1, stricter than §4's "input after serialisation"); a failed call debits only provider-reported usage. With `schema` (JSON Schema object) the reply must parse and validate (`jsonschema-go`); one retry with the validation error, then `ValidationError`. Returns string, or the parsed object with `schema`. Tokens debited (§7.5). |
| `tool(name, args, {wait?})` | P1 reads, P2 writes | §3.2 | Read: `Registry.CallRead(ctx, name, args, binding)`. Write: `Registry.Propose(ctx, name, args, binding)` → `{status:"proposed", id}`, or `{status:"applied", id, result}` when trust/auto applied it inline. With `{wait:true}` a proposed write pauses the run (`waiting_reason='approval'`) until the row is `applied` → `{status:"applied", id, result}`, `rejected` → `{status:"rejected", id}`, or `failed` → `{status:"failed", id, error}`. Dry run: a write never reaches the registry → `{status:"dry_run"}` (AUTO-12). |
| `state.get(key)` / `state.set(key, value)` / `state.all()` | P1 | none | Per-automation JSON object. Reads see the committed state plus this run's own sets; sets are buffered and committed **only** when the run ends `succeeded` (AUTO-04). |
| `output.inbox({title, body, priority?})` | P1 | `outputs: [inbox]` | Buffered; committed with state on success as an `automation_outputs` row `kind='inbox'`. |
| `output.report({title, body})` | P1 | `outputs: [report]` | Same, `kind='report'`; shown on the automation card and in the run. Every `output.*` title is ≤ 200 characters (P1 review decision). |
| `output.briefing({title, body})` | P2 | `outputs: [briefing]` | Same, `kind='briefing'`; the next daily briefing includes outputs created since the previous briefing (§12.6). |
| `output.target({...create_target args})` | P2 | `outputs: [target]` | Sugar for `tool("create_target", args)` — a registry write (manifest needs no `tool:create_target`; `outputs` is the gate). |
| `output.slack({...send_slack_message args})` | P2 | `outputs: [slack]` **and** `slack:write@<account>` covering the call (§20.3 D28) | Sugar for `tool("send_slack_message", args)` — External, a proposal unless auto (§6). `outputs: [slack]` alone sends nothing and admits no auto grant (D28). |
| `ask({kind, title, summary?, questions?, checklist?})` | P5 | `ask:owner` | Workbench automations only (§13.3). Creates an `owner_asks` row; pauses (`waiting_reason='ask'`) until answered; returns the answer JSON. |
| `session({prompt, agent?, title?, wait?})` | P5 | `session:start[@kind]` | Workbench only (§13.1). Returns `{session_id, status, summary}` (`wait:"finish"`, default) or `{session_id}` (`wait:"none"`). |
| `shell(cmd)` | P5 | `shell:"<cmd>"` | Workbench only (§13.2). Returns `{exit_code, stdout, stderr}`. |
| `mcp(server, tool, args)` | P6 | `mcp:<server>/<glob>` | Go-side MCP client call (`internal/externalmcp`, the go-sdk client already used by `ListTools`) on an enabled Quick Connection; only tools QC-02 allows; 30 s bound per call. |
| `agent(instruction, {tools?, budget?, tier?})` | P6 | `agent:run` + `llm:<tier>` | A bounded tool loop (§6.5). `tools` = names; the effective set is `tools ∩ (tools the manifest admits) ∩ (visible on automation)`. `budget` = `{tokens, minutes}` ≤ the run's remainder. Returns `{text, actions: [ids]}`. |

## 6. Writes, trust and auto

### 6.1 Surface and binding

- New constant `tools.AutomationSurface = "automation"` and `tools.AutomationContextType = "automation_run"`.
- `tools.Binding` gains `AutomationRunID int64`. The executor binds every SDK registry call as
  `Binding{Surface: "automation", ContextType: "automation_run", ContextID: <run id>, AutomationRunID: <run id>,
  WorkbenchID: <workbench id or 0>}`. `bindingOf` rebuilds `AutomationRunID` from `context_type='automation_run'`.
  `DirectApply` is never set for automations (a workbench automation does not inherit DEV-06's direct apply).
- Write tools that name the `automation` surface in P2 (each tool's `Surfaces` gains `"automation"`):
  `create_target`, `create_idea`, `create_track`, `remind_me`, `create_jira_issue`, `add_jira_comment`,
  `transition_jira_issue`, `assign_jira_issue`, `update_jira_issue`, `send_slack_message`. Not offered:
  `connect_jira_board`, `dismiss_tracks` (AlwaysAsk), `edit_confluence_page`, `brief_context`, every workbench
  tool. `TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces` is updated to the new surface lists.
- New read tools for automations in P1, registered in `buildToolRegistry` but **not** in `tools.ReadTools()` (so
  dev-mode MCP never mounts them, DEV-01) and with `Surfaces: ["automation"]`: `list_emails` (Gmail + IMAP
  messages of one account, newest first, `since`, `limit`, `unread_only`; scope arg `account`) and `get_email`
  (one message, body clipped 32 KiB). Both read **only the locally synced store** (`gmail_messages`,
  `imap_messages`) — never the live Gmail/IMAP API — for Gmail and IMAP accounts alike, with no per-build or
  per-provider gating (§20 D2). They carry the same Google Limited Use posture as the inbox, memory and briefing,
  which already feed synced mail to the model; the product-wide decision governs all of them
  (`docs/security-audit-2026-07-31.md`).
- **More local-store reads (ask #277, §20.1 D23), all in P1 beside the email tools.** New tools, each `Surfaces:
  ["automation"]`, not in `tools.ReadTools()` (DEV-01), local store only, list `limit` default 50 / max 200, long
  texts clipped with a `truncated` flag:
  `list_inbox` (`inbox_items`, archived rows excluded; `status` pending|snoozed|resolved|dismissed|all, default
  pending; `priority`, `trigger_type`, `since`) — `tool:` only;
  `list_calendar_events` (`calendar_events` with `start_time` in `[from, to)`, past included; optional
  `account`; description clipped 4 KiB) — `calendar:read@<account>|*`;
  `list_meeting_recaps` / `get_meeting_recap` (`meeting_recaps` joined to the event title and start; `get` returns
  the recap JSON and `source_text` clipped 32 KiB each) and `list_meeting_notes` (`meeting_notes` of one event or
  since a time; a note is one short row, so the list returns its whole text and there is no `get`) — `meetings:read`;
  `list_day_plans` / `get_day_plan` (the owner's `day_plans` via `db.ResolveOwner`, OWNER-01; `get` adds its
  `day_plan_items`) — `dayplan:read`;
  `list_reminders` (`reminders`; `status` pending|done|dismissed|all, default pending; `due_before`) —
  `targets:read`, mirroring `remind_me` → `targets:write`;
  `list_jira_sprints` (`jira_sprints` joined to `jira_boards`; `project`, `board_id`, `state`) and
  `list_jira_releases` (`jira_releases`; `project`, `released`, `include_archived`; description clipped 4 KiB) —
  `jira:read@<PROJECT>|*`.
  Existing tools admitted on the `automation` surface: `memory_recall`, `memory_open`, `memory_map` (surface-less,
  so already visible; they live in `tools.DependentReadTools`, not in `buildToolRegistry`, so the automation
  registry `buildAutomationRegistry` adds them with the workspace vault path and no recall-compare shadow handle;
  `memory_open` skips its access-stat bump on the `automation` surface, so automation reads stay writes-free,
  AUTO-02/AUTO-12) — `tool:` only; `get_writing_style` (`Surfaces` gains `automation`) — `tool:` only;
  `list_jira_projects` (surface-less, already `jira:read@*`) — unchanged. `get_confluence_page` is **not** offered
  (a live network read; D23 is local store only) — Confluence content stays reachable through the knowledge tools.

### 6.2 Trust order (`resolveTrust`)

For a binding on the `automation` surface, first match wins:
1. `AlwaysAsk` tool → `ask`.
2. An auto grant row for (automation of the run, tool) with `grant_hash = automations.approval_hash =
   automation_runs.recipe_hash` → `execute` (External included — the AGENT-03 amendment, §14.2).
3. `External` tool → `ask`.
4. `tool_trust(tool, 'automation')` → its value (`ask` when absent). `SetTrust` accepts `automation` like any
   other trust surface; Settings → Assistant tools shows its switch.

Every other surface keeps today's order unchanged. An inline apply goes through `Apply`'s claim (AGENT-05), one
`agent_actions` row with `trust_at_create='execute'`.

### 6.3 Where proposals appear

The Inbox action strip already lists every non-workbench `agent_actions` row (`AgentActionQueries.fetchStrip`).
Rows with `context_type='automation_run'` get a label "⚙ <automation name> · run #<n>" on `AgentActionCardView`
(P3) and a link to the run. Auto-applied rows show in the strip's applied tail as done facts; their step row
carries `status='applied'` and `auto=1`. Approve/Reject stay the existing owner-only path (AGENT-07 unchanged).

### 6.4 Auto grants

- Table `automation_tool_grants` (§9.4). Written only by `watchtower automations auto <id> <tool> on --hash <sha>`
  (refused under AI-agent markers, AGENT-07; refused when `<sha>` ≠ current `approval_hash`; refused for an
  AlwaysAsk tool or a tool the manifest does not admit as a write) and removed by `… off` (open to anyone).
  The Desktop's form is the only UI that runs `on`.
- A grant whose `grant_hash` no longer equals `approval_hash` is **inactive**, kept for display ("Auto paused —
  the recipe changed. Re-confirm?"). Re-confirming writes the new hash; a recipe returned to the exact granted
  text matches the kept hash again, so the grant is active again without a new grant. A save never carries grants over by
  itself: the save sheet lists the grants the edit pauses with unchecked "Keep auto for …" boxes; checking one
  runs `auto … on --hash <new>` after the save (AUTO-03).

### 6.5 `agent()` runtime (P6)

`agent()` runs a bounded tool loop with the run's binding: with an OpenAI-compatible provider, the runtime-B
loop (`agentloop.NewClient(model, baseURL, reg, binding)` restricted to the effective tool set); with the
`claude`/`codex` CLI providers there is no in-process loop, so (§20 D3) the SDK runs a headless `ai query`-style
process with the chat-mode MCP server bound to `--surface automation --automation-run N`, `--allowedTools` = the
effective tool set, and `WATCHTOWER_AUTOMATION_RUN_ID` in its environment. Writes inside the loop go through
`Registry.Propose` with the automation binding (AGENT-01 holds); `wait` is not available inside `agent()`
(proposals stay pending; their ids are returned). Iterations ≤ 12; tokens debited per model call.

## 7. Triggers, scheduler, executor

### 7.1 Triggers

| Trigger | Source | Run row |
|---|---|---|
| `schedule` (cron, 5-field, local time zone, `robfig/cron/v3` standard parser) | scheduler tick | `trigger='schedule'`, `scheduled_for` |
| missed schedule, `missed: run_once` | scheduler tick | `trigger='catch_up'`, `scheduled_for` = the latest missed time |
| `button` | Desktop button → `automations run <id>` | `trigger='button'` |
| `event` | event bus flush (§8) | `trigger='event'`, `event_cycle`, `event_json` |
| Run now (any automation) | `automations run <id>` | `trigger='manual'` |
| Dry run | `automations dry-run <id>` | `trigger='dry_run'` |
| Rerun of a past run | `automations run <id> --rerun-of <run>` | `trigger='manual'`, `rerun_of` |

Every trigger only **inserts a `queued` row** (AUTO-09); nothing executes inline in the scheduler, the bus, the
CLI or the Desktop — with one exception: `dry-run` executes in the CLI process (§10) because it writes nothing
outside its own journal.

Coalescing: at most one `queued` row per (automation, trigger kind). A second trigger of the same kind while one
is queued inserts nothing and returns the queued run's id (`run --json` → `{"run_id": n, "coalesced": true}`).

### 7.2 Scheduler (own goroutine, not a sync phase)

- `daemon.Run` starts `automations.Scheduler.Run(ctx)` and `automations.Executor.Run(ctx)` as goroutines next to
  the sync loop; neither is a phase of `runSync`, and neither waits for a sync cycle.
- The scheduler ticks at every minute boundary and on a wake (`Clock` interface: `Now()`, `After(d)`; tests use a fake clock).
  Each tick: rescan the personal folder and unprotected workbench folders by directory mtime (§13.4), then for
  every runnable `schedule` automation compute due times in `(last_scheduled_for, now]`.
- Grace 2 minutes: a due time within 2 minutes of `now` is **on time** → one `schedule` row. Due times older than
  that are **missed** (Mac asleep/off, daemon down): `run_once` → exactly one `catch_up` row for the latest missed
  time, however many were missed (AUTO-10); `skip` → none. Either way `last_scheduled_for` advances to the latest
  due time in the window in the same transaction as the insert, so a crash cannot double-insert and a restart does
  not re-catch-up.
- First index of a schedule automation sets `last_scheduled_for = now` (no catch-up for times before it existed).
  Enabling a disabled automation does the same (no catch-up for the disabled period). So does a confirm that changes
  `confirmed_hash` (no catch-up for the unconfirmed window; re-confirming the same hash keeps the point), a rescan
  that makes a row runnable again (its `approval_hash` reverted to the confirmed one — since §20.3 D26 a trigger edit
  alone never leaves a row runnable — `db.PrimeAutomationSchedule` writes only while the row is not a runnable schedule) and enabling the `automations`
  feature (FEAT-03 hook `db.FastForwardAutomations`, which also cancels runs queued while it was off, dry runs kept).
- **Compare-and-set (P1).** The schedule advance is conditional on the `last_scheduled_for` the scheduler read
  (`EnqueueRequest.ExpectLastScheduledFor`, required with `AdvanceScheduleTo`; `db.CompareAndSetAutomationSchedule`);
  a row changed meanwhile rolls the transaction back (`db.ErrScheduleChanged`) and is skipped for that tick.
- **Time zone, DST and clock steps (P1).** The local zone is re-read every tick (`/etc/localtime` link, else
  `time.Local`), so a zone change applies without a restart. An hour field without `*` is a wall-clock appointment:
  a time repeated by a fall-back fires once (first occurrence), a time in the skipped spring-forward hour fires once at
  the jump (02:30 → 03:00); an hour field with `*` follows elapsed time (both passes of a repeated hour; the skipped
  hour has no due times). Deliberate deviations from Vixie cron: only the hour field decides (`* 2 * * *` is
  wall-clock), and DST comes from the zone database, not from the size of a clock jump. A clock stepped back waits
  until it passes `last_scheduled_for` again (no duplicate); a `last_scheduled_for` more than a day ahead of now
  restarts the schedule from now (no catch-up). v1 limits: a clock set forward by less than a day holds the schedule
  until real time catches up (that slot is lost); one stepped back by more than a day may repeat a due time.

### 7.3 Executor

- One executor goroutine claims rows: `UPDATE automation_runs SET status='running', started_at=… WHERE id=? AND
  status='queued' AND (SELECT COUNT(*) FROM automation_runs WHERE automation_id=? AND status IN
  ('running','waiting')) < <concurrency>` in one `BEGIN IMMEDIATE` transaction (AUTO-05). Oldest `queued_at`
  first; a queued row of a non-runnable automation ends `cancelled` with `error_kind='not_runnable'`.
- `maxConcurrentRuns = 2` runs in `running` at once across all automations (code constant). `waiting` runs do not
  count (they hold no CPU; each is bounded by `pause_timeout_hours`).
- Wakeups: a 10 s poll of `queued` and `waiting` rows, plus the wake signal (§7.4).
- **P1 implementation.** The daemon's claim checks the global running bound in the same statement
  (`ClaimAutomationRunWithin`); a ready wait resumes only into a free running slot (`ResumeAutomationRunIfSlot`) and
  before queued runs are claimed; a finished run wakes the executor. The daemon never picks up a `dry_run` row
  (`NextQueuedAutomationRuns` excludes them): the CLI claims and runs its own. At start the executor spares a live CLI
  dry run (its `started_at` + budget minutes + 1 min still ahead) and on every poll sweeps dry runs past that deadline
  (`MarkStaleDryRuns`). The run re-parses the claimed snapshot with the scope rebuilt from the index row (`scope` +
  `project_id`). Ending a run closes its still-open steps in the same transaction.
- The executor lives in the daemon; the daemon's flock-holding process is the only executor (the CLI's `run`
  only queues).

### 7.4 Wake signal

`daemon.AutomationWakeSignal = syscall.SIGUSR2` with its own watcher (`WatchAutomationWake`), feeding the
scheduler/executor only. `automations run`, the Desktop after an approval/ask answer on an automation row, and
the Desktop after launching a requested session send it. **Not** the existing `SIGUSR1` trigger channel: that
one starts a full sync cycle (`TriggerSignal`, `cmd/sync.go`), which would make every Run now cost a sync (§20
D1). With no daemon running, `run` still queues and prints `daemon not running; the run starts when it does`
(exit 0); the Desktop respawns the daemon anyway. The daemon advertises the signal in `<pidfile>.caps` (its pid, then
`automations-wake`, written right after the PID file and removed with it); the CLI signals only a daemon that lists it —
the caps file tells the CLI whether this daemon actually runs the automations wake. An older daemon, or one with
automations off, silently ignores SIGUSR2 (a Go process catches it and does nothing), so the run would just wait for its
next poll; such a daemon is not signalled, and `run`/`wake` print a restart hint (exit 0). `automations wake` ships in P1.

### 7.5 Budgets

Budgets are in **tokens**, not dollars (§20 D4, ask #270).
- Per run: `budget.tokens` and `budget.minutes` from the recipe (snapshotted on the run row). Every `llm`/`agent`
  model call debits its `input_tokens + output_tokens` (`digest.Usage.InputTokens + OutputTokens`, the same
  numbers `pipeline_runs` records); before each such call the executor checks the remainder and refuses the call
  with `BudgetExceeded` when it is ≤ 0; after a call that crosses it the run is interrupted. End status
  `budget_exceeded`. A call whose provider reports no usage debits an estimate of `ceil(len(prompt+input+reply)
  / 4)` tokens, so a provider without usage numbers cannot run unbounded.
- Display only: when the provider reports a dollar cost (claude's `total_cost_usd`), it is stored in
  `reported_cost_usd`; nothing compares against it, and it is never estimated.
- No global daily cap (§20.3 D25, ask #294): each run is bounded only by its own `budget.tokens` and
  `budget.minutes`. The former `automations.daily_budget_tokens` key is gone (a leftover key in `config.yaml` is
  ignored); `error_kind='daily_cap'` stays in the CHECK (no migration) but nothing produces it.

### 7.6 Waiting

A run pauses — `status='waiting'`, `waiting_reason` ∈ `approval` (tool wait), `ask`, `session`, `app` (session
requested while the Desktop is not running) — by blocking its goroutine in the SDK call on a condition the
executor's poll re-checks (agent_actions status, owner_asks status, terminal_sessions state). The active-time
deadline is suspended while waiting. A run waiting longer than `pause_timeout_hours` ends `expired`; Cancel ends
it `cancelled` (a pending proposal it made stays pending in the Inbox; a requested session is left as is).

### 7.7 Restart

A daemon exit interrupts every `running`/`waiting` run (goja state is not serialisable): on start the executor
marks them `failed` with `error_kind='interrupted'`. State and outputs were not committed (AUTO-04), so a rerun is
safe for Watchtower's own data; proposals and applied writes made before the interruption stay, listed in the
journal. No replay-based resume in v1 (§20 D6).

### 7.8 Statuses

`queued → running → (waiting ↔ running)* → succeeded | failed | budget_exceeded | timed_out | cancelled |
expired`. Terminal statuses are final; every run reaches one (AUTO-08). `succeeded` commits state + outputs in
one transaction with the status change.

## 8. Events (P4)

- In-process bus `automations.Bus` owned by the daemon. Sync phases publish typed events with ids and counts
  only — never content:
  - `slack.new_messages{account, channel, count}` (`phaseSlackSync`)
  - `gmail.new_messages{account, count}` (`phaseGmailSync`; IMAP accounts too, `phaseImapSync`)
  - `jira.issue_changed{account, key, project, field}` (`phaseJiraSync`; field ∈ status, assignee, priority,
    comment, other)
  - `calendar.event_changed{account, event_id, change}` (`phaseCalendarSync`/`phaseCalDAVSync`; change ∈
    created, updated, cancelled)
  - `confluence.page_changed{space, page_id}` (`phaseExternalSync`)
- `runSync` calls `bus.Flush(cycleID)` once after the source syncs (`cycleID` = `syncStart` in RFC 3339 UTC). For
  each runnable `event` automation whose `type` and `where` match at least one event of the cycle, Flush inserts
  **one** `queued` row with `event_cycle = cycleID` and `event_json` = the matching events (at most 100, plus
  `truncated: true`). A unique index on `(automation_id, event_cycle)` makes it at most one event run per
  automation per cycle even if Flush were called twice.
- `where` matches event fields with case-insensitive equality or `*` glob. Matching is not a permission: the
  script still needs the manifest to read anything about the event's subject.
- Reaction commands are not migrated onto the bus.

## 9. Data model

All migrations follow the house rules: `schema.sql` mirror, `TestAllTablesExist`, golden + Swift test schema
regenerated (`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`). Numbers start at
00113 (`origin/main` ends at 00112 on 2026-10-14); if `main` claims them first, renumber before the branch merges
and check by table presence, not goose version.

### 9.1 00113_automations.sql (P1) — `automations`

| Column | Type | Notes |
|---|---|---|
| `id` | INTEGER PK AUTOINCREMENT | |
| `slug` | TEXT NOT NULL | filename stem |
| `scope` | TEXT NOT NULL CHECK IN ('personal','workbench') | |
| `project_id` | INTEGER NULL REFERENCES projects(id) ON DELETE CASCADE | workbench id; NULL for personal; CHECK `(scope='workbench') = (project_id IS NOT NULL)` |
| `path` | TEXT NOT NULL UNIQUE | absolute recipe path |
| `name` | TEXT NOT NULL DEFAULT '' | |
| `trigger_kind` | TEXT NOT NULL DEFAULT '' CHECK IN ('','schedule','button','event','manual') | '' while unparsable |
| `trigger_spec` | TEXT NOT NULL DEFAULT '{}' | JSON of `trigger` |
| `missed_policy` | TEXT NOT NULL DEFAULT 'run_once' CHECK IN ('run_once','skip') | |
| `concurrency` | INTEGER NOT NULL DEFAULT 1 CHECK BETWEEN 1 AND 4 | |
| `budget_tokens` | INTEGER NOT NULL DEFAULT 50000 | |
| `budget_minutes` | INTEGER NOT NULL DEFAULT 5 | |
| `pause_timeout_hours` | INTEGER NOT NULL DEFAULT 72 | |
| `permissions_json` | TEXT NOT NULL DEFAULT '[]' | normalised |
| `outputs_json` | TEXT NOT NULL DEFAULT '[]' | |
| `recipe_text` | TEXT NOT NULL DEFAULT '' | the indexed copy the executor runs |
| `content_hash` | TEXT NOT NULL DEFAULT '' | |
| `approval_hash` | TEXT NOT NULL DEFAULT '' | |
| `confirmed_hash` | TEXT NOT NULL DEFAULT '' | '' = never confirmed |
| `parse_error` | TEXT NOT NULL DEFAULT '' | |
| `enabled` | INTEGER NOT NULL DEFAULT 0 | |
| `last_scheduled_for` | TEXT NULL | RFC 3339 UTC |
| `next_run_at` | TEXT NULL | for the list; derived by the scheduler |
| `removed_at` | TEXT NULL | file gone |
| `created_at`, `updated_at` | TEXT | house default |

Unique index `(scope, COALESCE(project_id, 0), slug)`.

### 9.2 `automation_runs` (00113)

`id` PK; `automation_id` FK CASCADE; `trigger` CHECK IN ('schedule','catch_up','button','event','manual','dry_run');
`scheduled_for` TEXT NULL; `event_cycle` TEXT NULL; `event_json` TEXT NOT NULL DEFAULT ''; `rerun_of` INTEGER NULL
REFERENCES automation_runs(id) ON DELETE SET NULL; `status` CHECK IN ('queued','running','waiting','succeeded',
'failed','budget_exceeded','timed_out','cancelled','expired'); `waiting_reason` CHECK IN ('','approval','ask',
'session','app'); `recipe_hash` (approval_hash at claim); `recipe_snapshot` (recipe_text at claim);
`budget_tokens`, `budget_minutes` (snapshotted); `input_tokens`, `output_tokens` INTEGER DEFAULT 0;
`tokens_estimated` INTEGER DEFAULT 0 (1 when any call's usage was estimated); `reported_cost_usd` REAL NULL
(display only, sum of provider-reported costs; NULL when none reported); `active_ms` INTEGER DEFAULT 0; `error` TEXT DEFAULT '';
`error_kind` CHECK IN ('','script','permission','budget','daily_cap','timeout','interrupted','not_runnable',
'expired','cancelled','backend'); `summary` TEXT DEFAULT '' (last `output.report` title or the script's return
value — a string as is, any other value as JSON, `''` for none — clipped 1 KiB); `queued_at`, `started_at` NULL, `finished_at` NULL.
Indexes: `(automation_id, status)`, `(status, queued_at)`, unique `(automation_id, event_cycle) WHERE event_cycle
IS NOT NULL`, partial unique `(automation_id, trigger) WHERE status='queued'` (coalescing, §7.1).

### 9.3 `automation_run_steps` (00113)

`id` PK; `run_id` FK CASCADE; `seq` INTEGER (UNIQUE with run_id); `kind` CHECK IN ('llm','tool','mcp','agent',
'ask','state','output','session','shell','log'); `name` TEXT (tool/output/server name); `args_json` TEXT (clipped
4 KiB, secrets never present by §3.4); `result_summary` TEXT (clipped 4 KiB); `status` CHECK IN ('ok','error',
'denied','proposed','applied','rejected','failed','waiting','dry_run'); `auto` INTEGER DEFAULT 0;
`permission` TEXT DEFAULT '' (the entry that admitted it, or the one it lacked); `action_id` INTEGER NULL
(agent_actions id, no FK); `ask_id`, `session_id` INTEGER NULL (no FK, P5); `input_tokens`, `output_tokens`
INTEGER DEFAULT 0; `tokens_estimated` INTEGER DEFAULT 0; `reported_cost_usd` REAL NULL (display only); `duration_ms`; `error` TEXT DEFAULT ''; `started_at`, `finished_at`.

### 9.4 `automation_state`, `automation_outputs` (00113); `automation_tool_grants` (00116, P2)

- `automation_state(automation_id PK FK CASCADE, state_json TEXT NOT NULL DEFAULT '{}', run_id INTEGER NULL,
  updated_at)`.
- `automation_outputs(id PK, automation_id FK CASCADE, run_id FK CASCADE, kind CHECK IN ('inbox','briefing',
  'report'), title TEXT NOT NULL, body TEXT NOT NULL, priority CHECK IN ('high','medium','low') DEFAULT 'medium',
  created_at, read_at NULL, dismissed_at NULL)`.
- `automation_tool_grants(automation_id FK CASCADE, tool TEXT, grant_hash TEXT NOT NULL, granted_at,
  PRIMARY KEY (automation_id, tool))`.

### 9.5 00117_automation_workbench.sql (P5)

`ALTER TABLE owner_asks ADD COLUMN automation_run_id INTEGER REFERENCES automation_runs(id) ON DELETE SET NULL`;
`ALTER TABLE terminal_sessions ADD COLUMN automation_run_id INTEGER REFERENCES automation_runs(id) ON DELETE SET
NULL`. Session requests are step rows (`kind='session'`, `status='waiting'`), not a table (§13.1). `ask()` is
workbench-only in v1 (§20 D7), so `owner_asks.project_id` stays NOT NULL.

### 9.6 Dual paths

Swift reads all automation tables through GRDB (`AutomationQueries`, WatchtowerCore). Swift writes only
`automation_outputs.read_at`/`dismissed_at` (the strip's Done/Dismiss, like reminders); every other write is Go,
through the CLI. The approval-hash function exists only in Go; the Desktop gets hashes from `automations show
--json`.

## 10. CLI (`cmd/automations*.go`)

| Command | Notes |
|---|---|
| `automations list [--json] [--workbench N]` | index rows + next run, last status, 7-day tokens |
| `automations show <id\|slug> [--json]` | row, parsed recipe, hashes, grants (active/inactive, P2), widening vs confirmed (P1 v1 limit: `[]` when confirmed, else every normalised permission — the index keeps only `confirmed_hash`); a slug is resolved before an id |
| `automations validate <file> [--json]` | parse + manifest + script pre-parse, no DB write |
| `automations rescan [--workbench N] [--json]` | index personal folder (+ one workbench); Desktop runs it for protected folders |
| `automations run <id> [--rerun-of R] [--json]` | queue + SIGUSR2; Run now and buttons |
| `automations dry-run <id\|--file F> [--json]` | executes in the CLI process, `trigger='dry_run'`; writes `{status:"dry_run"}`; no state/outputs; real `llm` tokens counted; an **unconfirmed** recipe is refused under AGENT-07 markers (owner only, §20.1 D16); the CLI pins the hash its check saw (`ExecuteInlinePinned`) — a recipe changed before the claim cancels the run |
| `automations cancel <run-id>` | |
| `automations runs <id> [--limit N] [--json]`, `automations steps <run-id> [--json]` | history |
| `automations enable <id>` | owner only (AGENT-07 markers refused before anything is read, §20.3 D24, ask #293) |
| `automations disable <id>` | open under agent markers (it only reduces activity) |
| `automations confirm <id> --hash <sha>` | owner only (AGENT-07 markers refused) |
| `automations auto <id> <tool> on --hash <sha>` / `off` | `on` owner only (AGENT-07) |
| `automations save --file F [--path P] [--confirm-hash <sha>]` | writes the recipe atomically (temp + rename), indexes it; with `--confirm-hash` (owner only) confirms in the same step |
| `automations delete <id>` | owner only (AGENT-07 markers refused before anything is read, §20.3 D24, ask #293); removes the index row (cascade) in one statement refused while a run is `running`/`waiting` ("cancel it first"), then the file when it is a regular file in its recipe folder |
| `automations wake` | sends the wake signal (P1); open under agent markers |
| `automations templates [--json]`, `automations install-template <name> [--workbench N]` | P6 |
| `automations outputs [--kind K] [--json]` | P1, until the Inbox renders them (P3) |

AGENT-07's marker list gains `WATCHTOWER_AUTOMATION_RUN_ID` (set on every `shell()`/`agent()`/`session()` child,
§13.2), so a command run by an automation can no more approve than an agent can.

Owner-only under AGENT-07 markers: `confirm`, `save --confirm-hash`, `dry-run` of an unconfirmed recipe, `auto … on`
(P2), `enable` and `delete` (§20.3 D24). Open: `disable`, `cancel`, `run` (of a confirmed, enabled recipe),
`rescan`, a plain `save`, the read verbs and `wake` — they only reduce activity or run what the owner already
confirmed. Removing a recipe file by hand is outside the CLI and not guarded (the next rescan marks the row
`removed_at`, §2.5).

## 11. Authoring (P3)

- Shipped skill `create-automation` (`internal/skills/shipped/create-automation.md`): how to interview the owner,
  the recipe format, the grammar, the five templates as examples, "always draft and dry-run before save".
- `draft_automation` — **read** tool, surfaces `main` and `automation_editor` (§14.5). Args `{recipe_text,
  workbench_id?}`. Validates; computes the widening against the saved version (when editing); dry-runs in memory
  bounded by `min(budget.tokens, 50000 tokens)` and `min(budget.minutes, 5)` with writes as `{status:"dry_run"}`.
  Writes **nothing** to the database (AGENT-06: its dry-run journal is returned in the result, not persisted). Result: `{ok, errors[], manifest, widening[],
  dry_run: {steps[], outputs[], tokens}}`. The dry-run journal goes back to the chat model as is: a draft that
  reads `list_emails`/`get_email` shows that model the clipped mail of those steps (owner-approved, §20.1 D18).
  `draft_automation` dry-runs a **draft** — text the chat is authoring — never an unconfirmed recipe: when the
  draft's `approval_hash` equals the `approval_hash` of an indexed, not removed automation that is not confirmed
  (`confirmed_hash ≠ approval_hash`), it validates but does not dry-run (`dry_run.status = "refused"`, no model
  call, "This recipe is not confirmed yet; only you can dry-run it, from its card in Automations") — §20.1 D16.
- `save_automation` — **write** tool, `AlwaysAsk: true` (never execute trust, never auto), surfaces `main` and
  `automation_editor`. Args `{recipe_text, slug, workbench_id?, reason}`. `Normalize` re-validates and pins
  `approval_hash` and the widening list into the stored args; the card shows trigger, permissions (widening
  highlighted), outputs, budget, the last dry-run summary, and for an edit the diff against the saved file.
  `Execute` (after the owner's Approve, AGENT-07) runs the equivalent of `automations save --confirm-hash
  <pinned hash>` — writes the file, indexes, confirms. `Execute` refuses if the file changed since propose
  (content_hash pinned too). Grants are not carried over (§6.4).
- Editing in the Desktop: the form (trigger, permissions, budget, concurrency, missed, enabled, auto grants) and
  the Monaco script editor save through `automations save --confirm-hash` after the widening sheet; "change it
  in words" is an `EmbeddedChatEngine` chat bound to the automation (`ChatSurfaceSpec` with
  `.actions(surface: "automation_editor")`, tools `draft_automation`, `save_automation` and the read tools only),
  whose `save_automation` card shows the diff.

## 12. Desktop

### 12.1 Automations tab (P3)

`AutomationsViewModel` (owned by `AppState`, survives navigation) over `AutomationQueries` (WatchtowerCore,
ValueObservation on `automations`/`automation_runs`). List rows: name, trigger text ("Weekdays 09:00", "Button:
Release", "On new Gmail (work)"), next run, last status (badge colours: succeeded green, running/waiting blue,
failed/timed_out/expired red, budget_exceeded orange, cancelled grey), tokens this week; badges for **Needs your
confirmation**, **Auto paused**, **Disabled**, **Parse error**. Sidebar badge = automations needing
confirmation + runs waiting on the owner.

Approved layout (mockup 1): the header carries **Templates**, **+ New** and a "Search automations" field (name
filter); the list sits left of the card. A row is two lines — the name with its status pill or badge on the right
("● Succeeded", "● Failed", "● Running", "Needs your confirmation", "Disabled"), then one detail line joined with
" · ": the trigger text, then the most useful fact for the state — "next in 14 h" (+ "3.2k tokens this week") for a
healthy row, "last run: <error>" for a failed one, "started 40 s ago" for a running one, "schedule changed, waiting
for you" for one that needs confirmation, "coming in a later version" for an event trigger before P4.

### 12.2 Automation card

Description, recipe (read-only, Monaco), permissions with widening vs confirmed, outputs (latest reports),
history (runs, each expands into its steps: kind, name, status, tokens, duration, error; proposals link to their
Inbox card, sessions to the session, asks to the ask), buttons **Run now**, **Dry run**, **Enable/Disable**,
**Edit**, **Change in words**, **Delete**. Dry run renders the would-be writes and outputs as a list ("would
propose create_jira_issue {…}").

Approved layout (mockup 1): title, then a subtitle "<schedule in words> · <personal | workbench name> ·
<enabled | disabled>" ("Every weekday at 09:00 · personal · enabled"); the button row **Run now** (primary),
**Dry run**, **Change in words**, **Edit**, **⋯** — **Enable/Disable** and **Delete** live inside **⋯**. Below: the
description in plain words; **It may** — each permission and output as a human line ("Read mail in work (Gmail)",
"Use the light model", "Put cards in your Inbox"); **Limits per run** — "40,000 tokens · 5 minutes", "One run at a
time", "Missed while asleep: run once"; **History** — one row per run ("Succeeded · Today 09:00 · 41 s", tokens on
the right), the newest expanded into its steps as "✓ list_emails — 23 messages", "✓ llm (light) — 1,180 tokens",
"✓ inbox card — "Mail: 4 need a reply"", the others collapsed and expandable. The recipe in Monaco is reached from
**Edit** (and "Show the script" in the confirm sheet), not shown inline.

**Confirmation sheet** (mockup 3; AUTO-06, §2.5, D26): title "Confirm “<name>”?", the line "The recipe changed
since you last confirmed it. It won't run again until you confirm. Changes are marked." A **Changed** block lists
each hashed field that differs from the confirmed version as "<field> <old> → <new>" — schedule (in words),
missed policy, budget per run (tokens, minutes), concurrency, outputs — and the script ("Script changed"), followed by who changed it and
when. **It may** lists the permissions with widening entries marked, or "No change to what it can access.";
"Show the script (N lines)" discloses the script read-only. Buttons **Dry run first**, **Not now**, **Confirm**
(primary). Go computes the block (`show --json` keys `changes`, `changes_known`, `changed_by`, `changed_at`, added
in P3): the index holds only `confirmed_hash`, so the confirmed text is the newest `automation_runs.recipe_snapshot`
whose `recipe_hash` equals `confirmed_hash`, else the `previous_recipe_text` pinned in the last applied
`save_automation` for that automation, and a candidate counts only if its `approval_hash` computed now equals
`confirmed_hash`. So: confirmed → no changes, known; never confirmed → "First confirmation"; a counting candidate →
its field diff, known; no counting candidate — including after a hash-format change such as D26's re-hash, where
the snapshot text may equal the current text yet its hash no longer matches — → `changes_known` false and the
block reads "What changed is not known — review the whole recipe". The author line is "Changed by the
assistant in the chat · <age>" when an applied `save_automation` pinned the recipe's current `approval_hash`,
otherwise "Changed outside Watchtower · <age of updated_at>" — v1 limit: a plain `automations save`
or a hand edit records no author, so the mockup's "Changed by Claude in the workbench terminal" needs an author
record (owner-accepted limit, 2026-10-15; a later phase; a `confirmed_text` column would also remove the snapshot fallback).

**Create in words** (mockup 2): a "New automation" sheet with three tabs, **Describe in words** (default),
**Form**, **Template**. Left: the chat (the owner's request, the assistant's replies, follow-ups such as "Skip
newsletters.", a composer with **Send**). Right: a live **Draft** panel re-rendered after every `draft_automation`
result — name, "Show recipe", **When** ("Weekdays at 09:00", "Your local time · if the Mac was asleep, runs once
when it wakes"), **Each run may spend** ("40,000 tokens · 5 min", "Last dry run used 1,050 tokens"), **It asks to**
(each permission with its manifest string and a plain explanation), what it can't do ("It can't send mail, post to
Slack or change Jira."), and a **Dry run · nothing was written** block of `DryRunPresentation` lines. The footer
reads "Saving asks for your confirmation. It won't run until you confirm." with **Cancel**, **Dry run again**,
**Save…** (→ the `save_automation` card, §11).

**Edit form** (mockup 4): title "Edit “<name>”" with the recipe path; **Name**; **Runs** as choice buttons — "On a
schedule", "When I press a button", "Only when I run it", "On new mail / message (soon)" (disabled until P4); for a
schedule a human picker (every weekday / day / week on… / hour / custom (cron), plus "at" time) with a live line
"Next: tomorrow 09:00 · cron 0 9 * * 1-5" and the checkbox "If the Mac was asleep at that time, run once when it
wakes" (`missed`); **Each run may spend** (tokens, minutes); **It may** as removable chips with **+ Add**;
**Script** in Monaco with the link "Change it in words instead". Footer note "Changing the schedule, budget,
permissions or script needs your confirmation again." and **Cancel**, **Dry run**, **Save and confirm**.

### 12.3 Template gallery

Five cards (§15) with "Install" → `automations install-template` → opens the form with the copy unconfirmed;
Save confirms.

### 12.4 Workbench header buttons (P5)

`WorkbenchHeaderControls` shows one button per runnable workbench automation with `trigger.button`, in slug
order, max 4 visible + overflow menu. Click → confirmation dialog when `confirm: true` → `automations run <id>
--json`. While a run of it is active the button shows a spinner and opens the run on click. A not-runnable
recipe shows the button disabled with "Needs your confirmation" (click opens the confirm sheet).

### 12.5 Inbox (P3)

`AgentActionCardView` labels automation rows (§6.3). `automation_outputs` with `kind='inbox'` render on the
strip as output cards (title, body, automation, run; Done/Dismiss write `read_at`/`dismissed_at`) — a third
source of the strip, which needs the STRIP-01 amendment (§14.4).

### 12.6 Briefing (P2)

`internal/briefing` adds a section "From your automations" with `automation_outputs.kind='briefing'` created
since the previous briefing's `created_at` (titles + bodies, bounded to 4 KiB total, oldest dropped first with a
"+N more" line).

### 12.7 Quick run (P3, ask #295, §20.3 D27)

Two ways to run a recipe without opening its card, both calling `automations run <id> --json` exactly like the
card's **Run now** and both honouring the feature-off refusal (with `automations` off the entry points are hidden;
a refusal that still arrives is shown as the CLI's message, nothing is retried).

- **Who is listed.** Every indexed, not removed recipe, personal and workbench. Manual and button recipes are the
  subject; a scheduled or event recipe is listed after them in its group as "(run now)". A row is runnable exactly
  when the recipe is runnable (§2.5: parsed, not removed, confirmed and enabled) — the same rule as the card's Run
  now, which the CLI enforces (`notRunnableReason`) and which shows a disabled recipe's Run now disabled. Not runnable rows are listed dimmed with their reason: "needs your confirmation first",
  "disabled", "can't be read" (parse error).
- **Run Automation… — ⌃⌘R** (mockup 6, drawn there as ⌘K). Owner ruling 2026-10-15: one key combination does
  the same thing everywhere, so quick run does **not** reuse ⌘K (the Workbench tab's "Go to…" palette and the Chat
  tab's "Search Chats" keep it) and adds nothing to the Go to… palette. "Run Automation…" is an app-menu item with
  its own key equivalent **⌃⌘R** (R for run; unused anywhere in the app — no `.keyboardShortcut`, key monitor or
  Monaco binding — and not a standard macOS shortcut), so it opens the same standalone palette from every tab and
  window. The palette has a "Search commands" field; the **Run automation** section
  ranks rows by fuzzy name match (exact > prefix > word start > substring > subsequence). A row shows the name,
  the scope ("watchtower workbench" / "personal"), a hint ("asks before it runs" for `confirm: true`, "only when you
  run it" for manual) and the last run ("last run 2 days ago, succeeded"); the selected runnable row shows "↩ run".
  An **Other** section offers "Open Automations". ↩ on a runnable row runs it; a `confirm: true` recipe first shows
  a short sheet "Run “<name>”?" with the description's first paragraph and "You'll get a notice when it ends.",
  **Cancel** / **Run**. ↩ on a dimmed row runs nothing: unconfirmed → the confirmation sheet (§12.2); disabled or
  parse error → its card.
- **Menu-bar tray → Run automation ▸** (mockup 7). A submenu grouped by workbench name, then **Personal**; each
  item is the name ("…" appended when it asks before running, "(run now)" for a scheduled recipe) with its last
  status: "✓ 2 d ago" (last succeeded), "✗ 2 d ago" (last failed), "● running" (a click opens the run),
  "— needs confirmation" (a click opens the confirmation sheet in the main window), "— disabled" / "— can't be
  read" (not clickable). The submenu ends with "Open Automations…". A `confirm: true` recipe asks "Run “<name>”?"
  in a small alert first (the tray has no window).
- **Finish notice.** A run started from either place is watched until it ends; then a macOS notification "<name>
  finished" (succeeded) or "<name> failed" / "<name> stopped: <status in words>" with the run's `summary` (or
  `error`) as its body; a click opens the run on its card. A coalesced run (`"coalesced": true`) is watched the same
  way. Runs started elsewhere (schedule, card, buttons) post no notice.

## 13. Workbench automations (P5)

### 13.1 `session()` — a visible session

1. The SDK writes a step `kind='session'`, `status='waiting'`, `args_json={prompt, agent, title}`; the run goes
   `waiting` with `waiting_reason='app'`.
2. The Desktop (`AutomationSessionCenter`, AppState) observes waiting session steps of its workbenches. When the
   app runs, it creates a normal `terminal_sessions` row in the workbench (`kind` = `agent` or the workbench's
   `default_agent`, `title` = `⚙ <title or automation name> · run #N`, `automation_run_id` set), launches it like
   **New Session**, submits `prompt` as the first owner message (the existing launch + first-message path), writes
   the session id into the step, and sends SIGUSR2. `waiting_reason` becomes `session`.
3. The run resumes when the session reaches Finished (`finished_at` set by `finish_session` — returns
   `{status:"finished", summary: finish_summary}`), Error (`agent_failed_at`), Stopped (process gone while not
   finished) or deleted (row gone → `{status:"deleted"}`); `wait:"none"` resumes right after step 2.
4. The session is an ordinary session: visible in SESSIONS, answers its own asks, PROJ-11 states apply.

### 13.2 `shell(cmd)`

Runs `/bin/sh -c <cmd>` with `cwd` = the workbench folder, its own process group (killed with the group on
interrupt and in tests' cleanup), timeout = remaining active budget, stdout/stderr each capped at 256 KiB (tail
kept, `truncated: true`). Output over the limit is **truncated, never a failure** (§20.1 D19, ask #272): when the
two tails together would still serialise over §4's 256 KiB result limit, both are cut further (keeping tails,
each stream at most half of the limit, a shorter stream's unused share going to the other) until the result fits;
the result says so (`truncated: true`) and the step row records the exit code and which stream was cut. `shell()` never throws `ResultTooLarge`. Environment: `PATH`, `HOME`, `LANG`, `USER` from the daemon plus
`WATCHTOWER_AUTOMATION_RUN_ID=<run>`; nothing else (no tokens, no `WATCHTOWER_TERMINAL_SESSION_ID`). Only exact
manifest commands (AUTO-13). In a privacy-protected folder (`privacyProtected`, see §13.4) `shell()` is refused with `NotAvailable`
("this workbench is in a protected folder; use session() or move the folder") — §20 D9; the folder is never
touched.

### 13.3 `ask()`

Creates an `owner_asks` row in the bound workbench: `kind` from the call, `session_id` NULL, `automation_run_id`
set, `origin='agent'`, level by the existing Go classification. It appears in the workbench's Waiting-for-you
stack like any ask, labelled with the automation. The run waits `ask`; on `answered` the executor moves it to
`delivered` (the `get_ask` rule) and returns the answer. Withdrawn by Cancel/expiry (`withdrawn_reason='agent'`).

### 13.4 Repo recipes and protected folders

The daemon's scheduler rescans unprotected workbench folders by mtime of `.watchtower/automations/`; it never
reads a folder `privacyProtected` lists (the knowledge phase's rule). For those, the Desktop runs `automations
rescan --workbench N` when the workbench page opens and when its file watcher sees a change under
`.watchtower/automations/`. Because the executor runs the indexed copy (§2.5), a protected-folder recipe runs on
schedule without the daemon touching the folder — except `shell()`, refused there (§20 D9).

## 14. Contracts

### 14.1 New inventory `docs/inventory/automations.md` (created in P1; module row added to the README table)

| Id | Title | Observable (short) | Phase |
|---|---|---|---|
| AUTO-01 | The manifest is the only source of permissions | Every SDK call is checked against the recipe's `permissions`/`outputs` before its backend runs; a miss throws `PermissionDenied`, writes a `denied` step and touches nothing. No trust row, grant, surface or argument widens it. | P1 |
| AUTO-02 | Writes only through the registry | The only SDK paths that change data outside the automation's own tables are `Registry.Propose` (and `Apply` it triggers) on the `automation` surface, `shell()` and `session()`; `output.inbox/briefing/report` write only `automation_outputs`. | P1 (pinned), P2 |
| AUTO-03 | Auto only by the owner, bound to the hash | An auto grant is written only by `automations auto … on` outside AI-agent markers with the current `approval_hash`; it applies only while that hash equals the run's; any script/permission change deactivates it until the owner grants the new hash or the recipe returns to the exact granted text (the grant compares hashes only); every auto write is one `agent_actions` row through `Apply`'s claim plus an `auto=1` step. AlwaysAsk tools are never auto. | P2 |
| AUTO-04 | State commits only on success | `state.set` and `output.*` (local) are buffered and committed in one transaction with `status='succeeded'`; any other terminal status leaves `automation_state` and `automation_outputs` byte-identical. | P1 |
| AUTO-05 | Bounded concurrency per automation | At most `concurrency` (default 1) runs of one automation are `running`/`waiting` at once; the claim is one conditional update. | P1 |
| AUTO-06 | Only confirmed content runs | A run is claimed only when `confirmed_hash = approval_hash`; the executor runs the indexed copy, never the file; a recipe new or changed outside an owner save is not runnable until confirmed (a schedule, missed-policy, budget or concurrency change included, §20.3 D26). Dry runs are exempt (they write nothing, AUTO-12), but only the owner dry-runs an unconfirmed recipe (ask #271): the CLI refuses it under AI-agent markers (AGENT-07, `WATCHTOWER_AUTOMATION_RUN_ID` included) and `draft_automation` refuses to dry-run a draft whose `approval_hash` is an unconfirmed recipe's. | P1, P3 |
| AUTO-07 | The script sees the world only through the SDK | No `require`, filesystem, network, timers or promises in the sandbox; no SDK result carries a secret. | P1 |
| AUTO-08 | Every run is bounded and ends | Active time ≤ `budget.minutes`, tokens ≤ `budget.tokens`, waits ≤ `pause_timeout_hours`; every run reaches exactly one terminal status, including after a daemon restart (`interrupted`). | P1 |
| AUTO-09 | Triggers only queue | Scheduler, event bus, CLI `run` and Desktop buttons only insert `queued` rows; only the daemon's executor runs them (dry run excepted, which writes nothing outside its journal). | P1, P4 |
| AUTO-10 | Missed schedules | After a gap covering N ≥ 1 missed due times: `run_once` inserts exactly one `catch_up` run, `skip` none; a restart never repeats it. | P1 |
| AUTO-11 | Complete journal | Every SDK call, denied ones included, has exactly one step row with its status, tokens and duration. | P1 |
| AUTO-12 | Dry run writes nothing outside its journal | A dry run makes no `agent_actions` row, no output, no state change, starts no session and runs no `shell()`. | P1, P5 |
| AUTO-13 | Exact shell commands, workbench only | `shell()` runs only a command byte-equal to a `shell:` entry, only in a workbench automation, in the workbench folder, with the §13.2 environment. | P5 |

Guard test names follow `TestAuto0N_…` (Go) and `testAuto0N_…` (Swift).

### 14.2 AGENT-03 amendment — owner-approved, ask #265

Replace AGENT-03's Observable with:

> `Registry.SetTrust(tool, execute)` returns `ErrExternalExecute` for a tool with `External: true`
> (`create_jira_issue`, `connect_jira_board`, `send_slack_message`, …); `watchtower actions trust` surfaces that
> error; the Settings toggle is disabled for external tools. The same lock covers a local tool marked
> `AlwaysAsk: true` (`dismiss_tracks`, a bulk write): `SetTrust` returns `ErrAlwaysAsk`, `Propose` records it
> pending even from a persisted `execute` trust row, a direct-apply session refuses it, and the Settings toggle is
> disabled for it (`always_ask` in `actions tools --json`).
> **Exception — the automation auto grant (owner-approved 2026-10-14 in ask #265; in code with Automations P2):** on the `automation`
> surface only, a call made by an automation run is applied without a per-call Approve — External tools included,
> AlwaysAsk tools never — when an `automation_tool_grants` row exists for (that automation, that tool) whose
> `grant_hash` equals both the automation's current `approval_hash` and the run's `recipe_hash`. Such a grant is
> written only by `watchtower automations auto <id> <tool> on --hash <sha>` from the Desktop, refused under an AI
> agent's environment markers (AGENT-07) and refused for a hash other than the current one; the grant is active
> only while the recipe's `approval_hash` equals the granted hash — any change to the recipe's script or
> permissions (by anyone, the assistant included) deactivates it, and only the owner granting the new hash or a
> return to the exact granted text re-activates it. An auto write is still one `agent_actions` row (`trust_at_create='execute'`, `context_type=
> 'automation_run'`) applied through `Apply`'s claim (AGENT-05), logged as an `auto=1` step of its run and shown in
> the Inbox as applied. No other surface, binding, trust row or grant can execute an External tool.

Why (added): "The owner decided (ask #265) that a reviewed automation is the click: approving the exact code and
permissions once is a stronger review than approving each scheduled post blind; the hash binding keeps that
review from being reused for code the owner did not see."

New guards: `TestAgent03_AutoGrantAppliesExternalOnlyOnAutomationSurfaceWithMatchingHash`,
`TestAgent03_AutoGrantNeverCoversAnotherAutomationOrSurface`, `TestAgent03_RecipeEditMakesAutoGrantInactive`,
`TestAgent03_AlwaysAskIsNeverAuto`, `TestAgent03_AutoGrantRefusedUnderAgentMarkers` (cmd). Existing guards
unchanged.

### 14.3 Other agent-actions changes (strengthening; changelog entries, no guard relaxed)

- AGENT-01: names the `automation` surface beside main/target/reaction ("trust is per (tool, surface)" already
  covers it) and the dry-run rule ("a dry run never reaches `Propose`"). Guard
  `TestAgent01_AutomationWriteRecordsProposalOnly`.
- AGENT-06: `draft_automation` is a read tool on the chat connection that writes nothing; added to the chat-mode
  guard's call list with a fake generator.
- AGENT-07: marker list gains `WATCHTOWER_AUTOMATION_RUN_ID`; `automations confirm`, `automations auto … on`,
  `automations save --confirm-hash` and `automations dry-run` of an unconfirmed recipe (§20.1 D16, ask #271) join
  the refused commands; `automations enable` and `automations delete` join them too (§20.3 D24, ask #293). Guard
  `TestAutomationsCLI_EnableDeleteRefusedUnderAgentMarkers`. Desktop `Constants.agentEnvMarkers` gains the
  variable.

### 14.4 STRIP-01 amendment — approved (ask #270, §20 D10)

Amended text: "…over three tables — `agent_actions`, `reminders` and `automation_outputs` (`kind='inbox'`)… An
automation output is gesture-gated by construction: it exists only because the owner confirmed a recipe that
declares `outputs: [inbox]` (AUTO-06)." STRIP-02 is unaffected (outputs are the backing rows, not a strip
store).

### 14.5 AGENT-04 amendment — approved (ask #270, §20 D11)

Amended: the automation's "change it in words" chat joins main and target as a tool-mode surface
(`.actions(surface: "automation_editor")`) carrying only `draft_automation`, `save_automation` and read tools.

### 14.6 PROJ-03 amendment — approved (ask #272, §20.1 D17; in code with P5)

PROJ-03's Observable gains: "Watchtower writes one more kind of file in the workbench folder: automation recipes,
only at `<folder>/.watchtower/automations/<slug>.md`, only on the owner's Save (the Desktop form or Monaco editor
through `automations save --confirm-hash`) or on the owner's Approve of a `save_automation` card (its `Execute`
in the owner's `actions apply` process), and `automations delete` removes only such a file. The write is atomic
(`fsutil.WriteFileAtomic`); no other path of the folder is written, no workbench MCP tool writes a recipe, and the
daemon never writes the folder." Existing PROJ-03 guards stay unchanged; new guards:
`TestSaveAutomation_WorkbenchWritesIntoItsFolder`, `TestAutomationsCLI_SavePathOutsideWorkbenchAutomationsRefused`.

### 14.7 QC-02 amendment — approved (ask #272, §20.1 D20; in code with P6)

QC-02's Observable gains: "Automations' `mcp()` (§5) is a second, Go-side consumer of the same allowed read-only
tool list: it calls only tools in `externalmcp.ResolveTools`' allowed list of an enabled, listed connection,
through `externalmcp.CallTool`, never through the registry; it never lists a connection itself and never calls a
tool QC-02 does not allow." Guard `TestMCP_OnlyQC02AllowedTools`.

## 15. Templates (P6)

Embedded in `internal/automations/templates/*.md`; installed unconfirmed and disabled.

1. `new-mail-summary` — personal; `event: gmail.new_messages` (and `schedule` variant in the description);
   `gmail:read@*`, `llm:light`; `outputs: [inbox]`; cursor in `state` (`since`).
2. `pr-review-rounds` — workbench; `schedule: "0 10,16 * * 1-5"`; `shell:"gh pr list --state open --json
   number,title,url,author,updatedAt"`, `session:start`, `llm:light`; for each PR updated since the last round
   (`state`), one `session()` whose prompt tells the agent to review the PR and file its findings as `ask_owner`
   asks; `outputs: [report]`.
3. `jira-state-report` — personal; `schedule: "0 9 * * 1"`; `jira:read@<PROJECT>` (placeholder the form asks
   for), `llm:strong`; `outputs: [report, briefing]`.
4. `team-performance-report` — personal; `schedule: "0 17 * * 5"`; `jira:read@*`, `people:read`, `slack:read@*`,
   `llm:strong`; `outputs: [report]`.
5. `release`, `deploy-test`, `deploy-stage` — workbench; `button: {label: "Release"|"Deploy to test"|"Deploy
   to stage", confirm: true}`; `shell:"make release"` / `shell:"make deploy-test"` / `shell:"make deploy-stage"`
   (placeholders the owner edits), `session:start` for the follow-up check; `outputs: [report]`.

## 16. Non-goals (v1)

Reaction commands on the bus; async JS, npm packages, network or files for scripts; external MCP writes (QC-02);
running when the daemon is not running or on another machine; replay/resume of an interrupted run; mobile
authoring (the phone may later show runs through a slice — not in v1); per-call token limits finer than the run; dollar budgets;
sharing personal recipes; a visual flow editor; parameterised `shell` commands; headless `session()`.

## 17. Phases

| Phase | Depends on | Delivers |
|---|---|---|
| **P1 core** | none | `internal/automations` recipe + manifest parser, hashes, goja sandbox, SDK `llm`, read `tool`, `state`, `output.inbox`/`report`, `log`; migration 00113; scheduler (cron, `run_once`/`skip`) and executor goroutines in the daemon, SIGUSR2; per-run token budgets (the daily cap was retired by §20.3 D25); Feature Manager feature `automations`, default ON (§20 D12); CLI (`list/show/validate/rescan/run/dry-run/cancel/runs/steps/enable/disable/confirm/save/delete/outputs/wake`); `list_emails`/`get_email` (local store only, §20 D2); the D23 local reads, the memory tools in `buildAutomationRegistry`, `get_writing_style` on the automation surface (§6.1, §20.1 D23, ask #277); source tags; config key; `docs/inventory/automations.md` with AUTO-01, 02 (read side), 04–12; AGENT-07 marker. |
| **P2 writes** | P1 | `automation` surface on the §6.1 tools; Binding `AutomationRunID`; trust order §6.2; `tool` writes + `{wait}`; `output.target/slack/briefing` + briefing section; migration 00116; `automations auto`; AGENT-03 amendment; AUTO-02 (write side), AUTO-03. |
| **P3 authoring + UI** | P1, P2 | Skill `create-automation`; `draft_automation`, `save_automation`; Desktop Automations tab, card, history, form, Monaco editor, widening and grant sheets, "change it in words" chat; Inbox labels and output cards; quick run from the "Run Automation…" palette (⌃⌘R) and the menu-bar tray with a finish notice (§12.7, ask #295); the STRIP-01 / AGENT-04 amendments (approved, ask #270). |
| **P4 events** | P1 | Bus, publishers in the five sync phases, `Flush` per cycle, `event` trigger, `where` matching, AUTO-09 event half. |
| **P5 workbench** | P1, P2, P3 | Workbench scope, repo recipes in `.watchtower/automations/`, Desktop rescan for protected folders, header buttons, `session()` + `AutomationSessionCenter`, `shell()`, `ask()`, migration 00117, AUTO-12 (session/shell half), AUTO-13; the PROJ-03 amendment (§14.6, approved in ask #272). |
| **P6 mcp, agent, templates** | P1, P2 | `mcp()`, `agent()` (§6.5, §20 D3), five templates + gallery (`templates`, `install-template`), e2e over the templates; the QC-02 amendment (§14.7, approved in ask #272). |

P2 and P4 may run as parallel lanes after P1 (P4 touches the daemon sync phases, P2 the registry). Swift work
(P3, P5) is one lane at a time.

## 18. Tests that must exist

**P1** (`internal/automations`, `cmd`, `internal/daemon`):
- Parser: `TestRecipe_ParsesFrontmatterDescriptionAndOneJSBlock`, `TestRecipe_RejectsZeroOrTwoJSBlocks`,
  `TestRecipe_RejectsUnknownKeyAndBadSlug`, `TestRecipe_BudgetBounds`, `TestRecipe_AsyncScriptRefused`.
- Manifest: `TestManifest_GrammarTable` (valid/invalid strings incl. quoting), `TestManifest_ScopeMatching`
  (exact, case, `*`, absent scope arg needs `@*`), `TestManifest_MCPGlob`, `TestManifest_ShellExactOnly`
  (prefix/suffix/whitespace variants refused), `TestManifest_CoversWidening`, `TestToolCapabilities_CoversEveryAutomationTool`.
- Hashes: `TestApprovalHash_IgnoresNameChangesOnScriptPermissionsScheduleBudget`, `TestApprovalHash_ButtonLabelIsCosmetic`, `TestAuto06_ScheduleBudgetEditNeedsConfirmation`, `TestAuto06_ButtonLabelEditKeepsConfirmation`.
- Sandbox: `TestAuto07_NoRequireFsNetTimers`, `TestAuto08_InterruptOnTimeout` (busy loop stops within 1 s of the
  deadline), `TestAuto08_InterruptOnBudget` (fake generator reporting 30k tokens per call, budget 50k: second call
  crosses it → `budget_exceeded`; third never starts), `TestBudget_EstimatesTokensWhenUsageMissing`, `TestAuto08_NoDailyCapAcrossRuns`,
  `TestSandbox_ResultTooLargeIsAnErrorNotATruncation`, `TestSandbox_StateTooLarge`, `TestSandbox_ErrorLineMapsToFile`.
- Permissions: `TestAuto01_DeniedCallThrowsAndWritesDeniedStep` (backend fake records zero calls).
- State: `TestAuto04_FailedRunLeavesStateAndOutputsUnchanged` (failed, timed_out, budget_exceeded, cancelled
  each), `TestAuto04_SucceededCommitsStateAndOutputsAtomically`.
- Executor with fake SDK backends: `TestExecutor_RunsQueuedToSucceeded`, `TestAuto05_OneActiveRunPerAutomation`
  (two queued, concurrency 1), `TestAuto05_ConcurrencyN`, `TestExecutor_MaxConcurrentRuns`,
  `TestAuto06_UnconfirmedRecipeIsCancelledNotRun`, `TestAuto06_ExecutorRunsIndexedCopyNotFile`,
  `TestAuto08_RestartMarksInterrupted`, `TestAuto11_EveryCallHasOneStep`.
- Scheduler on a fake clock: `TestAuto10_SleepAcrossTwoDueTimesRunsOnceCatchUp`, `TestAuto10_SkipPolicyRunsNone`,
  `TestAuto10_RestartDoesNotRepeatCatchUp`, `TestScheduler_OnTimeWithinGrace`, `TestScheduler_NewAndReenabledDoNotCatchUp`,
  `TestScheduler_DSTTransition`, `TestAuto09_RunCommandOnlyQueues`, `TestRun_CoalescesSecondTrigger`.
- Dry run: `TestAuto12_DryRunWritesNoActionsOutputsOrState`.
- Manifest (ask #273): `TestManifest_UnscopedSourceReadsNeedStar`, `TestManifest_KnowledgeToolsOnlyByToolEntry`;
  (ask #277) `TestManifest_D23ToolScopes`, `TestManifest_MeetingsAndDayplanReadOnly`.
- Local reads (ask #277): `TestListInbox_*`, `TestListCalendarEvents_*`, `TestMeetingRecapTools_*`,
  `TestDayPlanTools_*`, `TestListReminders_*`, `TestJiraSprintReleaseTools_*`, `TestD23Tools_AutomationSurfaceOnly`,
  `TestMemoryOpen_NoAccessBumpOnAutomationSurface`, `TestBuildAutomationRegistry_AddsMemoryTools`.
- CLI: `TestAutomationsCLI_ConfirmRefusedUnderAgentMarkers`, `TestAutomationsCLI_SaveIsAtomicAndIndexes`,
  `TestAutomationsCLI_DryRunUnconfirmedRefusedUnderAgentMarkers` (ask #271).
- Daemon: `TestDaemon_AutomationWakeSignalDoesNotStartSync`.
- Tier scan stays green with the two new source tags.

**P2:** `TestAgent01_AutomationWriteRecordsProposalOnly`, the five AGENT-03 guards of §14.2,
`TestAuto03_GrantInactiveAfterEditAndReactivatedByNewHash`, `TestAuto02_ToolWriteGoesThroughPropose`,
`TestToolWait_AppliedRejectedFailed`, `TestToolWait_PauseExcludedFromActiveTime`, `TestTrustOrder_AutomationSurface`
(table over AlwaysAsk / grant / External / tool_trust), `TestBriefing_IncludesAutomationOutputsSinceLast`,
updated `TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces`.

**P3:** Go — `TestDraftAutomation_WritesNothing` (AGENT-06 list), `TestDraftAutomation_RefusesDryRunOfUnconfirmedRecipe`
(ask #271), `TestDraftAutomation_EmailStepsReachTheChatClipped` (ask #272), `TestSaveAutomation_AlwaysAskAndPinsHash`,
`TestSaveAutomation_RefusesWhenFileChangedSincePropose`. Swift (`make test-swift FILTER=…`) —
`AutomationsViewModelTests` (list, badges, Run now → CLI args, Dry run rendering, state survives navigation),
`AutomationQueriesTests`, `AutomationFormTests` (widening sheet shown only on widening; grant boxes unchecked by
default), `AgentActionCardLabelTests` (automation label), `ActionStripAutomationOutputTests` (output cards on the
strip, Done/Dismiss write only `automation_outputs`), `QuickRunCatalogTests` (who is listed, dimmed reasons,
fuzzy order), `QuickRunCenterTests` (run args, confirm-first, dimmed ↩ opens instead of running, finish notice once
per watched run), `TrayRunAutomationMenuTests` (grouping and status text).

**P4:** `TestBus_OneRunPerAutomationPerCycle`, `TestBus_WhereFilterAndGlob`, `TestBus_EventsCarryNoContent`,
`TestBus_TruncatesAt100`, one publisher test per sync phase (`TestPhaseGmailSync_PublishesNewMessages`, …),
`TestAuto09_FlushOnlyQueues`.

**P5:** `TestAuto13_ShellExactCommandInWorkbenchFolder`, `TestAuto13_ShellRefusedInPersonalRecipe`,
`TestShell_KillsProcessGroupOnInterrupt` (reaps in `t.Cleanup`), `TestShell_EnvHasRunMarkerAndNoSecrets`,
`TestShell_OutputTailCappedAt256KiB`, `TestShell_OversizedOutputTruncatedNeverFails` (ask #272),
`TestSaveAutomation_WorkbenchWritesIntoItsFolder` (PROJ-03, ask #272),
`TestSession_WaitsForAppThenSessionThenFinish`, `TestAsk_WaitsAndDelivers`, `TestAuto12_DryRunStartsNoSessionOrShell`,
`TestRescan_WorkbenchRecipeNeedsConfirmation`, migration test for 00117. Swift — `WorkbenchHeaderAutomationButtonsTests`
(runnable/unconfirmed/active states, confirm dialog), `AutomationSessionCenterTests` (launch on request, writes
session id, wakes daemon; app launched later picks pending request).

**P6:** `TestMCP_OnlyQC02AllowedTools`, `TestAgent_ToolSetIsIntersection`, `TestAgent_BudgetCarvedFromRun`,
`TestAgent_WritesStayProposals`, `TestTemplates_AllParseAndValidate`, `TestTemplates_DryRunE2E` (each of the five
on seeded fixtures with a fake LLM and fake shell/session backends; expected step kinds and outputs pinned).

## 19. Docs

P1 creates `docs/features/automations.md` (linked from CLAUDE.md's Feature Notes), `docs/inventory/automations.md`
and the README row. P2 updates `docs/inventory/agent-actions.md` (AGENT-03 text, changelog) and
`docs/features/agent-actions.md`. P3 and P5 update `docs/app-guide.md`. Each phase appends to the feature note.

## 20. Decisions (ask #270)

The owner answered every open question of the draft in ask #270 (2026-10-14). Each is pinned below and in the
section it governs; nothing remains open.

1. **D1 Wake signal.** A separate `SIGUSR2` watcher (`daemon.AutomationWakeSignal`, `WatchAutomationWake`)
   feeds only the automations goroutines; `SIGUSR1` keeps meaning "run a sync" (§7.4).
2. **D2 Email reads.** `list_emails`/`get_email` read only the locally synced store (`gmail_messages`,
   `imap_messages`), never the live API, for Gmail and IMAP alike (owner: "I imagine it reads from the local
   index"). No per-flavour or per-provider gating: automations carry the same Google Limited Use posture as the
   inbox, memory and briefing, and the product-wide decision governs them all (`docs/security-audit-2026-07-31.md`)
   (§6.1).
3. **D3 `agent()` with CLI providers.** A headless `ai query`-style process with the chat-mode MCP server bound to
   `--surface automation --automation-run N`, `--allowedTools` = the effective tool set, the run marker in its
   environment; runtime B (`internal/agentloop`) for ollama (§6.5).
4. **D4 Budgets in tokens.** `budget.tokens` (input + output across `llm`/`agent` calls) and `budget.minutes` per
   run (no global daily cap since §20.3 D25, ask #294). No dollar budget anywhere; a
   provider-reported dollar cost is kept in `reported_cost_usd` for display only (§2.3, §7.5, §9.2, §9.3, §12).
5. **D5 What drops a confirmation/auto.** `approval_hash` = script + permissions + outputs + scope; trigger,
   budget, name and description edits keep confirmation and grants (§2.4). *Amended by §20.3 D26 (ask #294): the
   trigger (without a button's label), missed policy, budget and concurrency are in the hash too.*
6. **D6 Restart.** Interrupted runs end `failed` / `interrupted` with state uncommitted; Rerun is offered; no
   replay-resume in v1 (§7.7).
7. **D7 `ask()`** only in workbench automations in v1; a personal recipe declaring `ask:owner` fails validation;
   `owner_asks.project_id` stays NOT NULL (§3.1, §5, §9.5).
8. **D8 Personal recipe folder** = `<workspace dir>/automations/` (§2.1).
9. **D9 `shell()` in a privacy-protected workbench folder** is refused with `NotAvailable` ("this workbench is in
   a protected folder; use session() or move the folder"); the folder is never touched by the daemon (§13.2, §13.4).
10. **D10 STRIP-01 amended** so `output.inbox` appears in the Inbox (§14.4).
11. **D11 AGENT-04 amended** for the "change it in words" chat with the narrow tool set (§14.5).
12. **D12 Feature Manager gate.** Feature `automations`, default ON (with no confirmed recipe nothing runs);
    turning it off stops the scheduler/executor and hides the tab (P1 registers it; P3 hides the tab).
13. **D13 PR comments** go through `session()` in v1 (template 2 does so); an External `add_pr_comment` registry
    tool is a follow-up (§15).
14. **D14 AlwaysAsk tools are never auto** (§14.2).
15. **D15 Workbench binding** is by location only; a `workbench:` frontmatter key is a parse error (§2.3).

### 20.1 Decisions (asks #271–#273, #277)

The phase plans raised seven more questions (D16–D22) and the owner added one more scope decision (D23, ask #277), all on 2026-10-14. Each is pinned below and in
the section it governs. Ask #280 confirmed the readings of D16 and D22, ask #287 kept the Jira and digests rules of
§3.2 (§20.2).

16. **D16 Dry run of an unconfirmed recipe — owner only (ask #271).** The owner may dry-run a recipe that is not
    confirmed yet (the Desktop card's **Dry run**, `automations dry-run` without agent markers); an agent may not.
    Every agent-initiated path refuses it: the CLI under AGENT-07 markers (`WATCHTOWER_AUTOMATION_RUN_ID`
    included, so an automation's `shell()`/`session()`/`agent()` child cannot either), and the chat tool
    `draft_automation`, which dry-runs only a draft and refuses when the draft's `approval_hash` is that of an
    indexed unconfirmed recipe (§11, AUTO-06). No MCP tool runs or dry-runs an automation. Dry-running a confirmed
    recipe stays open to everyone. (Reading keyed by `approval_hash` owner-confirmed in ask #280, §20.2.)
17. **D17 PROJ-03 extended (ask #272).** Watchtower writes recipes into the workbench folder's
    `.watchtower/automations/`, only on the owner's Save or Approve (§14.6; in code with P5).
18. **D18 Draft dry runs may show clipped mail to the main chat (ask #272).** `draft_automation`'s dry-run journal,
    including `list_emails`/`get_email` steps (bodies clipped 32 KiB, step results 4 KiB), is returned to the
    main-chat (or editor-chat) model (§11).
19. **D19 `shell()` output over 256 KiB is truncated, never a failure (ask #272).** Tails kept, `truncated: true`,
    the step names the exit code and the cut stream; never `ResultTooLarge` (§4, §13.2).
20. **D20 QC-02 amended (ask #272).** `mcp()` is a second consumer of the same allowed read-only tool list
    (§14.7; in code with P6).
21. **D21 Broad knowledge tools only by `tool:<name>` (ask #273).** `search_knowledge`, `get_knowledge_document`
    and `get_task_context` are admitted only by an explicit `tool:` entry; there is no `knowledge` capability, so
    `knowledge:read` is a parse error (§3.1).
22. **D22 `list_messages` in v1 only by `slack:read@*` (ask #273)** (or `tool:list_messages`); no per-account
    scope in v1. The same holds for `list_upcoming_events` and `calendar:read@*` (§3.2). (Owner-confirmed in ask
    #280, §20.2.)
23. **D23 More local-store reads for automations, all in P1 (ask #277).** New: `list_inbox`,
    `list_calendar_events`, `list_meeting_recaps`, `get_meeting_recap`, `list_meeting_notes`, `list_day_plans`,
    `get_day_plan`, `list_reminders`, `list_jira_sprints`, `list_jira_releases` — automation surface only, not
    in `tools.ReadTools()`, local store only, limits 50/200, long texts clipped. Existing tools admitted:
    `memory_recall`/`memory_open`/`memory_map` (added to the automation registry; `memory_open` skips its stat
    bump there), `get_writing_style` (gains the `automation` surface), `list_jira_projects` (already
    admitted). New capabilities `meetings:read` and `dayplan:read`; reminders
    under `targets:read`; calendar range and Jira sprints/releases under the existing scoped capabilities;
    `list_inbox`, the memory tools and `get_writing_style` are `tool:`-only (D21's rule applied to cross-source
    and single-purpose tools). `get_confluence_page` is not admitted — it is a live network read and D23 is local
    store only; Confluence content stays reachable through the `tool:`-only knowledge tools (§6.1).

### 20.2 Rulings while P1 was built (asks #280, #287)

- **Ask #280 — owner confirmed both readings.** D16: `draft_automation` refuses a dry run only when the draft's
  `approval_hash` is that of an indexed unconfirmed recipe (a draft that differs from it is its own new text). D22:
  `list_messages` is admitted by `slack:read@*` **or** `tool:list_messages` (likewise `list_upcoming_events` by
  `calendar:read@*` or `tool:list_upcoming_events`).
- **Ask #287 — spec rules kept.** A Jira project grant covers the tool's linked data: `list_jira_issues`/
  `get_jira_issue` stay scoped by their own `project`/key prefix (no widening by links, epics or parents in
  `raw_json`), `get_jira_time_in_status` by `project`, else its `issue_keys` prefixes, else absent, whatever
  `include_linked` says. `digests:read` stays (`list_digests`/`get_digest`/`get_today_briefing`) and `find_experts`
  stays under `people:read`; neither is `tool:`-only.

### 20.3 Rulings after P1 (asks #293, #294, #295, #315)

24. **D24 (ask #293): enable and delete are owner-only.** `automations enable` and `automations delete` are refused
    under every AGENT-07 marker (`agentEnvMarkers`, `WATCHTOWER_AUTOMATION_RUN_ID` included) through the same
    `refuseUnderAgent` check, before anything is read or written, with the hint "enable and delete are owner-only"
    (after `refuseUnderAgent`'s own "the owner decides in Watchtower Desktop (or runs this from a plain Terminal)"). `disable`,
    `cancel`, `run` (of a confirmed, enabled recipe), `rescan` and a plain `save` stay open: they only reduce
    activity or run what the owner already confirmed. Deleting the recipe file directly is outside Watchtower's
    control; only the CLI verb is guarded. Guard `TestAutomationsCLI_EnableDeleteRefusedUnderAgentMarkers`.
25. **D25 (ask #294): no daily token cap.** The global per-day cap `automations.daily_budget_tokens` is removed —
    config key, default, executor wiring (`ExecutorOptions.DailyBudgetTokens`) and the meter's live daily total.
    Each run stays bounded by its own `budget.tokens` and `budget.minutes` (§7.5, AUTO-08). `error_kind='daily_cap'`
    stays in the CHECK (no migration) but is no longer produced. The `TestAuto08_DailyCap*` guards are retired with
    the owner's approval; `TestAuto08_NoDailyCapAcrossRuns` pins the new rule.
26. **D26 (ask #294, amends D5): a schedule or budget change needs the owner's confirmation.** `approval_hash` also
    covers the trigger (`trigger_spec` without a button's cosmetic `label`; `confirm` stays), the `missed` policy
    (any schedule edit waits for the owner), the budget (tokens and minutes) and `concurrency` (§2.4), so editing
    any of them drops a confirmation and auto grants like a script or permission edit does; name, description, a
    button's label and `pause_timeout_hours` still keep it. A rescan makes such a row runnable again only when the
    file reverts to the confirmed text; otherwise the owner confirms. The change re-hashes every recipe once: after
    the upgrade every existing recipe is unconfirmed until the owner confirms it again. Guards
    `TestApprovalHash_GoldenCanonicalBytes` (new bytes and hex), `TestApprovalHash_ButtonLabelIsCosmetic`,
    `TestAuto06_ScheduleBudgetEditNeedsConfirmation`, `TestAuto06_ButtonLabelEditKeepsConfirmation`.
27. **D27 (ask #295): quick run in P3.** After approving the seven UI mockups (2026-10-15) the owner added quick run
    for manual and button recipes to P3: "Run Automation…" (fuzzy search by name over personal and workbench
    recipes; ↩ runs; a `confirm: true` recipe shows "Run “<name>”?" first; an unconfirmed, disabled or unparsable
    recipe is listed dimmed with its reason and ↩ opens its confirmation or card instead of running) and the
    menu-bar tray's "Run automation ▸" submenu (grouped by workbench, then Personal; each item with its last status —
    "✓ <age>", "● running", "needs confirmation"; disabled items not runnable; "Open Automations…" at the end), plus
    a macOS notification when a run started from either place ends. Owner ruling 2026-10-15 (uniform shortcut): one key
    combination does the same thing everywhere, so the palette does not reuse ⌘K and adds nothing to the Workbench
    "Go to…" palette; it has its own app-menu shortcut ⌃⌘R, identical on every tab and window. The owner also
    accepted the confirm sheet's author-line limit (§12.2: only the assistant's saves are attributed). Both call `automations run <id> --json` like the
    card's Run now and respect the feature-off refusal (§12.7). No Go change beyond P3's `show --json` additions
    (§12.2): the CLI already returns `run_id`/`coalesced`, and runs carry `summary`/`error` for the notice.
28. **D28 (ask #315): `output.slack` writes only where the recipe has the right.** `output.slack` needs both
    `outputs: [slack]` and the manifest's `slack:write@<account>` covering the call (the same scope check a
    `tool("send_slack_message")` call passes, `AllowTool`); a denial's `needed` names the `slack:write` scope
    (`slack:write@*` when no account resolves). The output shortcut therefore admits an auto grant on
    `send_slack_message` only together with a `slack:write` entry (`AdmitsWrite`), so a grant never exceeds the
    recipe's scope. `output.target` is unchanged: `outputs: [target]` is its whole gate. Guards
    `TestOutput_SlackNeedsSlackWriteScope`, `TestManifest_AllowOutputToolSlackNeedsWriteScope`,
    `TestManifest_AdmitsWrite`.
