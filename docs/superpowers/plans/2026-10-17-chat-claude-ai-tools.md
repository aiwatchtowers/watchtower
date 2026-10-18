# Chat — claude.ai tools (publish + connectors) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On the Claude provider, the main AI Chat publishes private pages and docs to the owner's claude.ai account (answering with the link) and uses the account's claude.ai connectors — reads freely, writes only after the owner's Approve on an `agent_actions` card.

**Architecture:** The warm `ai session` child drops `--strict-mcp-config` and runs with `--permission-prompt-tool stdio`; the Go backend answers every `can_use_tool` control request through one gate: a pure decision table (`internal/chat/connectorpolicy`) over the connectors' own annotations, a per-conversation publish dir with lexical path confinement, and — for writes — one `claude_ai_connector_call` row the **session alone** applies (claim → allow with the approved input → record). The Desktop gains a waiting step, a "Published on claude.ai" link card, a connector-call action card and a Settings → AI connectors section fed by a 0600 sidecar file.

**Tech Stack:** Go 1.26 (cobra, `database/sql` + modernc sqlite), Claude Code stream-json control protocol (`control_request`/`control_response`), SwiftUI + GRDB (WatchtowerCore).

**Spec:** `docs/superpowers/specs/2026-10-16-chat-claude-ai-tools-design.md` (approved ask #325; Q1–Q4 decided ask #326). No migration: `agent_actions` and `chat_turn_steps` already carry everything. (Task 6 later added one: migration `00139`, `agent_actions.session_token`.)

## Global Constraints

- Only the main AI Chat (`ai session --surface main`, Claude provider) changes. `ai query` (embedded chats: meeting, idea, track, target), the daemon pipelines, automations and `mcp --workbench` keep `--strict-mcp-config` and today's tool lists (decision Q2).
- `--setting-sources project,local` and the private neutral cwd (`NeutralWorkDir()`, 0700, checked by `checkPrivateDir`) stay on every spawn (TCC guard).
- claude.ai mode is off — flags and prompt exactly as today — when any of these holds: provider ≠ claude; surface ≠ `main`; the child env carries `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX` or `CLAUDE_CODE_USE_FOUNDRY` (non-empty). Reason text: `claude.ai tools need a claude.ai login; this chat uses <an API key|Bedrock|Vertex|Foundry>.`
- Child env in claude.ai mode: `CLAUDE_CODE_ARTIFACT=1`, `CLAUDE_CODE_ARTIFACT_AUTO_OPEN=0`; plus `ENABLE_CLAUDEAI_MCP_SERVERS=0` when `ai.claude_ai.connectors` is false.
- Built-ins in claude.ai mode: `ToolSearch,WebSearch,Artifact,Write` (Edit/Read only if Task 2 shows the CLI routes them through `can_use_tool`; see Planning notes). `ArtifactComments`, `ArtifactData`, `ArtifactCheck` stay hidden.
- Approval timeout: **15 min** (`GateApprovalTimeout`); approval poll: **1 s**; connectors settle poll: **≤ 10 s**, 1 s step; orphan cutoff for other conversations' rows: **20 min**.
- Tool name: `claude_ai_connector_call` (`External: true`, `AlwaysAsk: true`, new `AppliedBySession: true`); surface `main` only.
- Publish dir: `<work dir>/publish/<conversation id>`, 0700, removed on `Close`.
- Sidecar: `<dir of the db path>/claude-ai-connectors.json`, 0600, written by temp-file + rename.
- Config keys: `ai.claude_ai.connectors` (bool, default true), `ai.claude_ai.disabled_connectors` ([]string of server display names, comma-separated on `config set`).
- Copy (UI, English): step `Waiting for your approval`; card title `Published on claude.ai`, buttons `Open in Browser`, `Copy Link`; Settings row button `Connect on claude.ai` → `https://claude.ai/customize/connectors`.
- Only `https://claude.ai/` URLs become link cards.
- Public repo hygiene: recorded fixtures are scrubbed (no account names, connector ids, emails, org names, absolute paths); use `example.com`, "Connector A".
- Task scope checks only: `go test ./internal/<pkg>` (+ the `go test ./cmd -run …` a task names), `make lint-diff`; Swift `make test-swift FILTER=…` through the shared slot. The full gate runs once per wave by the controller.
- Implementer brief checklist = `docs/review/review-rules.md` §§ named in each task; self-review before hand-back.

## Review Focus

1. **The owner approves after the call can no longer run** (turn stopped, child crashed, app quit between Approve and the claim) — the row lands `failed` ("session ended before approval"), nothing is sent, no other process ever runs it (Task 8 `TestChat05_DeadSessionNeverRunsAnApprovedCall`, Task 6 `TestAgent05_ApplyRefusesASessionCall`).
2. **Approve lands in the same second the 15-minute timeout fires** — exactly one outcome: either the call runs once or it is cancelled; never both, never neither (Task 8 `TestGate_ApproveRacingTimeoutHasOneOutcome`).
3. **A path that tries to leave the publish dir** — `../`, an absolute `~/Documents/x`, a symlink planted inside the dir, a relative path (resolved against the cwd, not the publish dir), one bad entry in an `Artifact` `files` map — denied, and no file outside the publish dir is ever stat'ed (no TCC prompt) (Task 5 table test + `TestPublishDir_NeverTouchesOutsidePaths`).
4. **A connector that appears or changes mid-session** (owner connects Gmail on claude.ai while a session is warm; a tool lost its annotation) — the gate refreshes `mcp_status` once, then classifies; a server still unknown → denied (spec D1/D3: only a listed claude.ai connector passes), a tool of a listed connector still unknown → approval card; never a silent allow (Task 9 `TestConnectors_UnknownServerRefreshesOnceThenDenies`, `TestConnectors_UnknownToolRefreshesOnceThenAsks`).
5. **Two connector writes in one turn** — two rows, two cards, each answered on its own; rejecting one does not cancel the other (Task 8 `TestGate_TwoParallelAsksAreIndependent`).

## Planning notes (deviations found while reading the code)

- `watchtower actions approve` approves **and applies** (`decideAndMaybeApply(..., execute=true)`), and the Desktop's Retry runs `actions apply`. A session-applied row must never reach `Registry.Apply`; Task 6 adds `Tool.AppliedBySession` so approve stops at `approved` and apply is refused.
- `SessionDisallowedTools` and the one-shot `DisallowedTools` share one const; Task 7 splits them so `Artifact`/`Write` leave only the claude.ai-mode session list. Spec D8 names the new allowlist `SessionBuiltinTools`; the plan keeps `SessionBuiltinTools` for the non-claude.ai session and adds `ClaudeAISessionBuiltinTools`, both approved in `TestChatBuiltins_OnlyApprovedNamesExposed`.
- D4 unhides `Read`/`Edit`: in Claude Code read-only built-ins may run **without** a permission request, so the gate would never see a `Read` of `~/Documents`. v1 exposes `Write` only; `Edit`/`Read` are added only if Task 2 records that both reach `can_use_tool` (a model can rewrite a file with `Write`).
- `Artifact` `read` without `out_dir` saves to the CLI's own folder: the gate allows it with `updatedInput.out_dir = <publish dir>`. `Artifact` `publish` with a `url` (updating an existing, possibly shared artifact) is allowed only for a URL this session published; otherwise it goes to Approve.
- A resumed conversation (`--resume`) reuses its recorded system prompt (CHAT-04), so conversations started before this ships do not get the new prompt section; the tools themselves still appear. Accepted for v1.
- A waiting turn keeps its session busy, so CHAT-03 never evicts it; decision Q3's 15 minutes is the bound on that hold.

---

## Dependencies and parallel lanes

| Task | Kind | Depends on |
|---|---|---|
| 1 Inventory amendments | docs | none |
| 2 Live CLI probe + fixtures | Go (test only) | none |
| 3 Control protocol + event contract | Go | Task 2 |
| 4 `connectorpolicy` decision table | Go | none |
| 5 Publish dir confinement | Go | none |
| 6 Session-applied tool in the registry + CLI | Go | none |
| 7 Flags, env, allowlists, availability | Go | none |
| 8 Gate runtime in the Claude backend | Go | Tasks 3, 4, 5, 7 |
| 9 Connector catalog, sidecar, switches | Go | Tasks 3, 7, 8 |
| 10 Prompt section | Go | Task 7 |
| 11 `ai session` wiring | Go | Tasks 6, 8, 9, 10 |
| 12 Swift: `tool_wait` + waiting/denied steps | Swift | Task 3 |
| 13 Swift: published link card | Swift | Task 3 |
| 14 Swift: connector-call action card | Swift | Task 6 |
| 15 Swift: Settings → AI claude.ai connectors | Swift | Task 9 |
| 16 Docs, feature note, inventory → Enforced | docs | Tasks 1–15 |
| 17 Manual check (owner ask) | owner | Task 16 |

- **Wave 1 (parallel lanes):** D = Task 1; P = Task 2 (controller; needs a claude.ai login); G1 = Task 4; G2 = Task 5; G3 = Task 6; G4 = Task 7.
- **Wave 2:** G5 = Task 3 (after P); G6 = Task 10 (after G4). Swift lane S starts: Task 12 → 13 → 14 (one Swift lane, never two).
- **Wave 3:** G7 = Task 8 → Task 9 → Task 11 (one lane: all three edit `claude_backend.go`/`ai_session.go`). S continues with Task 15 once Task 9 is merged.
- **Wave 4:** Task 16 on the merged branch, the full gate, then Task 17.

All lanes branch off and merge into `feature/737-chat-claude-ai-tools`; only that branch goes to `main`, with the owner's OK.

---

### Task 1: Inventory amendments (spec §4)

**Kind:** docs · **Depends on:** none · **Checklist:** review-rules §6, §8.

**Files:**
- Modify: `docs/inventory/chat.md` (CHAT-02, CHAT-05, Changelog)
- Modify: `docs/inventory/agent-actions.md` (AGENT-03, AGENT-05 note, Module line, Changelog)

- [ ] **Step 1:** Append the spec §4 CHAT-05 text verbatim to CHAT-05's Observable, and the CHAT-02 sentence to CHAT-02's. Add each new guard under **Guard** with the location this plan fixes, marked `(planned, #737)`:
  `TestChat05_ConnectorWriteWaitsForApproval`, `TestChat05_PublishOnlyFromThePublishDir`, `TestChat05_DeadSessionNeverRunsAnApprovedCall`, `TestChat03_CloseWhileWaitingForApprovalRejectsAndReaps` (all `internal/chat/gate_test.go`); `TestChat02_GateDecisionsAreSteps` (`internal/chat/gate_test.go`); `testChat02WaitingStepIsVisibleUntilItEnds` (`WatchtowerDesktop/Tests/Core/ChatTurnDriverTests.swift`); `testChat05PublishedLinkCardOnlyOpensOrCopies` (`WatchtowerDesktop/Tests/Core/ArtifactChat05ScanTests.swift`).
- [ ] **Step 2:** Append the spec §4 AGENT-03 sentence; add to AGENT-05's Observable: "A `claude_ai_connector_call` row (`AppliedBySession`) is never run by `Apply`: `actions approve` stops at `approved`, `actions apply` is refused, and only the live session that proposed it claims `approved → executing` (the same conditional update)." Guards `(planned, #737)`: `TestAgent03_ConnectorCallIsAlwaysAsk`, `TestAgent05_SessionCallClaimsOnce`, `TestAgent05_ApplyRefusesASessionCall` (`internal/tools/claude_ai_connector_call_test.go`), `TestActions_ApproveSessionCallDoesNotApply` (`cmd/actions_test.go`).
- [ ] **Step 3:** Changelog lines in both files: `2026-10-17 (#737): amended per spec 2026-10-16-chat-claude-ai-tools-design §4, owner approved ask #236/#325; strengthening + one stated exception, no guard relaxed.` DEV-06: no change (state it in the chat.md changelog line).
- [ ] **Step 4:** Commit `docs(inventory): CHAT-02/05, AGENT-03/05 amendments for claude.ai tools (#737)`.

### Task 2: Live CLI probe and recorded fixtures

**Kind:** Go, test only · **Depends on:** none · **Checklist:** review-rules §7 (process reaping), public-repo hygiene.

**Files:**
- Create: `internal/chat/claude_ai_live_test.go` (build tag none; skipped unless `WATCHTOWER_LIVE_CLAUDE=1`)
- Modify: `internal/chat/testdata/record_fixtures.sh`, `internal/chat/testdata/scrub_fixtures.py`
- Create (recorded, scrubbed): `internal/chat/testdata/claude_ai_init.jsonl`, `claude_ai_mcp_status.jsonl`, `claude_ai_can_use_tool.jsonl`, `claude_ai_probe.md` (one line per question below with the observed answer)

**Interfaces:** Produces the fixture files Task 3 decodes and the answers Tasks 7–9 depend on.

- [ ] **Step 1:** `TestClaudeAILive_Probe` spawns the real `claude` with the claude.ai-mode argv (no `--strict-mcp-config`, `--permission-prompt-tool stdio`, `--setting-sources project,local`, `--tools ToolSearch,WebSearch,Artifact,Write,Edit,Read`) in a fresh 0700 temp cwd, reaps the process group in `t.Cleanup`, and records answers to:
  1. the `can_use_tool` request shape — field names for request id, tool name, `tool_use_id`, `mcp_server`, input;
  2. the `mcp_status` response shape — server name/status values, tool annotations field names;
  3. do `Read` and `Edit` (path inside the cwd and outside it, outside = a path under the temp dir only) produce `can_use_tool`, or run without one;
  4. does `Write` produce `can_use_tool` for a path inside the cwd;
  5. does `Artifact` `publish`/`list` produce `can_use_tool`;
  6. does `--disallowedTools mcp__claude_ai_<Token>` hide a whole connector;
  7. the Claude Docs tools' input vocabulary for share/delete operations (from the `mcp_status` tool schemas);
  8. the deny message path: what `tool_result` text the model and stream get after a deny with a message;
  9. the `init` event's auth field (`apiKeySource` or equivalent) under the claude.ai login.
- [ ] **Step 2:** Extend `scrub_fixtures.py` to replace connector display names with `Connector A/B…`, drop ids/emails/org names, and replace absolute paths with `<tmp>`. Run `bash scripts/leak-check.sh`-equivalent over the new files (grep for `@`, `/Users/`, real names) — expect none.
- [ ] **Step 3:** The controller runs `WATCHTOWER_LIVE_CLAUDE=1 go test ./internal/chat -run TestClaudeAILive -v > probe.log 2>&1; echo "exit=$?"`. If the agent's permission classifier blocks the spawned CLI (spec F9), the controller asks the owner to run that command with `!` and attaches the log.
- [ ] **Step 4:** Commit fixtures + `claude_ai_probe.md`. Any answer that contradicts this plan (e.g. Q6 "no") is reported to the controller before Tasks 3/7/9 start.

### Task 3: Control protocol codec and the protocol-v2 event contract

**Kind:** Go · **Depends on:** Task 2 · **Checklist:** review-rules §5, §9, "Go ↔ Swift dual-path contracts".

**Files:**
- Create: `internal/chat/controlproto.go`, `internal/chat/controlproto_test.go`
- Modify: `internal/chat/events.go` (new constant + fields), `internal/chat/events_test.go`
- Create: `internal/chat/testdata/events_v2_tool_wait.jsonl` (pinned lines the Swift parser test reads)

**Interfaces — Produces:**
- `type permissionRequest struct { RequestID, ToolName, ToolUseID, DisplayName, Description, DecisionReason, MCPServer, MCPServerSource, Malformed string; Input json.RawMessage }` (as built — Task 2 probe: `mcp_server` is an object `{name, source}`, there is no `title`; `Input` is the request's input byte for byte; `policyCall()` → `connectorpolicy.Call`, see spec §3.1)
- `func parseControlRequest(line []byte) (permissionRequest, bool)` — true only for `control_request` with subtype `can_use_tool`.
- `func permissionAllowLine(requestID string, input json.RawMessage) ([]byte, error)` (as built: error unless input is a JSON object — no bare allow; a policy Allow echoes `permissionRequest.Input`, an approved call sends the approved input), `func permissionDenyLine(requestID, message string) []byte` (newline-terminated).
- As built, also: `parseControlCancel(line) (requestID string, ok bool)`, `parsePermissionDenied(line) (permissionDenied, bool)`, `toolWaitEvent(turnID, toolUseID, actionID)`, `ToolWaitMessage`, `publishedSource(url, title)`; `MCPServerStatus` also carries `Source`, `ConfigType`.
- `func mcpStatusRequestLine(requestID string) []byte`; `func parseMCPStatusResponse(line []byte, requestID string) ([]MCPServerStatus, bool, error)`.
- `type MCPServerStatus struct { Name, Status string; Tools []MCPToolInfo }`, `type MCPToolInfo struct { Name string; ReadOnly, Destructive *bool }` (nil = no annotation).
- `const EventToolWait = "tool_wait"`; `Event.ActionID int64 \`json:"action_id,omitempty"\``; a `tool_wait` carries `turn_id`, `id` (the tool_use id), `action_id`, `message`.
- `const SourceKindPublished = "claude_ai_published"` (a `Source` with `url`, `title`).

- [ ] **Step 1: Failing tests** `TestControlProto_ParsesRecordedCanUseTool` (every line of `claude_ai_can_use_tool.jsonl` decodes; tool name, tool_use id, server, input equal the recorded values), `TestControlProto_IgnoresOtherControlLines` (interrupt `control_response`, `control_cancel_request` → false), `TestControlProto_AllowDenyLinesRoundTrip` (decoded by the same JSON shape the probe recorded; deny carries the message verbatim), `TestControlProto_MCPStatusAnnotations` (recorded response → servers with nil vs set annotations), `TestEvents_ToolWaitEncodesActionID` (matches `events_v2_tool_wait.jsonl` byte for byte).
- [ ] **Step 2:** `go test ./internal/chat -run 'ControlProto|Events'` → FAIL.
- [ ] **Step 3:** Implement against the recorded field names (Task 2 Q1/Q2/Q8).
- [ ] **Step 4:** Same command → PASS; `TestChat02_ToolCallNeverWipesText` still PASS.
- [ ] **Step 5:** Commit `feat(chat): control-protocol codec and tool_wait event (#737)`.

### Task 4: `connectorpolicy` — the gate's decision table

**Kind:** Go (pure) · **Depends on:** none · **Checklist:** review-rules §2, §6, §9 (security: fail closed).

**Files:**
- Create: `internal/chat/connectorpolicy/policy.go`, `overrides.go` (data rows only), `policy_test.go`

**Interfaces — Produces:**
- `type Verdict int` with `Allow`, `Ask`, `Deny`; `type Decision struct { Verdict Verdict; Reason string; UpdatedInput json.RawMessage }` (UpdatedInput nil = unchanged).
- `type Call struct { Tool string /* raw CLI name, e.g. mcp__claude_ai_Gmail__send or Artifact */; Server string /* can_use_tool mcp_server, "" for built-ins */; Input json.RawMessage }`
- `type Annotations struct { ReadOnly, Destructive *bool }`
- `type Catalog interface { Lookup(serverToken, tool string) (Annotations, bool) }`
- `type Policy struct { Catalog Catalog; Disabled map[string]bool /* server tokens */; PathCheck func(path string) error; PublishDir string; OwnArtifact func(url string) bool }`
- `func (p Policy) Decide(c Call) Decision`
- `func ServerToken(displayName string) string` — the CLI's `mcp__<token>__` mapping (`claude.ai Claude Docs` → `claude_ai_Claude_Docs`; every non-`[A-Za-z0-9_-]` rune → `_`); `func ParseToolName(raw string) (serverToken, tool string, ok bool)`.

Rules, first match wins (spec D3, decision Q1):
1. Built-in `Write` (and `Edit`/`Read` if exposed): every path field through `PathCheck` → Allow, else Deny `"<tool> may only write inside <PublishDir>"`.
2. `Artifact`: action omitted or `publish` → every local source (`file_path`, `file_paths[]`, each `files` value's string or `from`, `root`) through `PathCheck`; no `url` or `OwnArtifact(url)` → Allow; `url` of another artifact, or `force: true` → Ask. `read` → `out_dir` absent → Allow with `UpdatedInput` setting `out_dir` = PublishDir; present and inside → Allow; outside → Deny. `list`, `open`, `quickstart` → Allow. `delete`, `pin`, `unpin` → Ask. Any other action → Deny.
3. Not a `mcp__claude_ai_…` tool → Deny `"<tool> is not available in this chat"`.
4. Server token in `Disabled` → Deny `"<server> is switched off in Settings → AI"`.
5. Tool `authenticate` / `complete_authentication` → Deny `"connect <server> on claude.ai first"`.
6. Override row for (server token pattern, tool) → its verdict (Claude Docs: `create`/`update`/`batch`/`read`/`query`/`guide` → Allow unless the input contains a share/delete operation per Task 2 Q7 → Ask; `delete` → Ask).
7. Catalog annotation `ReadOnly == true` and `Destructive != true` → Allow.
8. Everything else (write, destructive, no annotation, unknown to the catalog) → Ask.

- [ ] **Step 1: Failing tests** — one table test `TestPolicy_Decide` with a row per rule above (incl. `Artifact` with no `action`, `files` map with one outside entry → Deny, `read` without `out_dir` → Allow + UpdatedInput.out_dir, `url` of an own vs foreign artifact), `TestPolicy_OverridesAreData` (every `overrides.go` row has a non-empty Why and a test row), `TestServerToken_Mapping` (`claude.ai Claude Docs`, `claude.ai Google Calendar`, a name with `.`/unicode), `TestParseToolName` (bad inputs → ok=false), `TestPolicy_UnknownCatalogEntryAsks`.
- [ ] **Step 2:** `go test ./internal/chat/connectorpolicy` → FAIL. **Step 3:** implement. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(chat): connector gate decision table (#737)`.

### Task 5: Publish dir and path confinement

**Kind:** Go · **Depends on:** none · **Checklist:** review-rules §9 (security), TCC rules in `internal/chat/claude_backend.go` work-dir comments.

**Files:**
- Create: `internal/chat/publishdir.go`, `internal/chat/publishdir_test.go`

**Interfaces — Produces:**
- `type PublishDir struct{ … }`; `func NewPublishDir(workDir string, conversationID int64) (*PublishDir, error)` — creates `<workDir>/publish/<id>` 0700 (parents 0700), refuses a symlink or foreign-owned dir (`*WorkDirError`).
- `func (d *PublishDir) Path() string`; `func (d *PublishDir) Check(p string) error`; `func (d *PublishDir) Remove() error`.

`Check` order (no file outside the dir is ever touched): a relative `p` is joined to `workDir` (the CLI's cwd), not to the dir; `filepath.Clean`; must have the dir as a strict prefix (`dir + "/"`) — else refuse **without any syscall**; then `Lstat` each existing component from the dir downward — a symlink anywhere refuses; a missing tail is fine (Write creates it).

- [ ] **Step 1: Failing tests** — `TestPublishDir_Check` table (inside; nested new path; `../x`; absolute `/tmp/...` outside; relative `publish/<id>/a.html` → inside; relative `a.html` → outside; symlink inside pointing out; the dir itself), `TestPublishDir_NeverTouchesOutsidePaths` (an outside path whose parent is a 0000 dir: Check still returns the outside error, not a permission error), `TestPublishDir_CreatedPrivate` (0700, refuses a pre-planted symlink at `publish/<id>`), `TestPublishDir_RemoveOnlyOwnConversation` (two ids; removing one leaves the other).
- [ ] **Step 2:** `go test ./internal/chat -run PublishDir` → FAIL. **Step 3:** implement. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(chat): per-conversation publish dir (#737)`.

### Task 6: Session-applied connector call in the registry and the CLI

**Kind:** Go · **Depends on:** none · **Checklist:** review-rules §6, §7, §8; `docs/inventory/agent-actions.md` AGENT-01/03/05/07 (read before editing). Extra packages to run: `go test ./internal/tools ./internal/mcp` and `go test ./cmd -run 'Actions|Agent0'`.

**Files:**
- Modify: `internal/tools/registry.go` (field, `List`, `Apply`, new methods)
- Create: `internal/tools/claude_ai_connector_call.go`, `internal/tools/claude_ai_connector_call_test.go`
- Modify: `cmd/actions.go`, `cmd/actions_test.go`, `cmd/actions_registry.go` (register the tool)

**Interfaces — Produces:**
- `Tool.AppliedBySession bool` — never listed by `Registry.List` (no MCP surface ever offers it), `Execute` never called, `Apply` refuses it with `ErrSessionApplied` **before** the claim.
- `func NewClaudeAIConnectorCall() *Tool` — name `claude_ai_connector_call`, `External`, `AlwaysAsk`, `AppliedBySession`, `Surfaces: [main]`; schema `{server: string, tool: string, input: object, reason: string}` (all required); `Revise` accepts patch `{"input": {…}}` (object only, replaces `input`).
- `func (r *Registry) ClaimSessionCall(id int64) (*db.AgentAction, bool, error)` — `approved → executing` conditional update; false when not approved.
- `func (r *Registry) FinishSessionCall(id int64, resultJSON string, callErr string) error` — `executing → applied` (callErr "") or `failed`.
- `func (r *Registry) CancelSessionCall(id int64, reason string) (bool, error)` — `pending|approved → rejected`, error = reason.
- `func (r *Registry) ExpireSessionCalls(conversationID int64, staleBefore time.Time) (int, error)` — every `pending|approved|executing` row of an `AppliedBySession` tool in that conversation, plus such rows of any conversation created before `staleBefore`, → `failed` with error `session ended before approval` (`executing` rows: `session ended while the call ran; outcome unknown`).
- `actions approve` on such a row: approves, does not apply, prints/returns status `approved` (`--json` keys unchanged); `actions apply [--force]` on it: refused, exit non-zero, `"claude_ai_connector_call runs only in the chat session that proposed it"`.

- [ ] **Step 1: Failing tests** — `TestAgent03_ConnectorCallIsAlwaysAsk` (SetTrust execute refused on every surface; Propose with a planted `execute` trust row still pending), `TestAgent05_SessionCallClaimsOnce` (two goroutines claim; exactly one true), `TestAgent05_ApplyRefusesASessionCall` (approved row: `Apply` → `ErrSessionApplied`, row still `approved`, Execute stub never called), `TestSessionCall_CancelOnlyFromPendingOrApproved`, `TestSessionCall_ExpireLandsFailed` (own conversation any age; other conversation only when older than the cutoff; applied/rejected rows untouched), `TestSessionCall_ReviseReplacesInput` (non-object patch → ValidationError), `TestRegistry_ListNeverOffersSessionCalls` (every surface); cmd: `TestActions_ApproveSessionCallDoesNotApply`, `TestActions_ApplySessionCallRefused` (with and without `--force`). Existing `TestAgent07_CLIApproveRefusedUnderAgent` stays green unchanged.
- [ ] **Step 2:** run the named packages → FAIL. **Step 3:** implement. **Step 4:** PASS, plus `go test ./internal/tools ./internal/mcp` all green.
- [ ] **Step 5:** Commit `feat(tools): session-applied claude_ai_connector_call (#737)`.

### Task 7: Flags, env, allowlists and claude.ai availability

**Kind:** Go · **Depends on:** none · **Checklist:** review-rules §8, §9; CHAT-04 guards. Extra: `go test ./internal/ai ./internal/chat`.

**Files:**
- Modify: `internal/ai/client.go` (consts), `internal/ai/builtin_tools_test.go`
- Modify: `internal/chat/claude_backend.go` (`ClaudeOptions`, `claudeArgs`, child env), `internal/chat/claude_backend_test.go`
- Create: `internal/chat/claudeai.go`, `internal/chat/claudeai_test.go`

**Interfaces — Produces:**
- `ai.ClaudeAISessionBuiltinTools = SessionBuiltinTools + ",Artifact,Write"` (Task 2 Q3 may add `Edit,Read`); `ai.ClaudeAISessionDisallowedTools` = `SessionDisallowedTools` minus exactly those names. `ai.DisallowedTools` (one-shot) and `ai.SessionDisallowedTools` keep `Artifact`, `Write`, `Edit`, `Read`.
- `ClaudeOptions.ClaudeAI ClaudeAIMode` with `type ClaudeAIMode struct { On bool; Connectors bool }`. On → no `--strict-mcp-config`, `--permission-prompt-tool stdio`, env `CLAUDE_CODE_ARTIFACT=1`, `CLAUDE_CODE_ARTIFACT_AUTO_OPEN=0`, and `ENABLE_CLAUDEAI_MCP_SERVERS=0` when `!Connectors`. Off → argv byte-identical to today.
- `func ClaudeAIAvailability(env []string, provider, surface string) (on bool, reason string)` — the Global Constraints rules and reason text.

- [ ] **Step 1: Failing tests** — `TestChatBuiltins_OnlyApprovedNamesExposed` gains the approved `ClaudeAISessionBuiltinTools` set (the approval is spec D8); `TestChatClaudeAI_OneShotKeepsStrictMCPConfig` (one-shot `buildArgs` still has `--strict-mcp-config`, no `--permission-prompt-tool`, `Artifact` hidden); `TestClaudeArgs_ClaudeAIModeDropsStrictAndAddsGate`; `TestClaudeArgs_OffIsUnchanged` (golden argv equal to today's); `TestClaudeEnv_ClaudeAIMode` (three env values; connectors off adds the fourth); `TestClaudeAIAvailability` table (each env marker, codex, ollama, surface target, all clear). Existing `TestChat04_ClaudeArgvCarriesNoContent`, `TestChat04_ClaudeArgsOnResume` run with the mode on and stay green.
- [ ] **Step 2:** FAIL. **Step 3:** implement. **Step 4:** PASS (`go test ./internal/ai ./internal/chat`).
- [ ] **Step 5:** Commit `feat(chat): claude.ai session flags and availability (#737)`.

### Task 8: The gate runtime in the Claude backend

**Kind:** Go · **Depends on:** Tasks 3, 4, 5, 7 · **Checklist:** review-rules §7 (races, process reaping), §8, §9; CHAT-01..05, AGENT-05. Run `go test -race ./internal/chat -run 'Gate|Chat0'` once at the end.

**Files:**
- Create: `internal/chat/gate.go`, `internal/chat/gate_test.go`
- Modify: `internal/chat/claude_backend.go` (reader routes `can_use_tool`; `Cancel`/`Close`/`Start` hooks), `internal/chat/claude_translate.go` (published link source), `internal/chat/testdata/fake_claude.sh` (new `gate` mode: emits a scripted `control_request` from `FAKE_CLAUDE_GATE_REQUESTS`, waits for the matching `control_response` on stdin, then emits the tool_result the probe recorded for allow/deny)

**Interfaces — Consumes:** Task 3 codec; Task 4 `Policy.Decide`; Task 5 `PublishDir`. **Produces:**
- `type ActionSink interface { ProposeConnectorCall(ctx context.Context, c ConnectorCall) (int64, error); ActionStatus(ctx context.Context, id int64) (string, error); ClaimApproved(ctx context.Context, id int64) (json.RawMessage, bool, error); FinishCall(ctx context.Context, id int64, result, callErr string) error; CancelCall(ctx context.Context, id int64, reason string) (bool, error); ExpireOrphans(ctx context.Context) error }`
- `type ConnectorCall struct { TurnID, Server, Tool, Reason string; Input json.RawMessage }` (Reason = the request's display_name, else description, else `claude.ai connector write` — the protocol has no title, Task 3).
- `ClaudeOptions.Gate *GateOptions`, `type GateOptions struct { Sink ActionSink; Publish *PublishDir; Policy connectorpolicy.Policy; ApprovalTimeout, PollInterval time.Duration; Now func() time.Time }` (defaults 15 min, 1 s, `time.Now`).
- `const GateApprovalTimeout = 15 * time.Minute`.

Behaviour:
- The reader hands each `can_use_tool` to the gate on its own goroutine (the reader never blocks on a decision). Allow/Deny answer at once (Allow with `UpdatedInput` when the policy set one).
- Ask: `ProposeConnectorCall` → emit `tool_wait{turn_id, id: tool_use_id, action_id, message: "Waiting for your approval"}` → poll `ActionStatus` every PollInterval: `approved` → `ClaimApproved` → allow with `updatedInput` = the approved input; `rejected` → deny `The owner rejected this call. Do not retry it; say it was not sent.`; timeout → `CancelCall(id, "not approved within 15 minutes")` — true → deny `The owner did not approve within 15 minutes, so it was cancelled. Tell the owner it was not sent.`; false (approved meanwhile) → claim path. A propose error → deny with the error text.
- The tool_result for a claimed call's tool_use id → `FinishCall(id, result text, "" | error text)` exactly once.
- `Cancel` and `Close` first cancel every waiting call (`CancelCall(id, "stopped")`) and deny it, then interrupt/close as today. `Start` calls `ExpireOrphans` before the first spawn.
- A successful `Artifact` publish tool_end gets a `Source{Kind: SourceKindPublished, URL, Title}` for the first `https://claude.ai/…artifact/…` URL in its result; the gate records that URL as the session's own (`Policy.OwnArtifact`).
- Gate off (`Gate == nil`) → no behaviour change; a `can_use_tool` then gets deny `not available in this chat` (fail closed).

- [ ] **Step 1: Failing tests** (fake CLI `gate` mode + a fake `ActionSink` with a controllable clock):
  - `TestChat05_ConnectorWriteWaitsForApproval` — a write request: a row is proposed, `tool_wait` is emitted, no `control_response` is written while the row is pending; after approve with an owner-edited input, exactly one allow carrying the edited input; `FinishCall` once with the tool result.
  - `TestChat05_PublishOnlyFromThePublishDir` — `Artifact` publish with `file_path` outside → deny with reason, no row; inside → allow, no row; `Write` outside → deny.
  - `TestChat05_DeadSessionNeverRunsAnApprovedCall` — child killed while waiting; row approved afterwards; a new backend's `Start` calls `ExpireOrphans` before spawning; no allow line is ever written by either child; `ClaimApproved` on the row returns false.
  - `TestChat02_GateDecisionsAreSteps` — a denied call ends as `tool_end ok=false` whose summary contains the gate's reason; an asked call emits `tool_wait` after `tool_start` and before `tool_end`; no event is ever `reset`.
  - `TestChat03_CloseWhileWaitingForApprovalRejectsAndReaps` — `Close` during a wait: row `rejected` ("stopped"), child and group reaped (existing `assertNoProcessSurvives`).
  - `TestGate_TimeoutCancelsAndTellsTheModel` (timeout 50 ms), `TestGate_ApproveRacingTimeoutHasOneOutcome` (approve lands between timeout and CancelCall: one allow, no cancel), `TestGate_TwoParallelAsksAreIndependent`, `TestGate_StopDeniesWaitingCall`, `TestGate_ReadOnlyConnectorCallWritesNoRow`, `TestGate_OffDeniesEveryRequest`, `TestTranslate_PublishedLinkSourceOnlyForClaudeAIURLs` (an `https://example.com/…` URL → no source).
- [ ] **Step 2:** `go test ./internal/chat -run 'Gate|Chat0|Translate'` → FAIL. **Step 3:** implement. **Step 4:** PASS; all existing `TestChat0*` green; `-race` run once.
- [ ] **Step 5:** Commit `feat(chat): permission gate for claude.ai tools (#737)`.

### Task 9: Connector catalog, sidecar file and the Settings switches

**Kind:** Go · **Depends on:** Tasks 3, 7, 8 · **Checklist:** review-rules §5, §9, "Go ↔ Swift dual-path contracts". Extra: `go test ./internal/config ./cmd -run Config`.

**Files:**
- Create: `internal/chat/connectors.go`, `internal/chat/connectors_test.go`, `internal/chat/testdata/claude_ai_connectors.json` (the pinned sidecar fixture Swift decodes)
- Modify: `internal/chat/gate.go` (catalog refresh), `internal/chat/claude_backend.go` (`Start` sends `mcp_status`)
- Modify: `internal/config/config.go` (`AIConfig.ClaudeAI ClaudeAIConfig{Connectors bool; DisabledConnectors []string}`, default `Connectors: true`), `cmd/config.go` (`knownConfigKeys`), their tests

**Interfaces — Produces:**
- `type ConnectorSnapshot struct { UpdatedAt time.Time; Available bool; UnavailableReason string; Servers []MCPServerStatus }` implementing `connectorpolicy.Catalog` (keyed by `ServerToken`).
- `func WriteConnectorsFile(path string, s ConnectorSnapshot) error` (0600, temp + rename); `func ReadConnectorsFile(path string) (ConnectorSnapshot, error)` (missing file = empty snapshot, no error).
- Sidecar JSON (pinned by the fixture): `{"updated_at": RFC3339, "available": bool, "unavailable_reason": string, "servers": [{"name", "status" ∈ connected|needs-auth|failed|pending|disabled, "tools": [{"name", "read_only"?, "destructive"?}]}]}`.
- `func DisabledToolTokens(disabled []string, last ConnectorSnapshot) []string` — `mcp__<token>` per disabled server (if Task 2 Q6 = yes; else per-tool tokens from `last`), plus `mcp__<token>__authenticate` / `__complete_authentication` for every server in `last`.
- `ClaudeOptions.ConnectorsFile string`; `GateOptions` gets the live snapshot.

Behaviour: after spawn in claude.ai mode, send `mcp_status`; re-send every 1 s for ≤ 10 s while any claude.ai server is `pending`; store the snapshot, mark disabled servers `disabled`, write the sidecar. A `can_use_tool` for a server token not in the snapshot triggers one refresh (≤ 2 s) before the policy decides. Hiding is convenience; the gate's `Disabled` rule is the enforcement. Unavailable mode (Task 7 reason) writes `available: false` with the reason and no servers.

- [ ] **Step 1: Failing tests** — `TestConnectors_SnapshotWaitsForPendingUpTo10s` (fake CLI answers `pending` twice then `connected`; injected clock), `TestConnectors_GivesUpAfter10s` (still pending → written as pending, chat goes on), `TestConnectors_SidecarIs0600AndAtomic`, `TestConnectors_FixtureRoundTrips`, `TestConnectors_DisabledToolTokens`, `TestConnectors_UnknownServerRefreshesOnceThenAsks`, `TestConnectors_UnavailableWritesReason`, `TestConfig_ClaudeAIDefaultsAndCSV` (`config set ai.claude_ai.disabled_connectors "Connector A,Connector B"` → two entries; unset → connectors on, none disabled).
- [ ] **Step 2:** FAIL. **Step 3:** implement. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(chat): claude.ai connector catalog and sidecar (#737)`.

### Task 10: System prompt section

**Kind:** Go · **Depends on:** Task 7 · **Checklist:** `.claude/skills/add-ai-prompt` (both providers), review-rules §6, "The assistant & chat contracts".

**Files:**
- Modify: `internal/chat/prompt.go` (`PromptOptions.ClaudeAI ClaudeAIPrompt`), `internal/chat/prompt_sections.go` (new block), `internal/chat/prompt_test.go`, `internal/chat/testdata/system_prompt_main.golden`

**Interfaces — Produces:** `type ClaudeAIPrompt struct { Kind ClaudeAIPromptKind; PublishDir, Reason string }`, kinds `ClaudeAIPromptNone` (today's prompt), `ClaudeAIPromptOn`, `ClaudeAIPromptOtherProvider`, `ClaudeAIPromptUnavailable`.

Section content (On), each pinned by a `Contains` assertion: it can publish private pages, decks and docs to the owner's claude.ai account with the `Artifact` tool and Claude Docs, writing the source file only inside `<PublishDir>`; after publishing it answers with the link; it never tells the owner to paste a prompt into claude.ai; it can read through the owner's claude.ai connectors; a connector write (send, create, edit, post, share, delete) is a proposal that waits for the owner's Approve — never say it was sent until the step finished; a denied or cancelled call is reported as not done. OtherProvider: one line `Publishing to claude.ai and claude.ai connectors need the Claude provider; use the in-app artifact instead.` Unavailable: one line with `Reason`. The `ArtifactsContract()` text is not edited (`TestChat05_ContractSaysArtifactsNeverSend` unchanged).

- [ ] **Step 1: Failing tests** — `TestPrompt_ClaudeAISectionOnlyWhenOn` (None → golden unchanged), `TestPrompt_ClaudeAISectionPinsRules`, `TestPrompt_OtherProviderLine`, `TestPrompt_UnavailableLine`; `TestBuildSystemPrompt_SectionsAndOrder` updated for the new position (after the tools sections, before `ArtifactsContract`).
- [ ] **Step 2:** FAIL. **Step 3:** implement; regenerate the golden. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(chat): prompt section for claude.ai tools (#737)`.

### Task 11: `ai session` wiring

**Kind:** Go · **Depends on:** Tasks 6, 8, 9, 10 · **Checklist:** review-rules §5, §8; CHAT-04 Swift-side argv unchanged (no new `ai session` flag). Run `go test ./cmd -run 'AISession|ClaudeSession|NewSessionBackend|Actions'`.

**Files:**
- Modify: `cmd/ai_session.go`, `cmd/ai_session_test.go`
- Create: `cmd/ai_session_gate.go` (the `ActionSink` adapter over `tools.Registry`)

**Interfaces — Consumes:** Task 6 registry methods, Task 7 `ClaudeAIAvailability`/`ClaudeAIMode`, Task 8 `ActionSink`/`GateOptions`, Task 9 `ConnectorsFile`/`DisabledToolTokens`/config, Task 10 `ClaudeAIPrompt`. **Produces:** `type registrySink struct{…}` implementing `chat.ActionSink` with binding `{Surface: main, ConversationID, ContextType, ContextID, TurnID}`; `ExpireOrphans` = `ExpireSessionCalls(conv, now − 20 min)`.

Wiring: `sessionPromptOptions` sets `ClaudeAI` (On for claude+main+available, OtherProvider for codex/ollama, Unavailable with the reason); `claudeSessionOptions` sets `ClaudeAI`, `Tools`/`DisallowedTools` from the claude.ai-mode consts plus `DisabledToolTokens`, `Gate` (sink, `NewPublishDir(NeutralWorkDir(), conv.ID)`, policy), `ConnectorsFile = filepath.Join(filepath.Dir(dbPath), "claude-ai-connectors.json")`. Codex/Ollama backends: prompt line only.

- [ ] **Step 1: Failing tests** — `TestClaudeSessionOptions_ClaudeAIModeWiring`, `TestClaudeSessionOptions_APIKeyEnvTurnsClaudeAIOff` (argv equals today's), `TestAISession_PromptOptionsClaudeAIByProvider` (claude main → On; target surface → None; codex/ollama → OtherProvider), `TestAISession_RegistrySinkBindsConversationAndTurn`, `TestAISession_EndToEndWithFakeClaude` and `TestClaudeSessionOptions_QC02PerToolAllowlist` unchanged and green.
- [ ] **Step 2:** FAIL. **Step 3:** implement. **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(cmd): wire claude.ai tools into ai session (#737)`.

### Task 12: Swift — `tool_wait`, waiting and denied steps

**Kind:** Swift (WatchtowerCore) · **Depends on:** Task 3 · **Checklist:** review-rules "Swift / Desktop conventions" (Lifecycle & state, Go ↔ Swift dual-path, Tests), CHAT-01/02.

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatEvent.swift`, `LiveTurn.swift`, `ChatTurnDriver.swift`; `WatchtowerDesktop/Sources/Views/Chat/StepsBlockView.swift`
- Test: `WatchtowerDesktop/Tests/Core/ChatEventTests.swift`, `WatchtowerDesktop/Tests/Core/ChatTurnDriverTests.swift`

**Interfaces — Produces:** `ChatEvent.toolWait(ChatToolWait)`, `struct ChatToolWait { turnID, id: String; actionID: Int64; message: String }`; a live step state `waiting(actionID:)` cleared by its `tool_end`. Waiting is live-only (the durable state is the `agent_actions` row); `chat_turn_steps` writes are unchanged.

- [ ] **Step 1: Failing tests** — `testChatEventParsesToolWait` (reads `internal/chat/testdata/events_v2_tool_wait.jsonl`), `testChatEventUnknownTypeStillNil`, `testChat02WaitingStepIsVisibleUntilItEnds` (start → wait → step shows `Waiting for your approval`; end ok=false → red step with the summary; end ok=true → normal step), `testWaitingStepSurvivesNavigation` (state lives on the driver, not the view).
- [ ] **Step 2:** `swift-slot.sh <lane> make test-swift FILTER='ChatEventTests|ChatTurnDriverTests'` → FAIL. **Step 3:** implement. **Step 4:** PASS; existing `testChat02ToolStepsArePersistedImmediately` green.
- [ ] **Step 5:** Commit `feat(desktop): waiting and denied chat steps (#737)`.

### Task 13: Swift — "Published on claude.ai" link card

**Kind:** Swift · **Depends on:** Task 3 · **Checklist:** "Swift / Desktop conventions", CHAT-05 (read `ArtifactChat05ScanTests` first).

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/PublishedLink.swift`, `WatchtowerDesktop/Sources/Views/Chat/PublishedLinkCardView.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Chat/ChatMessageRow.swift` (render cards for the turn's published sources)
- Test: `WatchtowerDesktop/Tests/Core/PublishedLinkTests.swift`, `WatchtowerDesktop/Tests/Core/ArtifactChat05ScanTests.swift`

**Interfaces — Produces:** `struct PublishedLink { title: String; url: URL; static func links(from sources: [ChatSource]) -> [PublishedLink] }` — only `kind == "claude_ai_published"` with scheme `https` and host `claude.ai`; `enum PublishedLinkAction { case open(URL), copy(String) }`.

- [ ] **Step 1: Failing tests** — `testPublishedLinkOnlyForClaudeAIHTTPS` (http, other host, `claude.ai.example.com`, missing URL → none), `testPublishedLinkActionsOnlyOpenOrCopy`, `testChat05PublishedLinkCardOnlyOpensOrCopies` (the scan's file list gains the two new files; same forbidden-reference list).
- [ ] **Step 2:** FAIL. **Step 3:** implement (`NSWorkspace.shared.open`, `NSPasteboard` in the view's action performer only). **Step 4:** PASS; `testChat05ArtifactSurfacesNeverWrite` green.
- [ ] **Step 5:** Commit `feat(desktop): published-on-claude.ai link card (#737)`.

### Task 14: Swift — connector-call action card

**Kind:** Swift · **Depends on:** Task 6 · **Checklist:** "Swift / Desktop conventions", AGENT-07 (`--args-sha256` on every approve), "The assistant & chat contracts".

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/ConnectorCallProposal.swift`, `WatchtowerDesktop/Sources/Views/Chat/AgentActionCardView+Connector.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Chat/AgentActionCardView.swift` (dispatch by tool; Retry hidden for session calls)
- Test: `WatchtowerDesktop/Tests/Core/ConnectorCallProposalTests.swift`

**Interfaces — Produces:** `struct ConnectorCallProposal { static let tool = "claude_ai_connector_call"; server, toolName: String; inputJSON: String; init?(action: AgentAction); func patch(editedInput: String) -> String? /* nil when not a JSON object */ }`; `static func statusLabel(for: AgentAction) -> String` — `approved` → `Approved — the chat is running it`, `rejected` with error `not approved within 15 minutes` → `Cancelled — not approved in time`, `rejected` `stopped` → `Cancelled — chat stopped`, `failed` → `Failed` + the row error.

- [ ] **Step 1: Failing tests** — `testConnectorProposalParsesArgs`, `testConnectorProposalPatchNeedsAnObject`, `testConnectorStatusLabels`, `testSessionCallsOfferNoRetry`, `testApproveCarriesArgsDigest` (approve goes through `AgentActionFeed.approve(_:shownArgs:patch:)`).
- [ ] **Step 2:** FAIL. **Step 3:** implement (input shown pretty-printed; Edit opens a monospaced editor, Approve disabled while the text is not a JSON object). **Step 4:** PASS.
- [ ] **Step 5:** Commit `feat(desktop): claude.ai connector-call approval card (#737)`.

### Task 15: Swift — Settings → AI claude.ai connectors

**Kind:** Swift · **Depends on:** Task 9 · **Checklist:** "Swift / Desktop conventions" (Lifecycle & state, Error handling), CHAT-03 (read the pool guards first). Update `docs/app-guide.md` in this task.

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ClaudeAIConnectorsFile.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ClaudeAIConnectorsModel.swift`, `WatchtowerDesktop/Sources/Views/Settings/ClaudeAIConnectorsSection.swift`
- Modify: the Settings AI tab host (where `AssistantToolsSettingsSection` is placed), `WatchtowerDesktop/Sources/Services/Chat/ChatSessionPool.swift` (`retireIdleSessions()` if absent: closes idle sessions now, busy ones after their turn)
- Test: `WatchtowerDesktop/Tests/Core/ClaudeAIConnectorsFileTests.swift`, `ClaudeAIConnectorsModelTests.swift`, `WatchtowerDesktop/Tests/ChatSessionPoolTests.swift`

**Interfaces — Produces:** `struct ClaudeAIConnectorsFile: Decodable` (decodes `internal/chat/testdata/claude_ai_connectors.json`); `@MainActor final class ClaudeAIConnectorsModel` (owned by `AppState`, not the view): `servers`, `setAllEnabled(Bool)`, `setEnabled(name:, Bool)` → `config set ai.claude_ai.connectors` / `ai.claude_ai.disabled_connectors <sorted csv>` → `ChatSessionPool.retireIdleSessions()`; a failed write keeps the old state and sets `lastError`.

UI: unavailable → one line with the reason; `needs-auth` → `Connect on claude.ai`; each row name + status + switch (default on).

- [ ] **Step 1: Failing tests** — `testConnectorsFileDecodesGoFixture`, `testConnectorsFileMissingIsEmpty`, `testToggleWritesSortedCSVAndRetires`, `testFailedWriteKeepsStateAndReports`, `testChatPoolRetireIdleKeepsBusySessions` (CHAT-03 guards unchanged and green).
- [ ] **Step 2:** FAIL. **Step 3:** implement. **Step 4:** PASS; `make lint-swift` through the slot.
- [ ] **Step 5:** Commit `feat(desktop): Settings → AI claude.ai connectors (#737)`.

### Task 16: Docs, feature note, inventory status

**Kind:** docs · **Depends on:** Tasks 1–15 · **Checklist:** review-rules §6; `feedback`: app guide kept current.

**Files:**
- Create: `docs/features/chat-claude-ai-tools.md` (architecture, gate table, session-applied rows, sidecar contract, v1 limits incl. the resume note)
- Modify: `CLAUDE.md` (Feature Notes link), `docs/features/chat-redesign.md` (pointer), `docs/inventory/chat.md` + `agent-actions.md` (drop `(planned, #737)`, Status stays Enforced, guard locations verified by `grep`)

- [ ] **Step 1:** Write the note; verify every guard name in the inventory exists: `grep -rn '<name>' internal cmd WatchtowerDesktop/Tests` per name → one hit each.
- [ ] **Step 2:** Controller runs the full gate: `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...` — each to a log with `exit=$?`.
- [ ] **Step 3:** Commit `docs: claude.ai tools in the chat (#737)`.

### Task 17: Manual check (owner, via an ask)

**Kind:** owner · **Depends on:** Task 16.

The controller builds the dev app (`make app-dev`, not under a running Watchtower) and asks the owner to check, each as ok / not ok / skipped:

1. Ask the chat for a deck about X → a "Published on claude.ai" card; the link opens; the page is private.
2. Ask it to find a Gmail thread → a read step, the right content, no card.
3. Ask it to send a mail → the approval card shows exactly what will be sent; Approve sends it once (check Sent).
4. Ask for a second mail → Reject → nothing sent, the chat says so.
5. Ask for a third mail → press Stop while the card waits → nothing sent, the card says Cancelled.
6. Switch one connector off in Settings → AI → the next turn cannot use it (the chat says it is off).
7. A connector in `needs-auth` shows `Connect on claude.ai`.
8. No macOS permission dialog (Documents, Desktop, Downloads, Photos…) during all of the above, including when the chat is asked to save a file to `~/Documents` (it is denied).
9. The session started by the Desktop app (not a terminal) reaches the connectors (spec F9).
10. A Codex chat asked for a deck says publishing needs the Claude provider and offers the in-app artifact.
