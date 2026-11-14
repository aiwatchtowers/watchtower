# Slack Live (Plan A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Slack through the user's own Claude / ChatGPT connector ("Live") works in the chat and in automations, next to the local copy, and nothing it returns becomes lasting data beyond the transcript and a run's own output.

**Architecture:** A per-team mode model (`full` from `slack_accounts`, `live` from a new `slack_live_status` table written by a real-read probe and by every real connector call) derived the same in Go and Swift. The chat gets a Slack rule in its prompt, a `coverage` object on local Slack results, connector write tools behind Approve, and Codex apps on for ChatGPT logins. A conversation that used the connector is marked `live_slack_since`; a run that used it is marked `live_slack`; every reader that makes chat text or run output lasting skips marked rows, pinned by a Go and a Swift guard.

**Tech Stack:** Go 1.26 (cobra CLI, `database/sql` on the in-repo SQLCipher driver, goose SQL migrations), SwiftUI + GRDB (WatchtowerCore), Claude Code CLI stream-json protocol, codex-cli `exec`.

**Spec:** `docs/superpowers/specs/2026-11-14-slack-full-and-live-design.md` (sections 1, 3, 4, 7–10; decisions D1, D2, D6, D10, D14, D15). Plan B (Full) covers sections 2, 5, 6.

## Global Constraints

- Mode names in UI and code: `full`, `live`, `off` (D1). The mode is derived, never stored.
- `slack_live_status.status` values: `ok`, `not_connected`, `needs_admin`, `no_plan`, `unavailable`.
- The probe makes one real read call; tool listing alone never counts as `ok` (Codex lists tools before OAuth and fails with `Unknown tool`).
- The probe never runs from the daemon on a timer.
- Connector wait: up to 15 s for `claude.ai Slack` to report `connected`.
- Of Live answers only the chat transcript is kept (D6); an automation run's own outputs are kept as its transcript (D14) and read by nothing that makes them lasting (no briefing block, ideas, memory, knowledge).
- A recipe with `slack:live` runs at most hourly; the validator refuses a tighter schedule (D15).
- Connector write tools (`slack_send_message`, `slack_schedule_message`, `slack_send_message_draft`, `slack_create_canvas`, `slack_update_canvas`, `slack_add_reaction`) are Ask; reads Allow.
- Next migration number: 00176. Mirror into `internal/db/schema.sql`, regenerate golden + Swift test schema (`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`).
- Inner loop only per task (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`, `make lint-swift` for Swift); full gate once per plan.
- Board language Russian; repo files English.

## Review Focus

1. A conversation where Live was used in turn 3 and turn 5 says "summarise everything above": turn 5 must be skipped by ideas/memory/instructions/next-step even though it called no tool — pinned in Task 4 (`TestLIVE01_LaterTurnsMarked`).
2. A Codex chat for an owner logged in with an API key (`auth_mode` ≠ `chatgpt`): apps stay off, the prompt does not promise Live — pinned in Task 3 (`TestCodexChatApps_OnlyForChatGPTLogin`).
3. A Live answer kept as an artifact: **Add to Knowledge** must be refused by the query layer too, not only the button — pinned in Task 4 (`testKeepRefusedForLiveConversation`).
4. A recipe saved with `slack:live` and a schedule `*/30 * * * *`, and one with `0 9,9 * * *`-style duplicates: the first refused, valid hourly-or-slower schedules accepted, including `0 */2 * * *` — pinned in Task 5 (`TestSlackLiveSchedule_MinimumHourly`).
5. The probe child is killed mid-run (app quits): no status row is written and no orphan stays — pinned in Task 2 (`TestLiveProbe_KilledLeavesNoRow`).

---

### Task 1: Mode model, migration and the shared fixture

**Files:**
- Create: `internal/db/migrations/00176_slack_live.sql`
- Modify: `internal/db/schema.sql` (slack_live_status; `chat_conversations.live_slack_since`; `automation_runs.live_slack`)
- Create: `internal/db/slack_live_status.go`, `internal/db/slack_live_status_test.go`
- Create: `internal/slackmode/mode.go`, `internal/slackmode/mode_test.go`, `internal/slackmode/testdata/slack_mode_cases.json`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Slack/SlackMode.swift`
- Create: `WatchtowerDesktop/Tests/Core/SlackModeFixtureTests.swift`
- Modify: `internal/db/db_test.go:170` (`expectedTables` += `slack_live_status`)
- Regenerate: schema golden, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`

**Interfaces:**
- Produces (Go):
  - `type SlackLiveStatus struct { TeamID, Provider, Status, ErrorClass string; CheckedAt time.Time }`
  - `func (d *DB) UpsertSlackLiveStatus(s SlackLiveStatus) error` — keeps the row with the newest `CheckedAt` per `(team_id, provider)`; an older write is a no-op.
  - `func (d *DB) ListSlackLiveStatus() ([]SlackLiveStatus, error)`
  - `slackmode.Mode` (`"full"|"live"|"off"`), `func Derive(full bool, live []string /*statuses*/) Mode`, `func LiveOn(statuses []string) bool` (true iff any `ok`).
- Produces (Swift): `package enum SlackMode: String { case full, live, off }`, `static func derive(full: Bool, liveStatuses: [String]) -> SlackMode`.

Migration (one `-- +goose Up`, plain `ADD COLUMN`s, no table rebuild):

```sql
CREATE TABLE slack_live_status (
  team_id TEXT NOT NULL,            -- '' = workspace not identified
  provider TEXT NOT NULL CHECK (provider IN ('claude','codex')),
  status TEXT NOT NULL CHECK (status IN ('ok','not_connected','needs_admin','no_plan','unavailable')),
  error_class TEXT NOT NULL DEFAULT '',
  checked_at TEXT NOT NULL,
  PRIMARY KEY (team_id, provider)
);
ALTER TABLE chat_conversations ADD COLUMN live_slack_since INTEGER;   -- chat_messages.id of the first Live turn, NULL = never
ALTER TABLE automation_runs ADD COLUMN live_slack INTEGER NOT NULL DEFAULT 0;
```

- [ ] **Step 1: Fixture** `internal/slackmode/testdata/slack_mode_cases.json`: cases `{full, live:[…], want}` covering: full+ok→full, full+[]→full, !full+[ok]→live, !full+[not_connected]→off, !full+[not_connected,ok]→live, !full+[]→off.
- [ ] **Step 2: Failing tests** — Go `TestSlackMode_SharedFixture` reads the fixture and asserts `Derive`; Swift `SlackModeFixtureTests.testFixtureMatchesGo` resolves the fixture like `ManagedPolicyTests.swift:15` (`#filePath` up to the repo root). `TestUpsertSlackLiveStatus_NewestWins`: write `ok@10:00`, then `not_connected@09:00` → still `ok`; then `unavailable@11:00` → `unavailable`.
- [ ] **Step 3: Run, expect FAIL** — `go test ./internal/slackmode ./internal/db -run 'SlackMode|SlackLiveStatus'`; `make test-swift FILTER=SlackModeFixtureTests`.
- [ ] **Step 4: Implement** migration, schema mirror, accessors (upsert = `INSERT … ON CONFLICT(team_id,provider) DO UPDATE … WHERE excluded.checked_at > slack_live_status.checked_at`), `Derive`, Swift twin; add table to `expectedTables`; regenerate goldens.
- [ ] **Step 5: Run, expect PASS** — same commands plus `go test ./internal/db -run 'TestAllTablesExist|TestSchemaGolden|TestDesktopTestSchema'`.
- [ ] **Step 6: Commit** `feat(slack): Full/Live mode model and slack_live_status (#1763)`.

### Task 2: The Live probe

**Files:**
- Create: `internal/slacklive/probe.go`, `internal/slacklive/classify.go`, `internal/slacklive/probe_test.go`, `internal/slacklive/testdata/` (fake CLI stubs)
- Create: `cmd/slack_live.go` (`watchtower slack live probe [--provider claude|codex] [--json]`), `cmd/slack_live_test.go`

**Interfaces:**
- Consumes: Task 1 `UpsertSlackLiveStatus`.
- Reuses: `chat.mcpStatusRequestLine` / `parseMCPStatusResponse` (`internal/chat/controlproto.go:209/247`) — export thin wrappers `chat.MCPStatusRequest(id string) string` and `chat.ParseMCPStatus(line, id string) ([]MCPServerStatus, bool)` if unexported.
- Produces:
  - `type Result struct { Provider string; Teams []string; Status, ErrorClass string }`
  - `func ProbeClaude(ctx context.Context, claudeBin string, env []string) Result`
  - `func ProbeCodex(ctx context.Context, codexBin string, env []string) Result`
  - `func Classify(provider string, stderrOrToolError string, connected bool, readOK bool) (status, errorClass string)`
  - CLI JSON (pinned keys): `{"provider","status","teams","error_class","checked_at"}`.

Behaviour:
- Claude: launch exactly the chat's shape `-p --input-format stream-json --output-format stream-json --verbose --no-session-persistence --permission-prompt-tool stdio` (no `--strict-mcp-config`); poll `mcp_status` up to 15 s for `claude.ai Slack` = `connected`; send one user message asking for one `slack_search_channels` call with limit 1; answer `can_use_tool` Allow only for `mcp__claude_ai_Slack__slack_search_channels`, Deny anything else; `readOK` = a `tool_result` without `is_error` for that tool. Team = the permalink host's first label, matched to `slack_accounts.team_domain`, else `''`.
- Codex: `codex exec --json --ephemeral --skip-git-repo-check -c approval_policy=never -c sandbox_mode=read-only -c features.apps=true` with a prompt to call `slack_list_workspaces`; `readOK` = a successful MCP tool call event; team ids from its result.
- Classification table (Classify): API-key login (`init.apiKeySource` ≠ `none`) or `auth_mode` ≠ `chatgpt` → `not_connected/api_key_login`; connector absent → `not_connected/no_connector`; `Unknown tool` → `not_connected/not_authorized`; text containing `admin` + `approv` → `needs_admin`; 429 / `rate` → `unavailable/rate_limited`; timeout → `unavailable/timeout`; plan errors → `no_plan`.
- The child runs in its own process group; `t.Cleanup` and context cancel kill the group and wait.
- On cancel / kill: no row written.

- [ ] **Step 1: Failing tests** with fake CLI stubs (shell scripts in `testdata/` emitting canned stream-json / exec JSON): `TestLiveProbe_Classifies` (table: connected+read ok → `ok`; tools listed but `Unknown tool` → `not_connected`; admin text → `needs_admin`; 429 → `unavailable`; apiKeySource `ANTHROPIC_API_KEY` → `not_connected`), `TestLiveProbe_KilledLeavesNoRow` (cancel the context while the stub sleeps; assert no row and the stub's pid is gone), `TestLiveProbe_ClaudeDeniesOtherTools` (stub requests `slack_send_message` → probe answers deny).
- [ ] **Step 2: Run, expect FAIL** — `go test ./internal/slacklive`.
- [ ] **Step 3: Implement** probe + classify + CLI; CLI writes one `UpsertSlackLiveStatus` per covered team (or `team_id=''`).
- [ ] **Step 4: Run, expect PASS** — `go test ./internal/slacklive ./cmd -run SlackLive`.
- [ ] **Step 5: Commit** `feat(slack): live probe with a real read call (#1763)`.

### Task 3: Live in the chat — policy, Codex apps, prompt, coverage, status on use

**Files:**
- Modify: `internal/chat/connectorpolicy/overrides.go` (Slack rows), `policy_test.go`
- Modify: `internal/codex/generator.go` / `client.go` (a chat-only `keep` of `apps`), `cmd/transport_wiring.go:116` (`codexSessionClient`), `internal/codex/features_test.go`
- Create: `internal/codex/chatgpt_login.go` (`func ChatGPTLogin(codexHome string) bool` — reads `auth.json`, true iff `auth_mode == "chatgpt"`)
- Modify: `internal/chat/prompt.go` / `prompt_sections.go` (Slack Live paragraph), `prompt_test.go`
- Modify: `internal/tools/messages.go` (result object with `coverage`), `internal/chat/sources.go:225` (`slackMessageSources` accepts the object), tests
- Modify: `internal/chat/claude_translate.go` + Codex event translation (status write on a Slack connector `tool_end`)

**Interfaces:**
- Consumes: Task 1 `UpsertSlackLiveStatus`, Task 2 `Classify`.
- Produces:
  - `list_messages` result: `{"messages":[…messageResult…],"coverage":{"scope":"own|none","synced_through":"<RFC3339>|","backfill_from":"<date>|","channel_in_scope":true|false|null}}`. `scope` is `own` when an enabled `ok` Slack account exists, else `none`; `channel_in_scope` only when the `channel` arg was given.
  - `chat.PromptOptions.SlackLive bool` — set when Claude.ai tools are on (Claude) or `codex.ChatGPTLogin` (Codex).

Prompt paragraph (exact text, `slackLiveBlock`):

```
Slack: answer from the local Slack tools first. Each list_messages result has a coverage object; when the question falls outside it (scope none, channel not in scope, dates after synced_through or before backfill_from), use the Slack connector's read tools for that part and say which part came from Live Slack. Never send, schedule or react through the connector without the owner's approval.
```

- [ ] **Step 1: Failing tests** — `TestPolicy_Decide` new cases: `claude_ai_Slack/slack_search_public` Allow, `slack_send_message` Ask, `slack_add_reaction` Ask, unannotated read listed in overrides Allow; `TestPolicy_OverridesAreData` covers the new rows. `TestCodexChatApps_OnlyForChatGPTLogin` (auth.json fixture `auth_mode: chatgpt` → chat args lack `features.apps=false`; `apikey` → present); `TestDisabledFeatures_MatchSnapshot` unchanged for non-chat clients. `TestBuildSystemPrompt_SlackLive` (paragraph present iff `SlackLive`). `TestListMessages_Coverage` (no account → `scope:none`; account + channel not member → `channel_in_scope:false`). `TestSlackMessageSources_ObjectShape`. `TestChatLive_StatusWrittenOnUse` (translated `tool_end` for `mcp__claude_ai_Slack__slack_read_channel` ok → `ok` row; error `Unknown tool` → `not_connected`). `TestChatLive_ConnectorErrorShown` (a failed connector call is surfaced as a step with `ok=false`, CHAT-02).
- [ ] **Step 2: Run, expect FAIL** — `go test ./internal/chat/... ./internal/codex ./internal/tools`.
- [ ] **Step 3: Implement.** Codex: pass `keep=["apps"]` to `featuresOff` only from `codexSessionClient` when `ChatGPTLogin(ownerCodexHome())`.
- [ ] **Step 4: Run, expect PASS** — same.
- [ ] **Step 5: Commit** `feat(chat): Live Slack through the owner's connector (#1764)`.

### Task 4: Live answers stay out of lasting stores (LIVE-01)

**Files:**
- Modify (Swift writer): `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatTurnStore.swift:80` (`finalizeTurn`) — in its transaction: if any `chat_turn_steps.name` of this message starts with `mcp__claude_ai_Slack__` or is a Codex Slack app call (`slack_` tool from the `slack` app), `UPDATE chat_conversations SET live_slack_since = :messageID WHERE id = :conv AND live_slack_since IS NULL`.
- Modify (Swift reader): `Database/Queries/ChatArtifactQueries.swift:77` `keep(...)` throws `ChatArtifactKeepError.liveSlack` for a marked conversation; `Services/Chat/ArtifactPanelModel.swift:131` disables the button with "Built on Live Slack answers, which are not kept".
- Modify (Go readers — add `AND (c.live_slack_since IS NULL OR m.id < c.live_slack_since)` or the conversation-level skip):
  - `internal/db/chat_knowledge.go:72` `ListChatTurnsForIdeas`
  - `internal/db/memory.go` `ListOwnerChatTurns`, `OwnerChatTurnExists`
  - `internal/db/chat.go:91` `ListOwnerChatTurnsSince` (instructions miner / coach)
  - `internal/db/chat.go:32` `ListRecentChatTurns` (target next step)
  - `internal/kb/source_chat_artifact.go` (`keptJoin` skips marked conversations)
  - `cmd/instructions.go:332` `runInstructionsRemember`: in a marked conversation store only `ParseRemember`'s line, refuse when the line quotes text not in the owner's message (it already takes only the owner's text — assert it).
- Create: `internal/db/live01_test.go` (`TestLIVE01_MarkedTurnsStayOutOfStores`, `TestLIVE01_LaterTurnsMarked`, `TestLIVE01_ReaderList`)
- Create: `WatchtowerDesktop/Tests/Core/LiveSlack01GuardTests.swift`
- Create: `docs/inventory/chat.md` entry LIVE-01 (or `docs/inventory/slack-accounts.md`), with the guard names.

**Interfaces:**
- Consumes: Task 1 column `chat_conversations.live_slack_since`.
- Produces: `package enum ChatArtifactKeepError: Error { case liveSlack }`.

Guards:
- `TestLIVE01_ReaderList`: scans `internal/**/*.go` (non-test) for SQL mentioning `chat_messages` or `chat_conversations`; each hit's function must be in `liveCheckedReaders` (checks the mark) or `displayOnlyReaders` (listed with a one-line why). A new reader fails the test.
- `LiveSlack01GuardTests.testReaderList`: same for `WatchtowerDesktop/Sources/**/*.swift` (display list: the ones in the Explore map §6; checked: `ChatArtifactQueries.keep`).

- [ ] **Step 1: Failing tests** — `TestLIVE01_MarkedTurnsStayOutOfStores` seeds a conversation with turns 1–4, `live_slack_since` = turn 3; asserts ideas/memory/instructions/next-step readers return turns 1–2 only and the kb source skips its kept artifact. `TestLIVE01_LaterTurnsMarked` (turn 4 had no steps, still skipped). Swift: `testFinalizeMarksConversationOnSlackStep`, `testFinalizeLeavesUnmarkedWithoutSlackStep`, `testKeepRefusedForLiveConversation`, `testReaderList`.
- [ ] **Step 2: Run, expect FAIL** — `go test ./internal/db ./internal/kb -run LIVE01`; `make test-swift FILTER='LiveSlack01GuardTests|ChatTurnStore'`.
- [ ] **Step 3: Implement** the Swift mark, the Go filters, the Swift refusal, the guards, the inventory entry.
- [ ] **Step 4: Run, expect PASS** — same, plus `go test ./internal/ideas ./internal/memory ./internal/instructions ./internal/coach ./internal/targets`.
- [ ] **Step 5: Commit** `feat(chat): LIVE-01 — Live Slack answers stay out of lasting stores (#1764)`.

### Task 5: Live in automations

**Files:**
- Modify: `internal/automations/manifest.go:56` (`capabilitySpecs["slack"]` gains verb `live`, unscoped — `slack:live` takes no `@scope`), `manifest_test.go`
- Modify: `internal/automations/recipe.go:523` (`parseSchedule` gets the manifest: a recipe with `slack:live` is refused when the cron fires more than once in any hour), `recipe_test.go`
- Modify: recipe save validation so `slack:live` with `trigger: event` on `slack.*` or a reaction trigger and no Full account is refused (`internal/automations/…validate`), test
- Modify: `internal/ai/client.go:350` — an opt-in stream-json input mode for agent children: `func (c *Client) SetStreamJSONInput(on bool)`; when on, args use `--input-format stream-json --output-format stream-json --verbose --permission-prompt-tool stdio` without `--strict-mcp-config`, wait ≤ 15 s for `claude.ai Slack` connected, then send the user message as a stream-json line; tools allowed = manifest set ∪ Slack connector read tools; `can_use_tool` answers deny for connector writes (they stay proposals, AUTO-02).
- Modify: `cmd/automations_backends.go:186` (`Prepare`) and `cmd/transport_wiring.go:169/182` — turn the mode on when the manifest has `slack:live`; Codex agent client keeps `apps` (same `keep` as Task 3) only then.
- Modify: `internal/db/automation_runs.go` — `func (d *DB) MarkAutomationRunLiveSlack(runID int64) error` (idempotent); the executor calls it when an `agent()` step's result reports a Slack connector call; `ListAutomationOutputsSince` (1362) skips outputs of `live_slack = 1` runs (briefing block).
- Status on use: the agent runner writes `UpsertSlackLiveStatus` like Task 3.

**Interfaces:**
- Consumes: Task 1 (`automation_runs.live_slack`, `UpsertSlackLiveStatus`), Task 2 `Classify`.
- Produces: `automations.AgentResult.UsedSlackLive bool`.

- [ ] **Step 1: Failing tests** — `TestManifest_SlackLiveParses` (`slack:live` ok; `slack:live@T1` refused); `TestSlackLiveSchedule_MinimumHourly` (`*/30 * * * *` refused, `0 * * * *` ok, `0 */2 * * *` ok, `15,45 9 * * *` refused); `TestSlackLive_EventTriggerNeedsFull`; `TestAIClient_StreamJSONInputArgs`; `TestAgentRun_MarksRunLiveSlack`; `TestBriefingAutomationBlock_SkipsLiveRuns` (`internal/briefing`).
- [ ] **Step 2: Run, expect FAIL** — `go test ./internal/automations ./internal/ai ./internal/briefing ./internal/db -run 'SlackLive|StreamJSON|LiveRuns'`.
- [ ] **Step 3: Implement.** Minimum-interval check: expand the cron over one sample week (UTC) and fail when two firings are < 60 min apart.
- [ ] **Step 4: Run, expect PASS** — same plus `go test ./cmd -run Automation`.
- [ ] **Step 5: Commit** `feat(automations): agent() with Live Slack, hourly at most (#1765)`.

### Task 6: Docs and guide

**Files:**
- Create: `docs/features/slack-live.md` (model, probe, chat, automations, LIVE-01, v1 limits: Claude Free unknown, Codex bug openai/codex#47839, no Live on the phone)
- Modify: `CLAUDE.md` feature list (one line), `docs/features/chat-claude-ai-tools.md` (Slack rows), `docs/features/automations.md` (`slack:live`)
- Modify: `docs/guide/` Slack page (what Live does, what is not kept, the hourly limit) — `go test ./docs/guide` (8 KB cap)

- [ ] **Step 1:** Write the pages.
- [ ] **Step 2:** `go test ./docs/guide`; expect PASS.
- [ ] **Step 3: Commit** `docs: Slack Live (#1764, #1765)`.

---

## Phase gate (controller, once)

`make test`, `make test-swift`, `make lint-all`; then the PR into `main` per the owner's target procedure (one agent per target in its own worktree).
