# Automations P6 (mcp, agent, templates) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The last three SDK capabilities and the gallery: `mcp(server, tool, args)` — a Go-side call to an enabled Quick Connection, read-only per QC-02; `agent(instruction, {tools, budget, tier})` — a bounded tool loop per decision D3 (the `claude`/`codex` CLI providers get a headless process whose chat-mode MCP server is bound to `--surface automation --automation-run N`, the effective tool set and the run env marker; ollama gets the runtime-B loop); and the five gallery templates of spec §15 with `automations templates` / `install-template`. Budgets are in tokens.

**Architecture:** Two new backends join `automations.Backends` (P1 allows new fields; `backends.go`): `MCP MCPCaller` and `Agent AgentRunner`, both implemented in `cmd` (where Quick Connections secrets, `buildToolRegistry` and provider resolution live) and wired into the daemon's executor and the CLI's `dry-run`. `MCPModule`/`AgentModule` append to `DefaultModules`. `mcp()` reuses `internal/externalmcp`'s go-sdk client (new `CallTool`) under `ResolveTools`' verdict, 30 s per call. `agent()` computes the effective tool set (`tools ∩ manifest-admitted ∩ visible on automation`, minus writes in a dry run), carves its budget from the run's remainder, and runs either `agentloop` (in-process, per-call gate and token hooks) or a CLI child in its own process group with a stripped environment, whose MCP server re-derives and enforces the same set per call. Inside `agent()` every write stays a pending proposal.

**Tech Stack:** Go 1.26, `github.com/modelcontextprotocol/go-sdk` (already used by `externalmcp`), `internal/agentloop`, `internal/ai` (claude CLI), `internal/codex`, `embed` for templates. No migration. No Swift (the gallery UI is P3's, over `templates --json`).

**Spec:** `docs/superpowers/specs/2026-10-14-automations-design.md` — §3.1 (`mcp:`, `agent:run`), §3.2 (mcp matching), §3.4 (secrets), §4 (dry run: `mcp` reads run, `agent` without writes), §5 (`mcp`, `agent` rows), §6.5 (`agent()` runtime), §7.5 (tokens), §10 (`templates`, `install-template`), §12.3, §15 (templates), §16, §17, §18 P6 tests, §20 D3/D4/D13, §14.7 (QC-02 amendment), §20.1 D20–D22 (asks #272, #273). QC-01..04: `docs/inventory/quick-connections.md`. P1 plan and its **Seams for later phases**: `docs/superpowers/plans/2026-10-14-automations-p1.md`; P2 plan `…-p2.md` (`Binding.AutomationRunID`, automation trust order).

**Branch:** `feature/automations-p6` → PR into `feature/automations`. Never `main`. Depends on P1 and P2 merged. Tasks 8–10 (templates) additionally depend on **P5** (`SessionModule`/`ShellModule` and their test fakes; templates 2 and 5 call `session()`/`shell()`). Template 1 is an event recipe; its `trigger.events` decoding is P1's (S5), and its tests seed `event_json` on the row directly, so P6 does not depend on P4.

**Header notes (seams):**
- Consumes P1's names exactly: `automations.Backends` (new fields `MCP`, `Agent` appended in `backends.go` — P1: "P6 appends `MCP MCPCaller` and `Agent AgentRunner`"), `Module`/`Definer`/`SDKFunc`/`Env`, `DefaultModules` (P6 appends `MCPModule`, `AgentModule`), `(*Manifest).AllowMCP`/`AllowCapability`/`AllowLLM`/`AllowTool(ctx, d, t, args)` (S1), `ClampListLimit` (S9), `Meter.BeforeCall|Debit|Remaining|Deadline`, `Journal`, `SourceLLMLight`/`SourceLLMStrong`, `RunEnvMarker`, `PersonalDir`/`WorkbenchDir`, `(*Indexer).RescanPersonal|RescanFolder`, `ParseRecipe`, `fsutil.WriteFileAtomic`, `automationstest.*`. P2's `tools.Binding.AutomationRunID`, `tools.Binding.AutomationAgent`, the automation trust branch and `(*Manifest).AdmitsTool`.
- **Seams settled elsewhere (consumed here, not re-made):**
  - **S8** `tools.Binding.AutomationAgent bool` is P2's (P2 Task 3, added with `AutomationRunID`): on the `automation` surface `resolveTrust` returns `ask` for it right after the AlwaysAsk rule, so `agent()` writes stay pending even under an active grant or a `tool_trust(…,'automation')=execute` (spec §6.5). Pinned at registry level by P2's `TestTrustOrder_AutomationSurface`; P6 pins it end to end with `TestAgent_WritesStayProposals` (Task 7) and `TestAgentMCPServer_WriteIsPendingProposalWithRunContext` (Task 5).
  - **S9** `automations.ClampListLimit(t *tools.Tool, args json.RawMessage) json.RawMessage` is exported by P1 (Task 4) and used by P1's `tool()`; P6's gates call the same function.
  - The "admitted by name" rule is P2's `(*Manifest).AdmitsTool` — `EffectiveAgentTools` uses it rather than a second copy.
- **Cross-plan contracts already pinned by P3 and P5 (consumed here, not re-decided):**
  - P3 Task 13 pins the gallery JSON: `automations templates --json` → an array of `{"name", "title", "description", "scope": "personal"|"workbench", "trigger_text", "permissions", "outputs"}`; `automations install-template <name> [--workbench N] --json` → `{"automation_id", "path"}`; a placeholder such as `<PROJECT>` is installed as written and surfaces as the parse error the form asks the owner to fix. P6 emits those keys (and may add keys; Swift decoding ignores extras).
  - P5 header note 5 writes `pr-review-rounds`, `release`, `deploy-test`, `deploy-stage` as fixtures in `internal/automations/testdata/workbench/` with end-to-end tests, and `automationstest.FakeShell` / `FakeSessionDesk`. P6 **moves** those four files byte-for-byte into the embedded templates (no rewrite) and repoints P5's `workbench_e2e_test.go` at the embedded copies without changing an assertion.

## Global Constraints

- All repo text English; repo is public — fixtures use `acme`, `example.com`, a Quick Connection named `github`, project `PAY`; no real ids, no local absolute paths (`t.TempDir()`).
- Inner loop only: `go test ./internal/<pkg>`, `go test ./cmd -run '<Name>'`, `make lint-diff`. The full gate (`make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`) runs once at the end of the phase, by the controller.
- **Tests that spawn processes reap them**: every test that starts a stub `claude`/`codex` script, a fake stdio MCP server or a helper binary starts it in its own process group and, in `t.Cleanup`, kills the whole group (`syscall.Kill(-pgid, SIGKILL)`) and waits for it — including on the timeout/cancel path it tests. No orphan may survive the test (verified once per task with `pgrep -f <stub name>` → none).
- Transactions `BEGIN IMMEDIATE`; never hold a write tx across an MCP call, a model call or a child process.
- Pinned values (spec, do not change without the spec):
  - `mcp(server, tool, args)`: permission `mcp:<server>/<glob>` (server exact, tool `path.Match`), then QC-02's `externalmcp.ResolveTools` verdict must allow the tool (a declared write is refused even when the glob matches) — automations are QC-02's second consumer of the same allowed read-only list (QC-02 amended, owner-approved in ask #272, spec §14.7, §20.1 D20); only an **enabled** Quick Connection; **30 s** per call; result ≤ 256 KiB serialised (`ResultTooLarge`, never truncated); runs for real in a dry run (it is a read); never enters the registry (no `agent_actions` row).
  - `agent(instruction, {tools?, budget?, tier?})`: permissions `agent:run` **and** `llm:<tier>` (default `light`); effective tool set = `tools ∩ (tools the manifest admits) ∩ (visible on automation)`; `budget = {tokens, minutes}` ≤ the run's remainder; returns `{text, actions: [ids]}`; iterations ≤ **12**; tokens debited per model call (`input + output`); `wait` is not available inside; writes go through `Registry.Propose` with the automation binding and stay pending; dry run → write tools removed from the effective set (AUTO-12); the broad knowledge tools (`search_knowledge`, `get_knowledge_document`, `get_task_context`) enter the effective set only through their own `tool:<name>` entry (no `knowledge` capability — ask #273, D21), `list_messages` only through `slack:read@*` or `tool:list_messages` (ask #273, D22) — both already follow from P1's `ToolCapabilities` and P2's `AdmitsTool`/P1's `AllowTool`, no second rule here.
  - CLI providers (`claude`, `codex`, D3): headless process; MCP server `watchtower mcp --db-path <db> --chat --surface automation --automation-run <N> --automation-tools <comma list>`; claude `--allowedTools` = one `mcp__watchtower__<tool>` token per effective tool (never the bare `mcp__watchtower`); environment exactly `PATH` (the CLI's rich PATH), `HOME`, `LANG`, `USER` and `WATCHTOWER_AUTOMATION_RUN_ID=<N>` — nothing else (no tokens, no `WATCHTOWER_TERMINAL_SESSION_ID`, no `CLAUDECODE`); its own process group, killed with the group on deadline, budget, cancel or daemon exit; no Quick Connections mounted into the agent.
  - Runtime B (`ollama`, D3): `agentloop` with the automation binding, the effective set only, `maxIterations` 12, per-model-call budget check and debit.
  - Templates (§15), embedded, installed **unconfirmed and disabled**: `new-mail-summary`, `pr-review-rounds`, `jira-state-report`, `team-performance-report`, and the `release` / `deploy-test` / `deploy-stage` set — frontmatter values exactly as §15 (listed in Task 8).
- Guard tests named as spec §18 P6: `TestMCP_OnlyQC02AllowedTools`, `TestAgent_ToolSetIsIntersection`, `TestAgent_BudgetCarvedFromRun`, `TestAgent_WritesStayProposals`, `TestTemplates_AllParseAndValidate`, `TestTemplates_DryRunE2E`; never weakened.

## Review Focus

1. **A model inside `agent()` naming a tool outside the effective set, or calling an admitted tool with an out-of-scope argument** (`jira:read@PAY`, `list_jira_issues{project:"OPS"}`) — refused per call on both runtimes, not only by what is advertised. Pinned in Task 4 (`TestAgentLoop_GateRefusesUnofferedAndOutOfScope`) and Task 5 (`TestAgentMCPServer_GatesEachCallByManifest`).
2. **Borrowing a run's binding** — another process (a workbench Claude Code session) starting `watchtower mcp --surface automation --automation-run N` must be refused: the env marker must equal N and run N must be `running`. Pinned in Task 5 (`TestAgentMCPServer_RefusesWithoutMatchingMarkerOrRunningRun`).
3. **A CLI child that outlives its run** (deadline, cancel, budget, daemon shutdown) — the whole process group (claude/codex plus its `watchtower mcp` child) is killed and reaped. Pinned in Task 6 (`TestCLIAgent_ProcessGroupKilledOnCancel`, `TestCLIAgent_ProcessGroupKilledOnDeadline`).
4. **An active auto grant and an `execute` trust row must not make an `agent()` write apply** — pending only. Pinned in Task 4 (`TestAgent_WritesStayProposals` grant/trust sub-cases) and Task 7.
5. **A Quick Connection that was never listed, failed its listing, is disabled, or lists the tool as a write** — `mcp()` fails closed with `NotAvailable`/`PermissionDenied` and spawns nothing. Pinned in Task 2 (`TestMCP_OnlyQC02AllowedTools` table).
6. **Template placeholders** — without `--param` the copy keeps the literal `<PROJECT>` and is indexed with a parse error (not runnable; the P3 form shows it to fix); an unknown `--param`, or a value that breaks the manifest (`PROJECT=a b`), refuses the install and writes no file. Pinned in Task 8 (`TestInstallTemplate_PlaceholdersAndParams`).

---

## File structure

| Path | Responsibility |
|---|---|
| `internal/externalmcp/call.go` | `CallTool` (go-sdk client call) |
| `cmd/automations_backends.go` | `MCPCaller` and `AgentRunner` implementations, wiring into executor/dry-run |
| `internal/automations/sdk_mcp.go` | `MCPModule` |
| `internal/automations/sdk_agent.go`, `agent_toolset.go` | `AgentModule`, effective set, budget carving |
| `internal/agentloop/client.go` | `Options` (tool allowlist, gate, iterations, model-call hooks) |
| `cmd/mcp.go`, `internal/mcp/actions.go`, `internal/mcp/server.go` | `--surface automation --automation-run N --automation-tools`, tool filter, call gate |
| `internal/ai/client.go`, `internal/codex/client.go` | opt-in child env, process group, allowed watchtower tools, max turns |
| `internal/automations/templates/*.md`, `templates/index.json`, `templates.go` | embedded gallery |
| `cmd/automations_templates.go` | `templates`, `install-template` |
| `docs/inventory/{automations,agent-actions,quick-connections}.md`, `docs/features/automations.md`, `docs/features/quick-connections.md` | docs |

---

### Task 1: `externalmcp.CallTool`

**Files:**
- Create: `internal/externalmcp/call.go`, `internal/externalmcp/call_test.go`
- Modify: `internal/externalmcp/main_test.go` (the fake stdio server gains a `get_thing` tool returning structured content, a `slow_thing` tool that blocks, and a `fail_thing` tool returning `isError`)

**Interfaces:**
- Consumes: `ServerSpec`, `discoveryTransport`, `killProcessGroup`, `withStderr`.
- Produces: `func CallTool(ctx context.Context, spec ServerSpec, tool string, args json.RawMessage) (json.RawMessage, error)` — connects (stdio server in its own process group, stopped before return; HTTP with `Headers`), calls `tools/call`; result: `structuredContent` when present, else `{"text": <text contents joined by "\n">}`; a result with `isError` → `*ToolError{Message}`; `ctx` bounds the whole exchange. `type ToolError struct { Message string }`.
- Depends on: none.

- [ ] **Step 1: Failing tests** (fake stdio server = the test binary under `WT_EXTERNALMCP_FAKE_STDIO_SERVER=1`; the cleanup kills the server's group and waits):
  - `TestCallTool_StdioStructuredResult`; `TestCallTool_TextResultWrapped`; `TestCallTool_IsErrorIsToolError`.
  - `TestCallTool_ContextDeadlineStopsServer` — `slow_thing` with a 200 ms deadline → `context.DeadlineExceeded`; the server's process group is gone afterwards.
  - `TestCallTool_HTTPHeaders` — `httptest` MCP server sees the bearer header.
  - `TestCallTool_SecretsTravelInEnvNotArgv` — a secret env value never appears in the started command's args (QC-03).
- [ ] **Step 2:** `go test ./internal/externalmcp -run TestCallTool` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 command → PASS; `pgrep -f WT_EXTERNALMCP_FAKE` → none.
- [ ] **Step 5:** `make lint-diff`; commit `feat(externalmcp): CallTool for Go-side reads`.

### Task 2: The `MCPCaller` backend (QC-02 verdict)

**Files:**
- Create: `cmd/automations_backends.go`, `cmd/automations_backends_test.go`
- Modify: `internal/automations/backends.go` (`MCP MCPCaller` field and the interface)

**Interfaces:**
- Consumes: `db.ListEnabledExternalConnections`, `connectionServer(cfg, database, c)` (secret + OAuth refresh, existing), `externalmcp.ResolveTools`, `externalmcp.CallTool`.
- Produces:
  - `automations`: `type MCPCaller interface { Call(ctx context.Context, server, tool string, args json.RawMessage) (json.RawMessage, error) }`; `Backends.MCP MCPCaller`; sentinel errors `automations.ErrMCPNotAvailable` (no enabled connection by that exact name, never listed, listing failed, no allowed tool) and `automations.ErrMCPToolNotAllowed` (tool not in `ResolveTools`' allowed list).
  - `cmd`: `func newAutomationMCPCaller(cfg *config.Config, database *db.DB) automations.MCPCaller` — exact-name match on an enabled row; `!ToolsListed` → `ErrMCPNotAvailable` (no listing attempt from an automation: the chat's launch-time listing and `connections tools --refresh` stay the only listers); tool ∉ allowed → `ErrMCPToolNotAllowed` before any process starts; else `CallTool` with a 30 s `context.WithTimeout`.
- Depends on: Task 1.

- [ ] **Step 1: Failing tests** (`cmd`, temp workspace; connection command = the externalmcp fake server via a small test helper binary built in `TestMain`, reaped in cleanup):
  - `TestMCP_OnlyQC02AllowedTools` — table: read-only-annotated tool → called; a tool annotated as a write but named in the owner's allow list → `ErrMCPToolNotAllowed`, server never started (a start counter file stays 0); unannotated `create_thing` → refused; never-listed connection → `ErrMCPNotAvailable`; disabled connection → `ErrMCPNotAvailable`; unknown name / case-different name → `ErrMCPNotAvailable`.
  - `TestMCPCaller_OAuthBearerUsed` — an OAuth connection's refreshed bearer reaches the HTTP fake.
  - `TestMCPCaller_ThirtySecondBound` — the deadline passed to `CallTool` is 30 s (injected clock/ctx probe).
- [ ] **Step 2:** `go test ./cmd -run 'TestMCP_OnlyQC02AllowedTools|TestMCPCaller'` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 command → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): Quick Connection caller under the QC-02 verdict`.

### Task 3: `MCPModule` — `mcp(server, tool, args)`

**Files:**
- Create: `internal/automations/sdk_mcp.go`, `internal/automations/sdk_mcp_test.go`
- Modify: `internal/automations/modules.go` (`DefaultModules` appends `MCPModule(b)`), `internal/automations/automationstest/fakes.go` (`FakeMCP` recording calls)

**Interfaces:**
- Consumes: `(*Manifest).AllowMCP(server, tool)`, `Backends.MCP`, `Journal` (step `kind='mcp'`, `name='<server>/<tool>'`), the sandbox's result size boundary.
- Produces: `func MCPModule(b Backends) Module` — `mcp(server, tool, args?)`: manifest check (denied → `PermissionDenied`, step `denied`, caller untouched) → `b.MCP == nil` → `NotAvailable` → call → `ErrMCPNotAvailable` → `NotAvailable`, `ErrMCPToolNotAllowed` → `PermissionDenied` with `needed` = `mcp:<server>/<tool>` and a message naming QC-02, `*externalmcp.ToolError`/other → `ToolError`; returns the parsed JSON. Dry run: runs for real.
- Depends on: Task 2.

- [ ] **Step 1: Failing tests:** `TestMCPModule_ManifestFirst` (`mcp:github/list_*`: `create_pr` denied with zero `FakeMCP` calls), `TestMCPModule_QC02RefusalIsPermissionDenied`, `TestMCPModule_NotAvailable`, `TestMCPModule_ResultTooLarge`, `TestMCPModule_DryRunCallsForReal`, `TestMCPModule_OneStepPerCall` (AUTO-11).
- [ ] **Step 2:** `go test ./internal/automations -run TestMCPModule` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 command → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): mcp() over Quick Connections`.

### Task 4: Runtime-B options and the effective tool set

**Files:**
- Modify: `internal/agentloop/client.go`, `internal/agentloop/loop_test.go`
- Create: `internal/automations/agent_toolset.go`, `internal/automations/agent_toolset_test.go`

**Interfaces:**
- Consumes: P2's `Binding.AutomationAgent` and automation trust branch (S8); P1's `ClampListLimit` (S9) — both already exist, this task adds neither; P2's `(*Manifest).AdmitsTool`.
- Produces:
  - `func EffectiveAgentTools(reg ToolRegistry, m *Manifest, requested []string, dryRun bool) []string` — `requested` nil/omitted = every tool the manifest admits by name; ∩ `m.AdmitsTool(t)` (P2's single by-name rule, which already requires `VisibleOn("automation")`); minus `AccessWrite` tools in a dry run; sorted; unknown names dropped (listed in the step args). Task 5's MCP server and Task 7's `AgentModule` call this one function (no second intersection).
  - `agentloop.Options struct { Tools []string /* nil = every surface tool */; Gate func(ctx context.Context, t *tools.Tool, args json.RawMessage) (json.RawMessage, error) /* returns the args to dispatch, or an error fed back to the model */; MaxIterations int /* 0 = defaultMaxIterations */; BeforeModelCall func() error /* error stops the loop and is returned */; AfterModelCall func(inputTokens, outputTokens int) }`; `func NewClientWithOptions(model, baseURL string, reg *tools.Registry, b tools.Binding, opts Options) *Client`; `NewClient` unchanged (zero `Options`). `buildTools` advertises only `Options.Tools ∩ List(surface)`; `dispatch` refuses a name outside that set before `Get`'s surface check, then runs `Gate`.
- Depends on: P2 merged.

- [ ] **Step 1: Failing tests:**
  - `TestAgentLoop_AdvertisesOnlyAllowedTools`; `TestAgentLoop_GateRefusesUnofferedAndOutOfScope` (a fake OpenAI server whose model calls an unoffered tool, then an offered one with an out-of-scope arg → both get `{"error": …}` results, the registry sees zero calls).
  - `TestAgentLoop_MaxIterationsOption` — 12 → the 13th model call never happens.
  - `TestAgentLoop_ModelCallHooks` — `BeforeModelCall` error on the 3rd call stops with that error; `AfterModelCall` receives each response's usage.
  - `TestRuntimeB_WriteToolRecordsProposalOnly` (existing AGENT-01 guard) unchanged and green.
  - `TestAgent_ToolSetIsIntersection` — manifest `jira:read@PAY`, `targets:read`, `outputs:[target]`; requested `list_jira_issues, list_targets, create_target, get_confluence_page, send_slack_message, search_knowledge, bogus` → `create_target, list_jira_issues, list_targets` (`search_knowledge` dropped: no `tool:search_knowledge`, ask #273); with `tool:search_knowledge` added → `search_knowledge` joins; requested omitted → every admitted tool; dry run → `create_target` removed.
- [ ] **Step 2:** `go test ./internal/agentloop` and `go test ./internal/automations -run TestAgent_ToolSetIsIntersection` → FAIL (new ones).
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 commands → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(agentloop): tool allowlist, call gate, iteration cap and token hooks`.
- Note: the registry-level half of `TestAgent_WritesStayProposals` that an earlier draft put here is P2's `TestTrustOrder_AutomationSurface` (`AutomationAgent` rows); the spec §18 guard `TestAgent_WritesStayProposals` itself lives in Task 7 (runner level, grant and trust sub-cases).

### Task 5: Chat-mode MCP bound to an automation run

**Files:**
- Modify: `cmd/mcp.go`, `cmd/mcp_test.go`, `internal/mcp/actions.go` (`registerRegistry` honours a filter and a gate), `internal/mcp/server.go` (`ServerOption`s)
- Create: `cmd/mcp_automation_test.go`

**Interfaces:**
- Consumes: `db.GetAutomationRun`, `db.GetAutomation`, `automations.ParseRecipe` (on `recipe_snapshot`), `ParseManifest`, `(*Manifest).AllowTool(ctx, d, t, args)`, `(*Manifest).AdmitsTool` (P2), `ClampListLimit` (P1), `automations.RunEnvMarker`, P2's `Binding.AutomationAgent`.
- Produces:
  - `internalmcp.WithToolFilter(func(t *tools.Tool) bool) ServerOption` (unmounted tools are never listed); `internalmcp.WithCallGate(func(ctx context.Context, t *tools.Tool, args json.RawMessage) (json.RawMessage, error)) ServerOption` (run before `CallRead`/`Propose`; an error becomes the tool's error result). Neither changes the dev-mode server (AGENT-02).
  - `watchtower mcp --chat --surface automation --automation-run N --automation-tools a,b,c`: refused unless `os.Getenv(RunEnvMarker) == strconv(N)`; run N exists and is `running`; the effective set is recomputed here with `EffectiveAgentTools` (Task 4) = `flag list ∩ manifest-admitted (AdmitsTool) ∩ visible on automation`, minus write tools when `run.trigger = 'dry_run'`; binding `{Surface: "automation", ContextType: "automation_run", ContextID: N, AutomationRunID: N, WorkbenchID: <automation's project id>, AutomationAgent: true}`; the gate re-reads the run status per call (not `running` → error "the automation run has ended"), runs `AllowTool(ctx, db, t, args)` (denied → error text `PermissionDenied: needs <permission>`), clamps `limit`, and refuses a result over 256 KiB with `ResultTooLarge`; `get_action` mounts as in chat mode. `--surface automation` without `--automation-run` → error; `--automation-run` with another surface → error; `main`/`target` behave exactly as today.
- Depends on: Task 4.

- [ ] **Step 1: Failing tests** (in-process MCP client over the server, file DB, seeded running run):
  - `TestAgentMCPServer_RefusesWithoutMatchingMarkerOrRunningRun` — no marker; marker `N+1`; run `queued`; run `succeeded` → each refused at start.
  - `TestAgentMCPServer_MountsOnlyEffectiveSet` — flag `list_jira_issues,create_target,get_confluence_page`, manifest `jira:read@PAY` + `outputs:[target]` → `tools/list` = `list_jira_issues`, `create_target`, `get_action`.
  - `TestAgentMCPServer_GatesEachCallByManifest` — `list_jira_issues{project:"OPS"}` → error naming `jira:read@OPS`, registry untouched.
  - `TestAgentMCPServer_DryRunMountsNoWrites`.
  - `TestAgentMCPServer_WriteIsPendingProposalWithRunContext` — `create_target` → one `pending` row, `context_type='automation_run'`, `context_id=N`, even with an active grant (S8).
  - `TestAgentMCPServer_CallAfterRunEndedRefused`.
  - `TestMCP_MainAndTargetUnchanged` — existing chat-mode tests green; `--surface automation` without `--automation-run` → error.
- [ ] **Step 2:** `go test ./cmd -run 'TestAgentMCPServer|TestMCP_MainAndTargetUnchanged'` and `go test ./internal/mcp` → FAIL (new ones).
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 commands → PASS; existing `internal/mcp` AGENT-02/06 guards green.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): chat-mode MCP bound to an automation run`.

### Task 6: CLI clients — child env, process group, narrowed allowlist

**Files:**
- Modify: `internal/ai/client.go`, `internal/ai/client_test.go`, `internal/codex/client.go`, `internal/codex/client_test.go`

**Interfaces:**
- Consumes: existing `buildArgs`, `QuerySync`, `claude.RichPATH()`.
- Produces (all opt-in; unset = today's behaviour byte-for-byte):
  - `ai.Client`: `SetWatchtowerTools(names []string)` — `--allowedTools` becomes `mcp__watchtower__<name>` per name (sanitised like `externalToolToken`), never the bare `mcp__watchtower`; `SetChildEnv(env []string)` — replaces the `os.Environ()` base (the rich `PATH` still appended last); `SetProcessGroup(true)` — `Setpgid`, and `cmd.Cancel` kills `-pgid` (SIGKILL after the existing interrupt + `WaitDelay`); `SetMaxTurns(n int)` → `--max-turns n`.
  - `codex.Client`: `SetChildEnv`, `SetProcessGroup` (codex has no per-tool MCP allowlist flag here; the server-side filter of Task 5 is the enforcement, as for claude).
- Depends on: none.

- [ ] **Step 1: Failing tests** (stub `claude`/`codex` = a shell script in `t.TempDir()` that records argv and env to a file, optionally spawns a grandchild `sleep 60` and sleeps; cleanup kills the group and waits):
  - `TestBuildArgs_WatchtowerToolsPerTool` — `--allowedTools` = `mcp__watchtower__list_jira_issues,mcp__watchtower__create_target`; no bare token; a hostile name cannot inject a comma.
  - `TestQuerySync_ChildEnvReplacesEnviron` — recorded env = exactly the given vars + `PATH`; a parent `CLAUDECODE`/`SLACK_TOKEN` absent.
  - `TestCLIAgent_ProcessGroupKilledOnCancel` — cancel ctx → stub and its grandchild both gone (`kill(-pgid, 0)` → `ESRCH`) within `WaitDelay`.
  - `TestCLIAgent_ProcessGroupKilledOnDeadline`.
  - `TestBuildArgs_MaxTurns`; `TestBuildArgs_DefaultsUnchanged` (no option set → args identical to before).
  - Codex twins: `TestCodexQuerySync_ChildEnvReplacesEnviron`, `TestCodexProcessGroupKilledOnCancel`.
- [ ] **Step 2:** `go test ./internal/ai -run 'TestBuildArgs_WatchtowerTools|TestQuerySync_ChildEnv|TestCLIAgent_|TestBuildArgs_MaxTurns|TestBuildArgs_DefaultsUnchanged'`, `go test ./internal/codex -run 'TestCodexQuerySync_ChildEnv|TestCodexProcessGroup'` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 commands → PASS; `pgrep -f <stub name>` → none.
- [ ] **Step 5:** `make lint-diff`; commit `feat(ai): opt-in child env, process group and per-tool watchtower allowlist`.

### Task 7: `AgentModule` and the agent runners

**Files:**
- Create: `internal/automations/sdk_agent.go`, `internal/automations/sdk_agent_test.go`
- Modify: `cmd/automations_backends.go` (+ tests), `internal/automations/modules.go`, `internal/automations/automationstest/fakes.go` (`FakeAgent`), the daemon/CLI wiring that builds `Backends` (P1's `cmd/sync.go` and `automations dry-run`), `internal/db/agent_actions.go` (two read helpers)

**Interfaces:**
- Consumes: Tasks 4–6; `providers.ResolveModelsFor(cfg, provider) (light, strong string)`; `Meter.BeforeCall|Debit|Remaining|Deadline`; `SourceLLMLight`/`SourceLLMStrong`; `RunEnvMarker`.
- Produces:
  - `automations`: `type AgentRequest struct { Instruction string; Tools []string /* effective set */; DryRun bool; Tier string; Budget Budget /* carved */; Deadline time.Time; Binding tools.Binding; RunID int64; BeforeModelCall func() error; AfterModelCall func(in, out int) }`; `type AgentResult struct { Text string; InputTokens, OutputTokens int64; Estimated bool; ReportedCostUSD *float64 }`; `type AgentRunner interface { Run(ctx context.Context, req AgentRequest) (AgentResult, error) }`; `Backends.Agent AgentRunner`.
  - Uses Task 4's `EffectiveAgentTools` for the set it hands the runner.
  - `func AgentModule(b Backends) Module` — `agent(instruction, opts?)`: `AllowCapability("agent","run","")` and `AllowLLM(tier)` (either missing → `PermissionDenied`, runner untouched); `opts.wait` → `ValidationError` ("wait is not available inside agent()"); budget carve: `tokens = min(opts.budget.tokens || remaining, remaining.tokens)`, `minutes = min(opts.budget.minutes || remaining, remaining.minutes)` (a larger request is clamped, the clamped value recorded in the step args); remaining tokens ≤ 0 → `BudgetExceeded`; agent-local budget spent mid-loop → the loop stops and `agent()` throws `BudgetExceeded` (catchable — the run may still have budget); the **run's** budget crossed → handled exactly as P1's `llm` module handles a crossing `Debit` (run interrupted, `budget_exceeded`); one step `kind='agent'`, `name` = `claude`|`codex`|`runtime-b`, args `{instruction (clipped), tools, budget, tier}`, result `{text (clipped), actions}`, tokens on the step; returns `{text, actions}` where `actions` = ids of `agent_actions` rows with `context_type='automation_run'`, `context_id=<run>` and `id >` the max id read before the call.
  - `db`: `func (d *DB) MaxAgentActionID() (int64, error)`; `func (d *DB) AgentActionIDsAfter(contextType, contextID string, afterID int64) ([]int64, error)`.
  - `cmd`: `func newAutomationAgentRunner(cfg *config.Config, dbPath string, database *db.DB) automations.AgentRunner` — provider `claude`/`codex` → CLI runner: model by tier from `ResolveModelsFor`; `ai.Client`/`codex.Client` with `SetMCPArgs([--chat --surface automation --automation-run N --automation-tools <set>])`, `SetWatchtowerTools(set + "get_action")` (claude), `SetMaxTurns(12)` (claude), `SetChildEnv([PATH, HOME, LANG, USER from the daemon, WATCHTOWER_AUTOMATION_RUN_ID=N])`, `SetProcessGroup(true)`, no `SetExternalMCPServers`; ctx deadline = `req.Deadline`; `BeforeModelCall` once before start; usage debited once after (provider usage, else `ceil(len(instruction+text)/4)` with `Estimated`); any other provider → runtime B: `agentloop.NewClientWithOptions(model, cfg.AI.OllamaURL, buildAutomationRegistry(cfg, database) /* P1 Task 5b */, req.Binding /* AutomationAgent: true */, Options{Tools: set, Gate: <AllowTool + ClampListLimit + 256 KiB>, MaxIterations: 12, BeforeModelCall, AfterModelCall})`.
- Depends on: Tasks 3–6.

- [ ] **Step 1: Failing tests** (`FakeAgent` for module tests; for runner tests a stub CLI and a fake OpenAI server, reaped in cleanup):
  - `TestAgent_PermissionNeedsAgentRunAndLLMTier` — `agent:run` without `llm:strong` and `{tier:"strong"}` → `PermissionDenied` (`needed` `llm:strong`); without `agent:run` → `needed` `agent:run`; runner never called.
  - `TestAgent_BudgetCarvedFromRun` — run budget 50000 with 20000 spent: `{budget:{tokens:100000}}` → runner sees 30000 and the step args record 30000; omitted → 30000; remaining 0 → `BudgetExceeded`, runner not called; minutes clamped to the run's deadline.
  - `TestAgent_LocalBudgetSpentThrowsCatchable` — runtime B fake usage exceeds the carved 5000 but not the run → script catches `BudgetExceeded`, run `succeeded`.
  - `TestAgent_RunBudgetCrossedInterruptsRun` — usage crosses the run budget → run `budget_exceeded`.
  - `TestAgent_WritesStayProposals` (runner level) — runtime B model calls `create_target` with an active grant → one `pending` row; `actions` = [that id]; nothing executed.
  - `TestAgent_WaitOptionRefused`.
  - `TestAgent_IterationsCapped12` — runtime B fake model always tool-calls → 12 model calls.
  - `TestAgent_CLIChildEnvHasRunMarkerAndNoSecrets` — stub claude records env/argv: env = `PATH, HOME, LANG, USER, WATCHTOWER_AUTOMATION_RUN_ID=<N>` only; argv has `--max-turns 12`, `--allowedTools` per-tool tokens, an mcp-config whose watchtower args carry `--surface automation --automation-run <N> --automation-tools <set>`; no Quick Connection server in the config.
  - `TestAgent_CLIUsageDebitedOrEstimated`.
  - `TestAgent_CancelKillsCLIChild` — run cancel mid-agent → process group gone, run `cancelled`.
  - `TestAgent_DryRunRemovesWriteTools` (AUTO-12) — dry run: the CLI's `--automation-tools` and runtime B's advertised set contain no write tool.
- [ ] **Step 2:** `go test ./internal/automations -run TestAgent_` and `go test ./cmd -run 'TestAgent_'` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 commands → PASS; `pgrep -f <stub name>` → none; `go test -race ./internal/automations -run TestAgent_` once.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): agent() on runtime B and the CLI providers`.

### Task 8: Templates and the gallery CLI

**Files:**
- Create: `internal/automations/templates/new-mail-summary.md`, `jira-state-report.md`, `team-performance-report.md`, `internal/automations/templates/index.json`, `internal/automations/templates.go`, `internal/automations/templates_test.go`, `cmd/automations_templates.go`, `cmd/automations_templates_test.go`
- Move (`git mv`, byte-for-byte, P5 header note 5): `internal/automations/testdata/workbench/{pr-review-rounds,release,deploy-test,deploy-stage}.md` → `internal/automations/templates/`; repoint P5's `internal/automations/workbench_e2e_test.go` at the embedded copies (no assertion changes).

**Interfaces:**
- Consumes: `ParseRecipe`, `PersonalDir`, `WorkbenchDir`, `(*Indexer).RescanPersonal|RescanFolder`, `fsutil.WriteFileAtomic(path, data, 0o644)` (P1's `automations save` helper), `db.GetWorkbench`; P3 Task 13's JSON contract.
- Produces:
  - `type TemplateParam struct { Key, Label, Example string }`; `type Template struct { Name, Title, Description, TriggerText string; Scope ScopeKind; Files []string /* slugs */; Params []TemplateParam }`; `func Templates() []Template` (index order); `func RenderTemplate(name string, params map[string]string) (map[string][]byte /* slug → recipe bytes */, error)` — replaces each given `<KEY>` placeholder (spec §15 spelling, e.g. `<PROJECT>`); a param the template does not declare, an empty value, or a value with whitespace, a newline, `"`, `@` or `<`/`>` → error naming it; a declared param left out keeps its literal placeholder.
  - Gallery = **five** templates; the fifth (`release-buttons`, workbench) installs three recipes. Index and frontmatter, exactly spec §15:
    1. `new-mail-summary` — personal; `trigger: {event: {type: gmail.new_messages}}`; `permissions: [gmail:read@*, llm:light]`; `outputs: [inbox]`; script keeps a per-account `since` cursor in `state`; the description shows the `schedule` variant.
    2. `pr-review-rounds` — workbench; `trigger: {schedule: "0 10,16 * * 1-5"}`; `permissions: ['shell:"gh pr list --state open --json number,title,url,author,updatedAt"', session:start, llm:light]`; `outputs: [report]`; for each PR updated since the last round (`state`) one `session()` whose prompt tells the agent to review the PR and file its findings as `ask_owner` asks (D13: PR comments go through the session).
    3. `jira-state-report` — personal; `trigger: {schedule: "0 9 * * 1"}`; `permissions: [jira:read@<PROJECT>, llm:strong]`; `outputs: [report, briefing]`; param `PROJECT` (label "Jira project key", example `PAY`).
    4. `team-performance-report` — personal; `trigger: {schedule: "0 17 * * 5"}`; `permissions: [jira:read@*, people:read, slack:read@*, llm:strong]`; `outputs: [report]` (`slack:read@*` is the only v1 grant that admits `list_messages`, ask #273).
    5. `release-buttons` → `release`, `deploy-test`, `deploy-stage` — workbench; `trigger: {button: {label: "Release" | "Deploy to test" | "Deploy to stage", confirm: true}}`; `permissions: ['shell:"make release"' | 'shell:"make deploy-test"' | 'shell:"make deploy-stage"', session:start]` (the commands are placeholders the owner edits); `outputs: [report]`; after the command a `session()` runs the follow-up check.
  - CLI (P3 Task 13's contract, superset allowed): `watchtower automations templates [--json]` → always an array of `{"name", "title", "description", "scope", "trigger_text", "permissions", "outputs"}` plus `"files"` and `"params"`; for `release-buttons`, `trigger_text`/`permissions` describe the `release` recipe and `files` lists all three. `watchtower automations install-template <name> [--workbench N] [--param KEY=VALUE]… [--json]` — a workbench template needs `--workbench` and a personal one refuses it; any target slug already present (file or index row) → refused before writing anything; writes every file atomically, rescans the folder, leaves each automation **unconfirmed and disabled**; JSON `{"automation_id": <first file's id>, "path": <first file's path>, "installed": [{"automation_id", "slug", "path", "parse_error"}]}` (the first entry is the one the P3 form opens). Not refused under AI-agent markers (it confirms nothing; AUTO-06 keeps the result unrunnable).
- Depends on: P1 for the code; P5 merged for the four moved workbench files (they parse with P1's manifest; P5 is needed to run them).

- [ ] **Step 1: Failing tests:**
  - `TestTemplates_AllParseAndValidate` — every template rendered with its param examples parses under its scope (`workbench:1` for workbench ones) with the §15 trigger, permissions and outputs asserted field by field; `index.json` names exactly the seven files; five gallery entries; `jira-state-report` rendered **without** params is a parse error naming `<PROJECT>`.
  - `TestInstallTemplate_PlaceholdersAndParams` — `jira-state-report` with no `--param` → installed, `parse_error` names `<PROJECT>`, not runnable; `PROJECT=PAY` → installed, manifest `jira:read@PAY`, no parse error; `PROJECT=a b` and an unknown `--param X=1` → refused, no file.
  - `TestInstallTemplate_InstalledUnconfirmedAndDisabled` — `show --json` → `needs_confirmation: true`, `enabled: false`; `run` → queued then `cancelled`/`not_runnable` by the executor (AUTO-06).
  - `TestInstallTemplate_WorkbenchScopeRules` — `pr-review-rounds` without `--workbench` refused; `new-mail-summary` with `--workbench 1` refused; `release-buttons --workbench 1` writes three files under `<folder>/.watchtower/automations/`.
  - `TestInstallTemplate_RefusesExistingSlug` — a second install → refused, the first file byte-identical.
  - `TestTemplatesCLI_JSON` — the P3 keys present on every entry (`name`, `title`, `description`, `scope`, `trigger_text`, `permissions`, `outputs`); `install-template --json` carries `automation_id` and `path` at the top level.
  - P5's `workbench_e2e_test.go` passes unchanged against the moved files.
- [ ] **Step 2:** `go test ./internal/automations -run 'TestTemplates_AllParse|TestRenderTemplate'` and `go test ./cmd -run 'TestInstallTemplate|TestTemplatesCLI'` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 commands → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): template gallery and install-template`.

### Task 9: Template end-to-end — dry runs

**Files:**
- Create: `internal/automations/templates_e2e_test.go`, `internal/automations/testdata/template_fixtures/` (seeded rows: one Gmail account `work` with three messages, Jira project `PAY` with five issues, two people, Slack messages in `#releases`)

**Interfaces:**
- Consumes: Tasks 7–8; `automationstest.FakeGenerator`; P5's `SessionModule`/`ShellModule` and `automationstest.FakeShell`/`FakeSessionDesk`; P1's `trigger.events` decoding of `event_json` (S5; the test seeds the row's `event_json` as a `db.AutomationEventPayload`).
- Produces: nothing new — pins each template's dry-run journal.
- Depends on: Task 8, P5 merged.

- [ ] **Step 1: Failing test `TestTemplates_DryRunE2E`** — for each of the seven recipes, installed + `ExecuteInline` on a `dry_run` row (event recipe: `trigger.events` seeded on the row), FakeGenerator replies scripted; pinned step kinds in order and final outputs:
  - `new-mail-summary`: `tool(list_emails)` `ok` → `llm` `ok` → `output` (`inbox`) `dry_run` → `state` `dry_run`; no `automation_outputs` row.
  - `jira-state-report` (`PROJECT=PAY`): `tool(list_jira_issues{project:"PAY"})` `ok` → `llm` (strong source tag `automation.llm.strong`) `ok` → `output` `report` and `briefing` `dry_run`.
  - `team-performance-report`: Jira, people, Slack reads `ok` → `llm` strong → `output` `report` `dry_run`.
  - `pr-review-rounds`, `release`, `deploy-test`, `deploy-stage` (moved from P5, whose `TestAuto12_DryRunStartsNoSessionOrShell` already pins their journals): here only the invariants — FakeShell 0 calls, no `waiting` session step, no `terminal_sessions`/`owner_asks` row, every `shell`/`session`/`output` step `dry_run`.
  - For every template: zero `agent_actions`, `automation_state` unchanged, real `llm` tokens counted on the run (AUTO-12).
- [ ] **Step 2:** `go test ./internal/automations -run TestTemplates_DryRunE2E` → FAIL; adjust template scripts (never the assertions) until it passes.
- [ ] **Step 3:** Step 2 → PASS.
- [ ] **Step 4:** `make lint-diff`; commit `test(automations): dry-run end-to-end over the five templates`.

### Task 10: Template end-to-end — real runs with fake backends

**Files:**
- Create: `internal/automations/templates_run_e2e_test.go`

**Interfaces:**
- Consumes: as Task 9.
- Produces: `TestTemplates_RunE2E` — the three personal recipes confirmed, enabled and run by the `Executor` with fakes (the four workbench recipes' real runs are already pinned by P5's `TestPRReviewRounds_E2E` and its release/deploy tests, now running against the embedded copies — not duplicated here):
  - `new-mail-summary` (event run with one `gmail.new_messages{account: work}`) → `succeeded`, one `inbox` output, `state` cursor for `work` set; a second event run with no newer mail → no output, cursor unchanged.
  - `jira-state-report` (`PROJECT=PAY`) → `report` + `briefing` outputs.
  - `team-performance-report` → one `report` output.
- Depends on: Task 9.

- [ ] **Step 1:** Write `TestTemplates_RunE2E` → FAIL; fix template scripts only (never the moved P5 files).
- [ ] **Step 2:** `go test ./internal/automations -run TestTemplates_RunE2E` → PASS.
- [ ] **Step 3:** `make lint-diff`; commit `test(automations): run end-to-end over the personal templates`.

### Task 11: Inventory and docs

**Files:**
- Modify: `docs/inventory/automations.md`, `docs/inventory/agent-actions.md`, `docs/inventory/quick-connections.md`, `docs/inventory/README.md` (module rows: `internal/externalmcp/call.go` under Quick Connections; `internal/automations/sdk_mcp.go`, `sdk_agent.go`, `templates*`, `cmd/automations_backends.go`, `cmd/automations_templates.go` under Automations), `docs/features/automations.md`, `docs/features/quick-connections.md`

**Interfaces:**
- Consumes: guard names from Tasks 1–10.
- Produces:
  - **automations.md** — no status flips (AUTO-01/07/08/11/12 are Enforced since P1); added guards: AUTO-01 `TestMCP_OnlyQC02AllowedTools`, `TestMCPModule_ManifestFirst`, `TestAgent_ToolSetIsIntersection`, `TestAgentMCPServer_GatesEachCallByManifest`, `TestAgentLoop_GateRefusesUnofferedAndOutOfScope`; AUTO-07 `TestAgent_CLIChildEnvHasRunMarkerAndNoSecrets`, `TestAgentMCPServer_RefusesWithoutMatchingMarkerOrRunningRun`; AUTO-08 `TestAgent_BudgetCarvedFromRun`, `TestAgent_RunBudgetCrossedInterruptsRun`, `TestAgent_IterationsCapped12`, `TestAgent_CancelKillsCLIChild`; AUTO-11 `TestMCPModule_OneStepPerCall`; AUTO-12 `TestAgent_DryRunRemovesWriteTools`, `TestTemplates_DryRunE2E`. Changelog: "P6 — mcp(), agent(), templates; inner tool calls of agent() are summarised in its one step (AUTO-11 counts SDK calls)".
  - **agent-actions.md** — AGENT-01 Observable gains "an `agent()` loop of an automation (runtime B or the CLI's `--surface automation` MCP server) is the same path: proposals only"; guard `TestAgent_WritesStayProposals`; AGENT-03 guard list gains `TestAgent_WritesStayProposals` and `TestAgentMCPServer_WriteIsPendingProposalWithRunContext` (the `AutomationAgent` narrowing itself and its changelog entry are P2's, Task 9 — not repeated here); AGENT-02: `--surface automation` is a chat-mode server, the dev server unchanged.
  - **quick-connections.md** — QC-02 amended per spec §14.7 (**owner-approved in ask #272**, §20.1 D20): Observable gains "Automations' `mcp()` (spec §5) is a second, Go-side consumer of the same allowed read-only tool list: it calls only tools in `externalmcp.ResolveTools`' allowed list of an enabled, listed connection, through `externalmcp.CallTool`, never through the registry; it never lists a connection itself and never calls a tool QC-02 does not allow" with guard `TestMCP_OnlyQC02AllowedTools`; Status line "amended <merge date> — automations' `mcp()` is a second consumer of the allowed list, owner approved in ask #272"; QC-03 guard `TestCallTool_SecretsTravelInEnvNotArgv`. Changelog dated with the PR; no existing QC guard relaxed.
  - `docs/features/automations.md` P6 section: mcp(), agent() (both runtimes, effective set, budget carving, the `--surface automation` server, env, process group, v1 limits: a CLI agent's tokens are known only when the child exits, so one `agent()` call can overshoot its carved budget before the run is interrupted; codex has no turn cap, only time and tokens), templates and params.
- Depends on: Task 10.

- [ ] **Step 1:** Write the docs.
- [ ] **Step 2:** Verify each guard name exists (`grep -rn '<name>' internal cmd`).
- [ ] **Step 3:** `git add`, `bash scripts/leak-check.sh --staged` → clean.
- [ ] **Step 4:** Commit `docs(automations): P6 inventory, QC-02 and AGENT notes`.

### Phase gate (controller, once)

- [ ] `bash scripts/dev-health.sh` → not overloaded.
- [ ] `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...` (logs to files, explicit exit codes); `pgrep` for any stub/fake-server process → none after the run.
- [ ] Manual (owner, business spec "How we know it's done"): each of the five gallery templates installs, dry-runs on real data and runs on its trigger; record the result on the board.
- [ ] local-review, then one PR `feature/automations-p6 → feature/automations`.

---

## Self-review against the spec

- §5 `mcp` (Go-side client, enabled connection, QC-02 only, 30 s) → Tasks 1–3; §14.7 QC-02 amendment (D20, ask #272) → Tasks 2, 11; D21/D22 (ask #273) in the agent tool set → Task 4; §3.2 mcp matching order (server exact → glob → QC-02 verdict) → Tasks 2–3; §3.4 no secrets to scripts or children → Tasks 1, 6, 7.
- §5/§6.5 `agent` — effective set intersection, budget ≤ remainder, `{text, actions}`, iterations ≤ 12, tokens per model call, no `wait`, proposals stay pending, runtime B for ollama, headless CLI with `--surface automation --automation-run N`, `--allowedTools` = effective set, run marker in the environment (D3) → Tasks 4–7; §4 dry run (`mcp` real, `agent` without writes) → Tasks 3, 5, 7.
- §7.5 / D4 tokens, not dollars → Task 7 (`reported_cost_usd` only when a provider reports it).
- §10 `templates`, `install-template`; §12.3 installed unconfirmed; §15 the five templates with their exact triggers/permissions/outputs; D13 PR comments via `session()` → Tasks 8–10.
- §18 P6 tests: `TestMCP_OnlyQC02AllowedTools`, `TestAgent_ToolSetIsIntersection`, `TestAgent_BudgetCarvedFromRun`, `TestAgent_WritesStayProposals`, `TestTemplates_AllParseAndValidate`, `TestTemplates_DryRunE2E` — all present (plus `TestTemplates_RunE2E`).
- Not in P6: the gallery UI (P3, over `templates --json`), `session()`/`shell()` themselves (P5), an External `add_pr_comment` tool (D13 follow-up).
