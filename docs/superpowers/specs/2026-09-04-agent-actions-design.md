# Agent Actions — tool registry, controlled writes, first write tools

**Date:** 2026-09-04
**Status:** Approved (owner, 2026-09-04)
**Initiative:** "Hermes inside Watchtower", sub-project 1 of 5

## 1. Overview

The owner wants a Hermes-Agent-like assistant inside Watchtower: a general
agent that can use pluggable tools (our own CLI/MCP surface plus custom
tooling) — but safe enough for work data. Hermes is "scary for work" for one
reason: a shell plus self-modifying skills plus one process holding every
credential, fed untrusted input from the very channels it reads. Watchtower
already encodes the opposite stance (`internal/ai/client.go` hides
Bash/Read/WebFetch from the model because synced Slack/Jira text is a prompt
injection surface). This initiative keeps that stance and adds capability on
top of it.

Today the assistant has no agent runtime of its own: every chat is
SwiftUI → `watchtower ai query` → `claude -p` / `codex exec` / Ollama HTTP,
the tool loop lives inside the vendor CLI, the model sees ~25 **read-only** MCP
tools, and the only write path is a fenced `watchtower-action` JSON block in
the reply text that Swift parses after the stream ends (target chat only,
17 target-scoped kinds, propose→Approve). Nothing is pluggable: a new action is
Swift code in four places.

This sub-project introduces the piece that makes tools first-class:

- a **tool registry** in Go (`internal/tools`) — registry is the core, MCP is
  an adapter over it;
- **controlled writes** — a write tool never touches its target system; it
  records a proposal and hands the model a receipt; the owner approves in the
  chat; Go executes exactly once;
- a **separate chat mode** of the MCP server so the developer surface
  (`watchtower mcp`, DEV-01) stays read-only untouched;
- the first two write tools, `create_target` (tasks and reminders) and
  `create_jira_issue`, on two surfaces: the main AI Chat and the target chat.

Owner decisions recorded during brainstorming (2026-09-04):

- Runtime choice **A now, B mandatory next**: keep the vendor-CLI loops
  (claude/codex reach tools via MCP; Ollama honestly has no tools) and design
  the registry so a Go-owned tool loop for HTTP providers (sub-project
  "runtime B") is a second adapter, not a rewrite.
- Write is needed but **controlled** — the four layers in §6.
- The Jira proposal card is **not editable**; the owner refines via chat and
  the assistant re-proposes.
- Surfaces: main AI Chat + target chat. Situation/meeting/idea/track chats
  stay draft-only (review-rules "The assistant & chat contracts").
- `create_target` is **not** offered in the target chat (TGT-BRIEF-01 axis 3
  forbids creating work items outside the target's vertical line);
  `create_jira_issue` **is** offered there — a Jira issue is not a target and
  sits outside the artifact mandate — recorded in `targets.md`'s changelog.

The five sub-projects, in order: (1) this spec; (2) assistant character
(SOUL-like markdown); (3) proactivity/nudging (daemon phase + notifications,
never initiated chat turns); (4) self-authored tools (declarative manifests,
never free scripts); (B) runtime — Go tool loop for HTTP providers, and the
existing read tools migrate into the registry then.

## 2. Non-goals (v1)

- Own agent loop / function calling for Ollama or API-key providers (runtime B).
- Migrating the 17 target-chat block kinds onto tools (a TGT-BRIEF revision;
  the block grammar stays byte-for-byte as is).
- Moving the existing `internal/mcp` read tools into the registry (done with B,
  when an in-process loop needs them).
- Mid-loop blocking approval (claude's `--permission-prompt-tool`); v1 never
  blocks the model — receipts only.
- Editable proposal cards; per-issue Jira field pickers.
- Model-authored tools, external MCP servers, declared CLI tools (sub-project 4
  — the registry's `Access`/`External`/trust fields are designed to host them).
- Any tool on the draft-only chat surfaces; any change to `internal/repl` /
  `watchtower ask` prompts.
- Linking a created Jira issue back onto the originating target (follow-up).

## 3. Architecture

```
Swift chat VM ──ai query --tools chat --surface S --conversation C --turn T──▶ Go
   │                                                                          │
   │ observes agent_actions (GRDB)                                claude -p / codex exec
   │ Approve/Reject/Retry → `watchtower actions approve|reject|apply <id>`     │ MCP (stdio)
   ▼                                                                          ▼
agent_actions ◀── Registry.Propose ◀── `watchtower mcp --chat …` (write tools) ◀── model tool call
      ▲
      └── Registry.Apply (Go executes: db.CreateTarget | jira.CreateIssue) ◀── `actions approve`
```

Components:

- **`internal/tools` — the registry (core).** `Tool{Name, Description,
  InputSchema, Access read|write, External bool, Surfaces []string,
  Validate, Execute}`. `Registry.Propose(ctx, call)` validates the JSON schema,
  runs the tool's semantic `Validate`, inserts an `agent_actions` row and returns
  a `Receipt`. A write call never reaches `Execute` from the MCP path unless the
  tool's trust is `execute`. `Registry.Apply(ctx, id)` runs `Execute` for an
  `approved`/`failed` row and records `applied`/`failed`. `SetTrust` refuses
  `execute` for `External` tools.
- **`internal/mcp` — adapter.** Dev mode (`watchtower mcp`) is unchanged:
  `SetReadOnly()` (`PRAGMA query_only=ON`), read tools only, DEV-01 intact.
  New **chat mode** `watchtower mcp --chat --surface main|target
  --conversation <id> --turn <uuid> [--db-path]` opens the DB writable,
  mounts the same read tools plus the registry's tools filtered by surface, and
  `get_action`. Dev mode never calls the registry wiring.
- **`agent_actions` + `tool_trust`** — goose migration `00061`. The proposal
  queue and the audit log are the same rows; rows are never deleted.
- **Go executes.** Desktop never writes `agent_actions`. It calls
  `watchtower actions approve <id>` (flip + execute inline), `reject <id>`,
  `apply <id>` (retry a `failed` row), observes the row through GRDB and renders
  it. One status owner; runtime B and sub-project 4 reuse the same executor.
- **Jira.** `internal/jira.Client.CreateIssue` (POST `/rest/api/3/issue`),
  `watchtower jira create` for humans/tests; the tool's `Execute` calls the same
  Go function in-process.

Happy path: owner types "заведи тикет про X" → claude CLI calls
`create_jira_issue` over MCP → registry validates (schema, account enabled,
project synced) → inserts `pending` → returns receipt → the model replies
"proposed, awaiting your approval" → the Desktop's observation renders a card →
Approve → `actions approve` runs `CreateIssue`, fetches the issue, upserts it
into `jira_issues`, marks `applied` with `{key, url}` → card shows the link →
on the owner's next message Swift prepends an "actions since your last
message" block so the model knows the key.

## 4. Registry contract (`internal/tools`)

```go
type Access string // "read" | "write"
type Trust  string // "ask" | "execute"

type Tool struct {
    Name, Description string
    InputSchema       map[string]any        // JSON Schema (draft 2020-12 subset the MCP lib accepts)
    Access            Access
    External          bool                  // the write leaves this machine (Jira); never Trust=execute
    Surfaces          []string              // {"main","target"}; empty = every chat surface
    Validate          func(ctx, *db.DB, Args) error           // semantic checks beyond schema
    Execute           func(ctx, *db.DB, Args) (Result, error) // write tools: run only by Apply
}

type Receipt struct {
    ActionID int64  `json:"action_id"`
    Status   string `json:"status"`           // pending | applied
    Tool     string `json:"tool"`
    Message  string `json:"message"`          // instruction text for the model
    Result   any    `json:"result,omitempty"` // present only when status=applied (trust=execute)
}
```

- `Propose`: schema validation → `Validate` → insert row (`status=pending`,
  `trust_at_create=ask`) → receipt whose `Message` is: *"Proposal #N recorded.
  The owner must approve it in this chat before anything happens. Tell the
  owner it awaits approval; do not claim it is done."* With trust `execute`
  the row is inserted as `approved`, `Execute` runs in the same call, and the
  receipt carries `status=applied` plus the result (or the row lands `failed`
  and the receipt says so). Validation failure returns a tool error to the
  model and writes no row.
- `Apply(id)`: allowed from `approved` and `failed` only, and it CLAIMS the row
  (`approved|failed → executing`) before calling `Execute`; `applied` and
  `rejected` are terminal, and a row already `executing` is refused, so a second
  `Apply` never reaches the tool (AGENT-05). External retries are not
  idempotent — the CLI/card warn "check Jira before retrying".
- `SetTrust(tool, trust)`: `execute` on an `External` tool → error (AGENT-03).
  Unknown tool → error. Stored in `tool_trust`; absent row = `ask`.
- `List(surface)`: tools whose `Surfaces` is empty or contains the surface.

The registry does not know MCP. `internal/mcp` registers each registry tool as
an MCP tool whose handler calls `Propose` (write) or `Execute` (read). In v1
the registry holds only the two write tools; every read tool — the existing
~25 plus the two new ones below — stays a plain `internal/mcp` tool until
runtime B moves reads into the registry.

## 5. First tools

### `create_target` — write, local, surfaces `{main}`

| arg | type | rule |
|---|---|---|
| `text` | string, required | imperative title, ≤ 200 chars, non-empty after trim |
| `intent` | string | why / desired outcome |
| `due` | string | `YYYY-MM-DD` or `YYYY-MM-DDTHH:MM` (owner-local, same shapes `ProposedAction.isValidDueDate` accepts) |
| `priority` | `high\|medium\|low` | default `medium` |
| `reason` | string, required | shown on the card |

Execute = the `watchtower remind` row shape: `level=day`,
`period_start/end=today`, `status=todo`, `ownership=mine`, `due_date=due`,
`source_type='chat'`, `source_id=<action id>`. Result `{target_id}`. Top-level
only — sub-tasks stay on the block grammar (`create_child_target`).

### `create_jira_issue` — write, external, surfaces `{main, target}`

| arg | type | rule |
|---|---|---|
| `account_id` | int | required only when more than one enabled Jira account; else resolved like `resolveJiraAccount` |
| `project_key` | string, required | must appear in `jira_sync_state` for that account |
| `issue_type` | string, required | Jira validates at execute; suggestions come from `list_jira_projects` |
| `summary` | string, required | ≤ 255 chars |
| `description` | string | plain text; Go converts paragraphs to ADF |
| `labels` | []string | optional |
| `priority` | string | optional Jira priority name |
| `reason` | string, required | shown on the card |

Execute = `jira.CreateIssue` → fetch created issue → `UpsertJiraIssue`
(via `Syncer.convertIssue` with `boardID=0`; if that coupling proves too tight
in implementation, store a minimal row and let the next sync fill it) →
result `{key, url}` where `url = site_url + "/browse/" + key`.

### `list_jira_projects` — read, `internal/mcp/jira.go`, both server modes

Per enabled account: `account_id`, label, `project_key`s from
`jira_sync_state`, and for each project the distinct `issue_type` values seen
in `jira_issues` plus the issue count. Mechanical, no AI (DEV-02 shape). An
ordinary read tool next to `list_jira_issues`, not a registry tool.

### `get_action` — read, `internal/mcp/actions.go`, chat mode only

`id` → the row (tool, args, status, result, error, timestamps). Lets the model
answer "did that ticket get created?" without guessing. Registered only by the
`WithRegistry` option, so dev mode never lists it.

## 6. Controlled write — the four layers

1. **Server split.** The developer-surface server registers no write tools
   and keeps `query_only`. The chat mode is a different entry point governed
   by new contracts (AGENT-xx), so DEV-01's "read-only forever" is not
   weakened — it is scoped to what it always governed.
2. **A write tool never writes its target.** `Propose` records; `Apply`
   executes; only the Desktop's Approve (or an owner-granted `execute` trust)
   connects the two. MEM-08's "model proposes, code disposes", applied to
   actions.
3. **Trust per tool, never global.** `ask` by default; `execute` is
   opt-in per tool name via `watchtower actions trust` or Settings; external
   tools cannot be `execute` in v1 by construction.
4. **Audit.** `agent_actions` is the log: who approved (the owner, by
   definition — there is one), when, result or error. Never deleted.

By construction there is still no shell and no free HTTP for the model: only
declared handlers. Sub-project 4's model-authored tools inherit `ask`.

## 7. Schema — migration `00061_agent_actions.sql`

```sql
CREATE TABLE agent_actions (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    tool            TEXT    NOT NULL,
    external        INTEGER NOT NULL DEFAULT 0,          -- snapshot of Tool.External
    args_json       TEXT    NOT NULL,
    reason          TEXT    NOT NULL DEFAULT '',
    surface         TEXT    NOT NULL DEFAULT '',         -- 'main' | 'target'
    conversation_id INTEGER NOT NULL DEFAULT 0,          -- chat_conversations.id (Swift-owned table; no FK)
    context_type    TEXT    NOT NULL DEFAULT '',         -- '' | 'target'
    context_id      TEXT    NOT NULL DEFAULT '',
    turn_id         TEXT    NOT NULL DEFAULT '',         -- Swift-generated UUID per send
    status          TEXT    NOT NULL DEFAULT 'pending'
                    CHECK(status IN ('pending','approved','rejected','applied','failed')),
    trust_at_create TEXT    NOT NULL DEFAULT 'ask' CHECK(trust_at_create IN ('ask','execute')),
    result_json     TEXT    NOT NULL DEFAULT '',
    error           TEXT    NOT NULL DEFAULT '',
    created_at      TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    decided_at      TEXT    NOT NULL DEFAULT '',
    applied_at      TEXT    NOT NULL DEFAULT ''
);
CREATE INDEX idx_agent_actions_conversation ON agent_actions(conversation_id, created_at);
CREATE INDEX idx_agent_actions_status       ON agent_actions(status);

CREATE TABLE tool_trust (
    tool       TEXT PRIMARY KEY,
    trust      TEXT NOT NULL CHECK(trust IN ('ask','execute')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
```

Status machine: `pending → approved → executing → applied | failed`;
`pending → rejected`; `failed → executing` (explicit retry) `→ applied | failed`.
`executing` is `Apply`'s claim, taken before the tool runs so two overlapping
applies can never both execute (AGENT-05); a row left there by an interrupted
apply is reclaimed with `watchtower actions apply --force`. Terminal: `applied`,
`rejected`. Mirror into `schema.sql`, add both tables to `TestAllTablesExist`,
regenerate the schema golden.

Swift-owned `chat_messages` (`Sources/Database/Queries/ChatMessageQueries.swift`)
gains `turn_id TEXT NOT NULL DEFAULT ''` via a guarded
`ALTER TABLE … ADD COLUMN` next to its `ensureTable` (Go never reads it).

## 8. Go surface

- **`internal/tools`**: `registry.go` (types, Propose/Apply/SetTrust/List),
  `targets.go` (`create_target`), `jira.go` (`create_jira_issue`);
  `internal/db/agent_actions.go` (insert, get, list by conversation/status,
  transition helpers, trust get/set). Read tools: `internal/mcp/jira.go`
  gains `list_jira_projects`; new `internal/mcp/actions.go` holds `get_action`
  and the `WithRegistry` option that mounts registry tools in chat mode.
- **`internal/jira/client.go`**: `CreateIssue(ctx, CreateIssueRequest) (Issue, error)`
  and `GetIssue(ctx, key)`; `adf.go` converts plain text into an ADF `doc` of
  paragraphs. Error mapping: 400 → the Jira `errors`/`errorMessages` text
  (e.g. "issuetype: The issue type selected is invalid"); 401 after a
  successful refresh is already `ErrAuthRevoked` — the executor records
  `failed` and marks the account `revoked` exactly as `phaseJiraSync` does;
  403 → "no permission to create issues in <project>".
- **`cmd/jira.go`**: `jira create --project P --type T --summary S
  [--description-file F] [--label L]… [--priority X] [--json]` under the
  persistent `--account`. Envelope `{ok, key, url, error}`.
- **`cmd/actions.go`**: `actions list [--status] [--conversation] [--json]`,
  `show <id>`, `approve <id>` (flip + `Apply` inline), `reject <id>`,
  `apply <id>` (retry), `trust <tool> ask|execute`, `tools [--surface] [--json]`
  (registry listing with access/external/trust). `approve`/`apply` exit 0
  whenever the status change persisted, reporting execution separately
  (`applied_ok`, `error`) — the `recap_ok` precedent; exit 1 only when nothing
  persisted.
- **`cmd/mcp.go`**: `--chat`, `--surface`, `--conversation`, `--turn`. In chat
  mode: no `SetReadOnly`, `WithRegistry(reg, surface, binding)` option; the
  binding (conversation, turn, surface, context) is stamped on every proposal.
- **`cmd/ai.go` / `internal/ai/client.go` / `internal/codex/mcp.go`**:
  `ai query --tools chat --surface S --conversation C --turn T` switches
  `buildMCPConfig` (claude) and the generated `config.toml` (codex) to the
  chat-mode server command. The existing `--allowedTools mcp__watchtower`
  already admits every tool of that server. The dead `--allowed-tools` flag
  and its Swift plumbing (`extraAllowedTools`) are deleted. Ollama:
  `cmd/generator.go` keeps passing no tools; nothing changes on the Go side.

## 9. Desktop

- **`AgentActionQueries`** (WatchtowerCore, GRDB, read + `ValueObservation`
  by conversation). **`AgentActionFeed`** (Core) — the shared piece each VM
  composes (`SkillsCatalog` precedent): observed rows, `cards(forTurn:)`,
  approve/reject/retry via `CLIRunnerProtocol` (`actions approve <id> --json`)
  with per-id in-flight state, and `sinceLastTurnBlock()` (see §10).
- **`ChatViewModel`** and **`TargetChatViewModel`** compose the feed, generate a
  `turnID` per `send()`, persist it on the assistant message, pass
  `--tools chat --surface main|target --conversation --turn` through
  `WatchtowerAIService.buildArgs`. The four draft-only VMs and the setup
  chats are untouched (AGENT-04).
- **`AgentActionCardView`** — new, generic, separate from
  `TargetActionCardView`: tool title, per-tool argument rendering (Jira:
  project/type/summary/description/labels; target: text/due/priority), reason,
  status pill, result link, error text, Approve/Reject/Retry. Cards interleave
  in both message lists after the assistant message with the same `turn_id`;
  during a stream they attach to the placeholder (which carries the turn id in
  memory). Two or more cards on a turn get the existing "Approve all" row
  shape. External retry shows the duplicate warning.
- No follow-up AI turn after Approve (TGT-BRIEF precedent). Cards are DB rows,
  so they survive reload and `newChat()`/`bind(to:)` need no card state to
  clear beyond the feed's conversation binding.
- **Settings → "Assistant tools"** card: `SettingsToolsViewModel` lists
  `actions tools --json` (name, description, access, external, trust) with a
  trust toggle, disabled for external tools; ships with its own test suite.
- **Ollama / no-tools providers**: Swift derives `supportsTools` from the
  provider kind (`ai models --json` → `cli` vs `http`); when false the prompt
  builders emit the honest variant (§10) and the feed is not started.

## 10. Prompts

- **Shared `AGENT ACTIONS` contract block** (Core, `AgentToolsContract.promptBlock(surface:)`),
  appended by the main and target VMs: write tools create *proposals*; after a
  write-tool call tell the owner it awaits approval and never claim it is
  done; one proposal per item, never re-propose the same item in one turn;
  when project/type is ambiguous ask, don't guess, and call
  `list_jira_projects` first; `get_action` answers "what happened to #N".
  The block lists the surface's write tools by name — the schemas come from
  MCP.
- **Main chat** (`ChatViewModel.formatSystemPrompt`): the "There is no SQL tool
  and no shell" sentence stays; the `IMPORTANT RESTRICTIONS` "never write /
  never call external systems" wording becomes "you cannot write directly —
  every write is a proposal through a tool, executed only after the owner
  approves". Block slots between `promptHeader` and
  `promptDeepLinksAndRestrictions`. Nothing is versioned in the DB prompt
  registry (Swift strings), so no bump.
- **Target chat**: the block coexists with `taskActionsContract` and draws the
  line: mutations of this target and its vertical line → `watchtower-action`
  blocks (unchanged); a Jira issue → the `create_jira_issue` tool. Re-injected
  on resumed turns with the other context blocks (existing behavior).
- **Actions since your last message**: when this conversation has rows whose
  `decided_at` or `applied_at` is later than the previous owner message's
  timestamp, the VM prepends `=== ACTIONS SINCE YOUR LAST MESSAGE ===` (tool,
  status, result/error per row) to the outgoing user message — the target
  chat's context re-injection precedent; not persisted as chat text.
- **Honest no-tools variant** (Ollama): the `TOOLS` section and the actions
  block are replaced by "No tools are connected in this session; answer from
  the conversation only and say so when asked to look something up." — fixing
  the pre-existing prompt that promised tools an HTTP provider never had.

## 11. Contracts — new `docs/inventory/agent-actions.md`

- **AGENT-01 — The model never writes.** Every write-tool call through the chat
  server becomes an `agent_actions` row; with trust `ask` no data table
  changes. Guard: call each write tool through chat mode with `ask` and dump
  `targets`/`jira_issues` byte-identical (the MEM-14 guard shape).
- **AGENT-02 — Dev surface untouched.** Dev mode registers no `write` tool and
  keeps `query_only`. Guard: `TestNoToolMutatesDatabase` extended to assert no
  registry write tool is listed in dev mode.
- **AGENT-03 — External never auto.** `SetTrust(execute)` on an `External`
  tool errors; the Settings toggle is disabled for them.
- **AGENT-04 — Draft-only surfaces see no tools.** Only the main and target
  VMs pass `--tools chat`. Guard: Swift tests on the situation/meeting/idea/
  track VMs' service calls.
- **AGENT-05 — Apply exactly once.** `Apply` on `applied`/`rejected` errors;
  retry only from `failed`.

Interplay, recorded in changelogs: `targets.md` — `create_target` is not a
target-chat tool (TGT-BRIEF-01 axis 3); `create_jira_issue` from the target
chat creates an external artifact outside the target mandate, still behind
Approve; TGT-BRIEF-01..03 semantics, guard tests and the block grammar are
unchanged. `dev-surface.md` — DEV-01 wording gains "the chat-mode server
(`--chat`) is a separate entry point governed by AGENT-01/02". `review-rules.md`
"The assistant & chat contracts" — action surfaces may now act through the
registry's proposal path as well as the block grammar; draft-only unchanged.
`docs/inventory/README.md` gains the module row.

## 12. Error handling

| failure | behavior |
|---|---|
| schema/semantic validation fails | tool error to the model, no row |
| DB insert fails in `Propose` | tool error to the model |
| `actions approve` process fails (CLI missing, crash) | row stays `pending`, card shows the error, Approve stays available |
| `Execute` fails | row `failed` + `error`, card offers Retry (external: with duplicate warning) |
| Jira auth revoked | row `failed`, account `status='revoked'` (same rule as `phaseJiraSync`) |
| chat-mode server crashes mid-turn | the vendor CLI reports a tool error; the model tells the owner |
| provider without tools (Ollama) | honest prompt, no feed, no cards |
| `chat_conversations` absent (CLI-only install) | `conversation_id=0` rows are legal; `actions list` still works |

## 13. Testing

Go (`go test ./internal/tools ./internal/mcp ./internal/jira ./internal/db ./cmd`):
registry schema/semantic validation, receipt text, `ask` vs `execute` paths,
`External` trust refusal, apply-once, surface filter; `create_target` row shape
equals the `remind` shape; `create_jira_issue` against `httptest` (request
body incl. ADF, 400/401/403 mapping, post-create upsert); chat vs dev mode tool
lists; `get_action`; CLI envelopes and exit codes; migration golden +
`TestAllTablesExist`; guard tests named `TestAgentNN_…`.

Swift (`make test-swift FILTER=…`): `AgentActionQueries` (Core, fixtures),
`AgentActionFeed` (turn interleave, CLI args for approve/reject/retry,
in-flight state, since-last-turn block), prompt tests (block present in
main/target, absent in the four draft-only VMs, honest Ollama variant),
`WatchtowerAIService.buildArgs` (chat-mode flags only for the two surfaces,
`--allowed-tools` gone), `chat_messages.turn_id` migration guard,
`SettingsToolsViewModel` suite, `AgentActionCardView` constructs.

## 14. Follow-ups

- **Runtime B (mandatory):** Go tool loop for OpenAI-compatible HTTP providers
  dispatching registry tools in-process; migrate the `internal/mcp` read tools
  into the registry then.
- Codex posture: check whether `codex exec` can disable its built-in
  shell/file tools by config; today `sandbox_mode=read-only` is the only fence.
- Mid-loop approval via claude's `--permission-prompt-tool` for `execute`-class
  tools that want a live answer.
- Link a created Jira issue onto the originating target (note or link row).
- Editable proposal cards.
- Sub-projects 2–4 as listed in §1.
