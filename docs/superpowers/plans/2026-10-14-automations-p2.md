# Automations P2 (writes) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an automation change the world only through the registry: the `automation` surface on the ten write tools of spec §6.1, `tool(name, args, {wait})` writes as proposals (trust `ask` by default), the per-(automation, tool) **auto grant** bound to `approval_hash` (migration 00114, granted only by the owner from the Desktop, refused under AGENT-07 markers), the AGENT-03 amendment exactly as spec §14.2, output kinds `briefing`/`target`/`slack` through `RegisterOutputKind`, the briefing section, and proposal rows that carry their automation run (`context_type='automation_run'`, `context_id=<run>`) so the Inbox labels them `⚙ <automation name> · run #<n>` — the Swift card label itself is P3 Task 12 (`runLabels`, `AgentActionCardLabelTests`), where spec §6.3 puts it and where the P3 plan already implements it.

**Architecture:** Every SDK write is `Registry.Propose` with `Binding{Surface: "automation", ContextType: "automation_run", ContextID: <run>, AutomationRunID: <run>, WorkbenchID: <wb or 0>}`. `resolveTrust` gets an automation-surface branch (AlwaysAsk → grant → External → `tool_trust(tool,'automation')`); a grant row applies only while `grant_hash = automations.approval_hash = automation_runs.recipe_hash`. An inline apply goes through `applyTrusted` → `Apply`'s claim (AGENT-05). `{wait:true}` pauses the run on P1's `Waiter` until the `agent_actions` row is `applied`/`rejected`/`failed`. Grants are written only by `watchtower automations auto <id> <tool> on --hash <sha>`.

**Tech Stack:** Go 1.26, SQLite (goose migration 00114), goja (P1), cobra; Swift (WatchtowerCore) for the Settings surface label only.

**Spec:** `docs/superpowers/specs/2026-10-14-automations-design.md` — §5 (`tool`, `output.*`), §6 (surface, trust order, auto grants), §9.4, §10 (`automations auto`), §12.6 (briefing), §14.2 (AGENT-03 amendment, owner-approved ask #265), §14.3, §18 P2 tests, §20 (D5, D14). Business spec: `docs/superpowers/specs/2026-10-14-automations-business.md`. P1 plan and its **Seams for later phases**: `docs/superpowers/plans/2026-10-14-automations-p1.md`.

**Branch:** `feature/automations-p2` → PR into `feature/automations`. Never `main`. Depends on P1 merged into `feature/automations`. May run as a parallel lane with P4 (P2 touches the registry, P4 the sync phases).

**Header notes (seams):**
- This plan consumes P1's seam names exactly as P1's "Seams for later phases" settles them (`db.EnqueueAutomationRun`, `automations.Env`, `Module`/`Definer`/`SDKFunc`, `DefaultModules`, `Waiter`, `Journal`/`Step`, `ToolRegistry`, `Backends`, `db.ConfirmAutomation`, `automationstest.*`).
- **Seam changes settled in P1** (P2 consumes them, adds no parallel name):
  - **S1** `ToolCapability.ScopeOf(ctx, d, args) ([]CallScope, error)` and `(*Manifest).AllowTool(ctx context.Context, d *db.DB, t *tools.Tool, args json.RawMessage) (string, error)`; P1's `ToolCapabilities` already lists the ten write tools with their real argument names (`project_key`, `key`, `account_id` resolved to a label) and P1 Task 4 pins their scope tests.
  - **S2** `OutputModule()` returns `*OutputMod` with `RegisterOutputKind(kind string, fn SDKFunc)`; P2 registers `briefing`/`target`/`slack` in `DefaultModules(b)` with closures over `b`.
  - **S3** a later `Define` of the same path replaces the earlier one (`TestDefiner_LaterModuleReplacesPath`, P1 Task 6); `ToolWriteModule` replaces `tool` this way and delegates reads to P1's read function.
  - **S4** `(*Step).ID() int64` and `(*Step).Mark(status string, link db.StepFinish) error` (non-final; P2 passes `db.StepFinish{ActionID: id}`).
- **Owned by P2 (S8, asked for by P6):** `tools.Binding.AutomationAgent bool`, added together with `AutomationRunID` in Task 3: on the `automation` surface a binding with `AutomationAgent` always resolves to `ask`, so a write made inside P6's `agent()` stays a pending proposal even under an active grant or an `execute` trust row (spec §6.5). A narrowing of the AGENT-03 exception, never a widening.
- **Owned by P2, consumed by P6:** `(*Manifest).AdmitsTool(t *tools.Tool) bool` — the single "admitted by name" rule (Task 1); `AdmitsWrite` is built on it and P6's `EffectiveAgentTools` uses it instead of a second copy.

## Global Constraints

- All repo text English; the repo is public — fixtures use `acme`, `example.com`, `<corp-domain>`, Slack labels like `work`; no real ids, no local absolute paths (`t.TempDir()`).
- Inner loop only: `go test ./internal/<pkg>` (no reflexive `-count=1`), `go test ./cmd -run '<Name>'` (never the whole `./cmd` per task), `make test-swift FILTER=<Class>`, `make lint-diff`. The full gate (`make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`) runs once at the end of the phase, by the controller.
- Tests that start a subprocess kill its process group and wait for it in `t.Cleanup` (P2 starts none; keep it so).
- Transactions `BEGIN IMMEDIATE`; never hold a write tx across a tool `Execute`, an LLM call or script execution.
- Migration **00114** (`automation_tool_grants`). Before merging, re-check `internal/db/migrations` on `origin/main`; if taken, renumber and verify by table presence, not goose version.
- Pinned values (spec, do not change without the spec):
  - Surface `"automation"`, context type `"automation_run"`; `Binding.AutomationRunID int64`, `Binding.AutomationAgent bool` (S8); `DirectApply` is never set for an automation binding.
  - Write tools that gain `"automation"` in `Surfaces`: `create_target`, `create_idea`, `create_track`, `remind_me`, `create_jira_issue`, `add_jira_comment`, `transition_jira_issue`, `assign_jira_issue`, `update_jira_issue`, `send_slack_message`. **Not** offered: `connect_jira_board`, `dismiss_tracks`, `edit_confluence_page`, `brief_context`, every workbench tool.
  - Trust order on the `automation` surface, first match wins: (1) `AlwaysAsk` → `ask`; (1a) `Binding.AutomationAgent` → `ask` (S8, spec §6.5: `agent()` proposals stay pending); (2) an active grant (`grant_hash = automations.approval_hash = automation_runs.recipe_hash`) → `execute` (External included); (3) `External` → `ask`; (4) `tool_trust(tool, 'automation')`, `ask` when absent. Every other surface keeps today's order unchanged.
  - An auto write = one `agent_actions` row, `trust_at_create='execute'`, `context_type='automation_run'`, `context_id=<run id>`, applied through `Apply`'s claim, plus an `auto=1` step with `status='applied'`.
  - `automations auto <id> <tool> on --hash <sha>`: refused under AGENT-07 markers (incl. `WATCHTOWER_AUTOMATION_RUN_ID`), refused when `<sha>` ≠ current `approval_hash`, refused for an `AlwaysAsk` tool, refused for a tool the manifest does not admit as a write. `… off` is open to anyone. A save never carries grants over (D5: only script/permissions/outputs/scope change the hash).
  - `{wait:true}` → `waiting_reason='approval'`; resolves `applied` → `{status:"applied", id, result}`, `rejected` → `{status:"rejected", id}`, `failed` → `{status:"failed", id, error}`; waiting time is excluded from active time; past `pause_timeout_hours` → run `expired`; Cancel → run `cancelled`, the proposal stays pending.
  - Dry run: a write never reaches the registry → `{status:"dry_run"}`; `output.*` and `state.set` likewise (AUTO-12).
  - Briefing section "From your automations": `automation_outputs.kind='briefing'` created since the previous briefing's `created_at`, titles + bodies, bounded to **4 KiB** total, oldest dropped first with a `+N more` line.
  - Inbox card label `⚙ <automation name> · run #<n>`: rendered by P3 Task 12 from the row context this plan pins (Task 3).
- Guard tests named `TestAgent03_…`, `TestAuto0N_…`, `TestAgent01_…` exactly as spec §14.2/§18; never weakened; existing AGENT guards unchanged.

## Review Focus

1. **A grant row for automation A must never apply to automation B, another surface, or a run claimed before a recipe edit** — the grant check joins run → automation → grant on all three hashes. Pinned in Task 3 (`TestAgent03_AutoGrantNeverCoversAnotherAutomationOrSurface`, `TestAgent03_RecipeEditMakesAutoGrantInactive` incl. the "run claimed with the old hash, recipe re-confirmed with a new hash and re-granted" case → still `ask` for the old run).
2. **An auto-applied `send_slack_message` whose `Normalize` pinned several candidate workspaces** — `Ready` fails, so the row must be recorded pending for the owner to pick, never applied-then-failed. Pinned in Task 3 (`TestAutoGrant_NotReadyRecordsPending`).
3. **A workbench automation's proposal** — the row keeps `context_type='automation_run'` (not `project`), so it reaches the Inbox strip and its card label; `Apply` later rebuilds `AutomationRunID`. Pinned in Task 3 (`TestProposalRow_WorkbenchAutomationKeepsRunContext`).
4. **`{wait:true}` across a run cancel, a pause timeout and the owner approving after the run already ended** — the waiting goroutine ends, the run ends `cancelled`/`expired`, the proposal stays pending and its later apply touches no run row. Pinned in Task 5 (`TestToolWait_CancelLeavesProposalPending`, `TestToolWait_ExpiresAfterPauseTimeout`, `TestToolWait_ApproveAfterRunEndedChangesNoRun`).
5. **A script that omits `reason`** — the SDK supplies a default reason so the registry's mandatory-reason gate does not fail every scripted write, and a script-given reason is kept verbatim. Pinned in Task 5 (`TestToolWrite_DefaultReason`).
6. **The briefing prompt verb count** — adding a `%s` section must not break a stored customised template (the existing count-mismatch fallback). Pinned in Task 7 (`TestBriefing_StoredTemplateWithOldVerbCountFallsBack`).

---

## File structure

| Path | Responsibility |
|---|---|
| `internal/automations/manifest.go` | `AdmitsTool`, `AdmitsWrite` (scope resolution is P1's) |
| `internal/db/migrations/00114_automation_tool_grants.sql`, `internal/db/schema.sql` | grants table |
| `internal/db/automation_grants.go` | grant store + active-grant join |
| `internal/tools/registry.go` | `Binding.AutomationRunID`, `Binding.AutomationAgent`, `bindingOf`, `newProposalRow`, automation trust branch, `Receipt.Auto` |
| `internal/tools/{targets,ideas,tracks,remind,jira,jira_write,slack_send}.go` | `"automation"` in `Surfaces` |
| `cmd/actions_registry_test.go` (wherever `TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces` lives) | pin update |
| `internal/automations/sdk_tool_write.go`, `sdk_output_p2.go`, `modules.go` | `ToolWriteModule`, output kinds |
| `internal/briefing/automations.go`, `internal/briefing/pipeline.go`, `internal/prompts/defaults.go` | briefing section |
| `cmd/automations_auto.go`, `cmd/automations.go` (show/list) | CLI |
| `WatchtowerDesktop/Sources/WatchtowerCore/Models/AssistantToolSurface.swift` | Settings surface label |
| `docs/inventory/agent-actions.md`, `docs/inventory/automations.md`, `docs/inventory/reaction-commands.md` (changelog only), `docs/features/agent-actions.md`, `docs/features/automations.md` | docs |

---

### Task 1: Manifest — `AdmitsTool` and `AdmitsWrite`

**Files:**
- Modify: `internal/automations/manifest.go`, `internal/automations/manifest_test.go`

**Interfaces:**
- Consumes: P1 `ToolCapability`, `ToolCapabilities` (the write-tool entries and their `ScopeOf` already exist, S1), `(*Manifest).AllowTool(ctx, d, t, args)`, `PermissionDenied`.
- Produces:
  - `func (m *Manifest) AdmitsTool(t *tools.Tool) bool` — the single "admitted by name" rule: `t.VisibleOn("automation")` and the manifest has `tool:<name>`, or a `<capability>:<verb>[@any scope]` entry for the tool's `ToolCapabilities` capability+verb, or (for `create_target`/`send_slack_message`) `outputs` contains `target`/`slack`. It ignores call arguments (scope is checked per call by `AllowTool`). P6's `EffectiveAgentTools` consumes it.
  - `func (m *Manifest) AdmitsWrite(t *tools.Tool) bool` — `t.Access == AccessWrite && !t.AlwaysAsk && m.AdmitsTool(t)`. Used by `automations auto … on` (Task 8).
- Depends on: none (P1 merged).

- [ ] **Step 1: Failing tests** in `manifest_test.go` (the write-tool scope tests — `TestManifest_JiraScopeFromRealArgs`, `TestManifest_SlackWriteScopeByAccountLabel`, `TestManifest_ScopeOfErrorIsADeniedNotAPanic` — are P1 Task 4's; they stay green here unmodified):
  - `TestManifest_AdmitsTool` — table: `jira:read@PAY` → true for `list_jira_issues` and `get_jira_issue`, false for `create_jira_issue`; `targets:read` → true for `list_targets`; `tool:get_confluence_page` → false (not on the surface); `outputs:[slack]` → true for `send_slack_message`.
  - `TestManifest_AdmitsWrite` — table: `tool:create_target` → true; `outputs:[target]` → true for `create_target`; `jira:write@PAY` → true for `create_jira_issue`; `jira:read@*` → false; `dismiss_tracks` with `tool:dismiss_tracks` → false (AlwaysAsk, not on the surface); a read tool → false.
  - `TestToolCapabilities_CoversEveryAutomationTool` extended to the ten P2 write tools (now visible on `automation` in the real registry, Task 4 — run this sub-test after Task 4 lands).
- [ ] **Step 2:** `go test ./internal/automations -run 'TestManifest|TestToolCapabilities'` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 command and `go test ./internal/automations` → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): AdmitsTool and AdmitsWrite in the manifest`.

### Task 2: Migration 00114 and the grant store

**Files:**
- Create: `internal/db/migrations/00114_automation_tool_grants.sql`, `internal/db/automation_grants.go`, `internal/db/automation_grants_test.go`
- Modify: `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), golden snapshot + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerate)

**Interfaces:**
- Consumes: P1 tables `automations`, `automation_runs`.
- Produces (package `db`):
  - Table `automation_tool_grants(automation_id INTEGER NOT NULL REFERENCES automations(id) ON DELETE CASCADE, tool TEXT NOT NULL, grant_hash TEXT NOT NULL, granted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')), PRIMARY KEY (automation_id, tool))` (spec §9.4).
  - `type AutomationToolGrant struct { AutomationID int64; Tool, GrantHash string; GrantedAt time.Time; Active bool /* grant_hash = automations.approval_hash */ }`.
  - `func (d *DB) SetAutomationToolGrant(automationID int64, tool, hash string, now time.Time) error` — one tx: refuses with `ErrHashMismatch` (P1's) unless `hash` equals the row's current `approval_hash`; upserts (a re-grant writes the new hash).
  - `func (d *DB) DeleteAutomationToolGrant(automationID int64, tool string) (bool, error)`.
  - `func (d *DB) ListAutomationToolGrants(automationID int64) ([]AutomationToolGrant, error)` (tool order, `Active` computed).
  - `func (d *DB) ActiveAutomationToolGrant(runID int64, tool string) (bool, error)` — one SELECT joining `automation_runs r` → `automations a` → `automation_tool_grants g` on `g.automation_id = r.automation_id AND g.tool = ?` with `g.grant_hash = a.approval_hash AND g.grant_hash = r.recipe_hash AND a.approval_hash <> ''`.
- Depends on: none.

- [ ] **Step 1: Failing tests:**
  - `TestMigration00114_GrantsTable` — table + PK; deleting the automation cascades its grants.
  - `TestGrant_SetRefusesStaleHash` — `SetAutomationToolGrant(id, tool, "other")` → `ErrHashMismatch`, no row.
  - `TestGrant_ActiveRequiresAllThreeHashes` — table: grant=approval=run → true; run claimed with an older `recipe_hash` → false; approval changed (rescan) → false; another automation's run → false; another tool → false; `approval_hash=''` → false.
  - `TestGrant_ListMarksInactive` — after `approval_hash` changes, `Active=false`; a re-grant with the new hash → `Active=true`.
  - Add the table to `TestAllTablesExist`.
- [ ] **Step 2:** `go test ./internal/db -run 'TestMigration00114|TestGrant_|TestAllTablesExist'` → FAIL.
- [ ] **Step 3:** Migration (Up + Down), schema mirror, store.
- [ ] **Step 4:** `go test ./internal/db -run 'TestSchemaGolden|TestDesktopTestSchema' -update`, then Step 2 → PASS; `go test ./internal/db` → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): migration 00114 automation_tool_grants`.

### Task 3: Registry — binding, proposal row, automation trust order (AGENT-03 amendment in code)

**Files:**
- Modify: `internal/tools/registry.go`
- Create: `internal/tools/registry_automation_test.go`

**Interfaces:**
- Consumes: `db.ActiveAutomationToolGrant` (Task 2); `AutomationSurface`, `AutomationContextType` (P1).
- Produces:
  - `Binding` gains `AutomationRunID int64` (doc comment: set only by the automations executor; never with `DirectApply`) and `AutomationAgent bool` (S8, doc comment: set only for calls made inside an automation's `agent()` — P6's runtime B and its `--surface automation` MCP server; not persisted, a later `Apply` does not need it).
  - `Receipt` gains `Auto bool \`json:"auto,omitempty"\`` — true only when the automation grant decided `execute` (not for a `tool_trust` execute).
  - `newProposalRow`: when `b.AutomationRunID != 0`, `context_type='automation_run'`, `context_id=<run id>` **even when `b.WorkbenchID != 0`** (the workbench context is not written for automation rows).
  - `bindingOf`: `context_type='automation_run'` → `AutomationRunID` parsed from `context_id` (malformed → 0).
  - `resolveTrust(t, b)`: on `b.Surface == AutomationSurface` the §6.2 order with the `AutomationAgent` step after AlwaysAsk (Global Constraints); returns `(Trust, auto bool, error)` internally; every other surface byte-unchanged.
  - `admitProposal`: a binding with `Surface == AutomationSurface` and `DirectApply` → `*ValidationError` ("automations never apply directly").
  - Grant path readiness: when the grant decided `execute` and the tool has `Ready` that rejects the normalized args, the row is recorded `pending` with `trust_at_create='ask'` and `Receipt.Auto=false`.
- Depends on: Task 2.

- [ ] **Step 1: Failing tests** (`registry_automation_test.go`, a file DB, a fake External write tool `ext_write`, a fake local tool `local_write`, a fake AlwaysAsk tool `bulk_write`, all with `Surfaces` incl. `automation`; automations and runs seeded via `automationstest.SeedAutomation` + `db.EnqueueAutomationRun` + `db.ClaimAutomationRun`):
  - `TestTrustOrder_AutomationSurface` — table over (AlwaysAsk, AutomationAgent, grant, External, tool_trust): AlwaysAsk + grant → `ask`; External + active grant → `execute`, `Auto=true`; External, no grant → `ask`; local + `tool_trust(local_write,'automation')='execute'` → `execute`, `Auto=false`; local, no row → `ask`; local + execute on `main` only → `ask`; `AutomationAgent: true` + active grant → `ask`; `AutomationAgent: true` + `tool_trust` execute → `ask` (S8).
  - `TestAgent03_AutoGrantAppliesExternalOnlyOnAutomationSurfaceWithMatchingHash` — grant active → one row `applied`, `trust_at_create='execute'`, `context_type='automation_run'`, `context_id=<run>`, `Execute` called once through `Apply`'s claim (`executing` seen by a hooking fake).
  - `TestAgent03_AutoGrantNeverCoversAnotherAutomationOrSurface` — grant for automation A: a run of B → pending; the same tool on `main` with B's run id in the binding → pending; on `target` → pending.
  - `TestAgent03_RecipeEditMakesAutoGrantInactive` — rescan with a changed script (new `approval_hash`) → pending; owner re-confirms + re-grants with the new hash, but the run claimed before still carries the old `recipe_hash` → pending; a new run → applied.
  - `TestAgent03_AlwaysAskIsNeverAuto` — `bulk_write` with a grant row forced in by raw SQL and `tool_trust` execute forced by `db.SetToolTrust` → pending.
  - `TestAgent01_AutomationWriteRecordsProposalOnly` — no grant, no trust: exactly one `pending` row, guard tables row-count-identical (reuse the `guardTables` helper pattern), `Execute` not called.
  - `TestAutoGrant_NotReadyRecordsPending` — fake External tool with `Ready` failing (candidates) + active grant → `pending`, `trust_at_create='ask'`, `Auto=false`, nothing executed.
  - `TestProposalRow_WorkbenchAutomationKeepsRunContext` — binding with `WorkbenchID: 3, AutomationRunID: 9` → row `context_type='automation_run'`, `context_id='9'`; `Apply` later sees `AutomationRunID: 9`.
  - `TestAutomationBinding_DirectApplyRefused`.
  - Existing guards (`TestAgent03_ExternalToolCannotBeExecuteTrust`, `TestAgent05_*`, `TestAgent01_*`) unchanged and green.
- [ ] **Step 2:** `go test ./internal/tools -run 'TestTrustOrder|TestAgent03|TestAgent01|TestAutoGrant|TestProposalRow|TestAutomationBinding|TestAgent05'` → FAIL (new ones).
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 command and `go test ./internal/tools` → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): automation trust order and auto grants in the registry (AGENT-03 amendment)`.

### Task 4: The `automation` surface on the ten write tools

**Files:**
- Modify: `internal/tools/targets.go`, `ideas.go`, `tracks.go` (`create_track` only), `remind.go`, `jira.go`, `jira_write.go` (four tools), `slack_send.go`; the `TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces` pin; `WatchtowerDesktop/Sources/WatchtowerCore/Models/AssistantToolSurface.swift`, `WatchtowerDesktop/Tests/Core/AssistantToolSurfaceTests.swift`

**Interfaces:**
- Consumes: `tools.AutomationSurface`.
- Produces: each of the ten tools' `Surfaces` gains `"automation"`; `remind_me` on the automation surface uses only the script's explicit `message_ref` (`reminderRef` already does this for every non-reaction surface); `send_slack_message` keeps `ProposeUnderDirectApply` (irrelevant here: no DirectApply); `AssistantToolSurface.label(for: "automation")` → `"Automations"`. `SetTrust(tool, "automation", …)` now works for the local five (External/AlwaysAsk still refused by the existing checks).
- Depends on: Task 3.

- [ ] **Step 1: Failing tests:**
  - `TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces` updated to the new surface lists (exact sets; `connect_jira_board`, `dismiss_tracks`, `edit_confluence_page`, `brief_context` and the workbench tools explicitly without `automation`).
  - `TestSetTrust_AutomationSurface` — `create_idea` execute on `automation` → ok; `send_slack_message` → `ErrExternalExecute`; `connect_jira_board` on `automation` → `ErrSurfaceNotOffered`.
  - `TestActionsTools_ListsAutomationTrust` (`cmd`) — `actions tools --json` shows `trust_by_surface.automation` for the five local tools.
  - Swift `AssistantToolSurfaceTests.testAutomationLabel`.
- [ ] **Step 2:** `go test ./cmd -run 'TestBuildToolRegistry_Pins|TestActionsTools_ListsAutomationTrust'`, `go test ./internal/tools -run TestSetTrust_AutomationSurface`, `make test-swift FILTER=AssistantToolSurfaceTests` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 commands → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): offer the ten write tools on the automation surface`.

### Task 5: SDK writes — `ToolWriteModule`, `{wait}`, dry run

**Files:**
- Create: `internal/automations/sdk_tool_write.go`, `internal/automations/sdk_tool_write_test.go`
- Modify: `internal/automations/modules.go` (`DefaultModules` appends `ToolWriteModule`), `internal/automations/sandbox.go`'s `(*Env).Binding()` (sets `AutomationRunID`), `internal/automations/automationstest/fakes.go` (`FakeRegistry` records `Propose` with a configurable `Receipt`)

**Interfaces:**
- Consumes: `ToolRegistry.Propose` (P1 interface), `Waiter.Wait(ctx, db.WaitApproval, ready)`, `db.GetAgentAction`, `(*Manifest).AllowTool(ctx, Backends.DB, t, args)` (P1, S1), the S3 last-wins `Define` and S4 `(*Step).Mark` (P1), `Meter`, `Journal`.
- Produces:
  - `func ToolWriteModule(b Backends) Module` — defines `tool(name, args, opts?)`; reads delegate to P1's read function unchanged; writes: manifest check → (dry run: step `dry_run`, `{status:"dry_run"}`, registry untouched) → default `reason` when the args have none or a blank one: `"⚙ <automation name> · run #<run id>"` → `Registry.Propose(ctx, name, args, env.Binding())` → step `proposed` with `action_id` (or `applied` + `auto=1` when `Receipt.Auto`, or `applied` without auto for a `tool_trust` execute, or `failed` for an inline apply that failed) → return `{status:"proposed", id}` / `{status:"applied", id, result}` / `{status:"failed", id, error}`.
  - `opts.wait === true` on a `pending` receipt: `step.Mark("waiting", db.StepFinish{ActionID: id})`, then `env.Wait.Wait(ctx, db.WaitApproval, ready)` where `ready` reads `agent_actions.status` ∈ {`applied`,`rejected`,`failed`}; resumes and finishes the step with that status → `{status:"applied", id, result}` / `{status:"rejected", id}` / `{status:"failed", id, error}`. `wait` on an already applied receipt returns at once. `opts` other than `wait` → `ValidationError`.
  - `(*Env).Binding()` → `{Surface: "automation", ContextType: "automation_run", ContextID: <run id>, AutomationRunID: <run id>, WorkbenchID: <project id or 0>}`.
  - Registry `*ValidationError` → JS `ValidationError`; `ErrNotWritable`/unknown tool → `ToolError`.
- Depends on: Tasks 1, 3, 4.

- [ ] **Step 1: Failing tests** (`sdk_tool_write_test.go`; executor-level ones use a real `tools.Registry` over a file DB with fake tool factories; `automationstest.FakeClock`):
  - `TestAuto02_ToolWriteGoesThroughPropose` — `tool("create_target", {...})` with `tool:create_target` → one `agent_actions` row `pending`, `context_type='automation_run'`; `targets` row count unchanged; returns `{status:"proposed", id}`; step `proposed` with `action_id`.
  - `TestToolWrite_PermissionDeniedTouchesNothing` — `jira:write@PAY`, `create_jira_issue{project_key:"OPS"}` → `PermissionDenied`, zero rows.
  - `TestToolWrite_AutoGrantStepIsAppliedAuto` — active grant → `{status:"applied", id, result}`, step `applied`, `auto=1`.
  - `TestToolWrite_TrustExecuteStepIsAppliedNotAuto` — `tool_trust(create_idea,'automation')='execute'` → step `applied`, `auto=0`.
  - `TestToolWrite_DefaultReason` — no `reason` → stored `reason` = `⚙ New mail summary · run #<id>`; a script-given reason kept verbatim.
  - `TestToolWait_AppliedRejectedFailed` — three sub-tests: a helper goroutine moves the row to `applied` (via `Registry.Approve` + `Apply`), `rejected`, `failed`; script receives the matching object; run `waiting` with `waiting_reason='approval'` while blocked, back to `running` after; step ends with the final status.
  - `TestToolWait_PauseExcludedFromActiveTime` — budget 1 minute, the wait lasts 10 fake minutes, run still `succeeded`; `active_ms` < 60000.
  - `TestToolWait_ExpiresAfterPauseTimeout` — `pause_timeout_hours: 1`, fake clock +61 min → run `expired`, row still `pending`.
  - `TestToolWait_CancelLeavesProposalPending` — `automations cancel` path (`db.CancelAutomationRun`) mid-wait → run `cancelled`, row `pending`.
  - `TestToolWait_ApproveAfterRunEndedChangesNoRun` — after `expired`, approve + apply the row → `automation_runs` row byte-identical.
  - `TestAuto12_DryRunWriteNeverReachesRegistry` — dry run: `tool("create_target")` and `{wait:true}` → `{status:"dry_run"}` at once, zero `agent_actions`, step `dry_run` with the would-be args.
  - `TestToolWrite_UnknownOptionIsValidationError`.
- [ ] **Step 2:** `go test ./internal/automations -run 'TestAuto02|TestToolWrite|TestToolWait|TestAuto12_DryRunWrite'` → FAIL (P1's `TestDefiner_LaterModuleReplacesPath` stays green).
- [ ] **Step 3:** Implement (P1's `TestTool_WriteNotAvailableInP1` is retired in this commit and replaced by `TestAuto02_ToolWriteGoesThroughPropose` — it pinned P1's interim branch, not a contract; note it in the AUTO-02 changelog).
- [ ] **Step 4:** Step 2 command → PASS; `go test -race ./internal/automations -run 'TestToolWait'` once.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): tool writes as proposals with wait`.

### Task 6: Output kinds `briefing`, `target`, `slack`

**Files:**
- Create: `internal/automations/sdk_output_p2.go`, `internal/automations/sdk_output_p2_test.go`
- Modify: `internal/automations/modules.go` (`DefaultModules` registers the three kinds on P1's `*OutputMod`)

**Interfaces:**
- Consumes: `(*OutputMod).RegisterOutputKind(kind string, fn SDKFunc)` (P1, S2), `(*Manifest).AllowOutput`, `(*CommitBuffer).AddOutput`, Task 5's write function.
- Produces:
  - `output.briefing({title, body})` — gate `outputs:[briefing]`; buffered `automation_outputs` row `kind='briefing'` committed only on `succeeded` (AUTO-04); body ≤ 64 KiB.
  - `output.target({...create_target args})` — gate `outputs:[target]` only (no `tool:create_target` needed); the Task 5 write path with tool `create_target`; one argument, never waits; step `kind='output'`, `name='target'`, status/`action_id`/`auto` as a tool write; `permission='outputs:target'`.
  - `output.slack({...send_slack_message args})` — same with `outputs:[slack]`, tool `send_slack_message` (External: a proposal unless an active grant).
  - Dry run: all three → `{status:"dry_run"}`, nothing buffered, no registry call.
- Depends on: Task 5.

- [ ] **Step 1: Failing tests:**
  - `TestOutput_BriefingBufferedAndCommittedOnSuccess` — succeeded → one `kind='briefing'` row; `failed` run → none (AUTO-04).
  - `TestOutput_TargetGateIsOutputsNotTool` — `outputs:[target]` without `tool:create_target` → proposal; `tool:create_target` without `outputs:[target]` → `output.target` throws `PermissionDenied` with `needed` `outputs:target`.
  - `TestOutput_SlackIsAProposalUnlessGranted` — no grant → `pending`; active grant on `send_slack_message` → `applied`, `auto=1`.
  - `TestOutput_P2KindsDryRun`.
  - `TestRegisterOutputKind_UnknownKindStillRefused` — `output.email(...)` → `TypeError`/undefined (no such kind).
- [ ] **Step 2:** `go test ./internal/automations -run 'TestOutput_|TestRegisterOutputKind'` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 command → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): briefing, target and slack outputs`.

### Task 7: Briefing section "From your automations"

**Files:**
- Create: `internal/briefing/automations.go`, `internal/briefing/automations_test.go`
- Modify: `internal/briefing/pipeline.go` (`RunForDate`: gather, `hasAnyData`, one more `Sprintf` argument), `internal/prompts/defaults.go` (`defaultBriefingDaily` gains one `%s` block; version bump 11 → 12 with a changelog comment), `internal/prompts/defaults_extra_test.go` if it pins verb counts, `internal/db/automation_runs.go` (`ListAutomationOutputsSince`, a P2 read helper — P1's `ListAutomationOutputs(kind, limit)` has no time filter and no automation name)
- Use the project skill `add-ai-prompt` for the template change.

**Interfaces:**
- Consumes: the new `func (d *DB) ListAutomationOutputsSince(kind string, since time.Time) ([]NamedAutomationOutput, error)` with `type NamedAutomationOutput struct { AutomationOutput; AutomationName string }` (ascending `created_at`, joined automation name; added by this task); `(*Pipeline).revisionWindowStart(userID, date)` — already "the previous day's briefing generation time, else 24 h".
- Produces: `func (p *Pipeline) gatherAutomationOutputs(since time.Time) (string, bool)` — block titled `From your automations`, one entry per output `⚙ <automation name>: <title>\n<body>`; total ≤ 4096 bytes: while over, drop the **oldest** entry and end with `+N more` (N = dropped count); no outputs → the placeholder `No automation output since the last briefing.` and `false`. `hasAnyData` counts it as real material. Prompt v12 tells the model to fold these items into `what_happened` (or `attention` when their priority is high) and never invent ids for them.
- Depends on: Task 6.

- [ ] **Step 1: Failing tests:**
  - `TestBriefing_IncludesAutomationOutputsSinceLast` — outputs before and after the previous briefing's `created_at` → only the later ones in the prompt (FakeGenerator captures the system prompt).
  - `TestBriefing_AutomationSectionBoundedTo4KiBOldestDropped` — ten 1 KiB bodies → section ≤ 4096 bytes, the newest kept, ends `+N more` with the right N.
  - `TestBriefing_AutomationOutputsAloneCountAsData` — no digests/tracks/targets, one briefing output → briefing generated.
  - `TestBriefing_StoredTemplateWithOldVerbCountFallsBack` — a stored v11 template (old `%s` count) → the default v12 used, log line present.
  - `TestBriefing_OnlyKindBriefingIncluded` — `inbox`/`report` outputs never appear.
- [ ] **Step 2:** `go test ./internal/briefing -run TestBriefing_` and `go test ./internal/prompts` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 commands → PASS; `go test ./internal/briefing ./internal/prompts` → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): briefing section for automation outputs`.

### Task 8: `watchtower automations auto` and grants in `show`/`list`

**Files:**
- Create: `cmd/automations_auto.go`, `cmd/automations_auto_test.go`
- Modify: `cmd/automations.go` (`show --json`: `grants: [{tool, active, granted_at}]`; `list --json`: `auto_paused: bool` when any grant is inactive), `cmd/actions.go` only if the refusal helper needs a new verb string

**Interfaces:**
- Consumes: `refuseUnderAgent(verb)` (existing, markers incl. `WATCHTOWER_AUTOMATION_RUN_ID` from P1), `db.SetAutomationToolGrant`, `db.DeleteAutomationToolGrant`, `db.ListAutomationToolGrants`, `(*Manifest).AdmitsWrite` (Task 1), `buildToolRegistry` (to resolve the tool), `automations.ParseRecipe` on `recipe_text`.
- Produces: `watchtower automations auto <id|slug> <tool> on --hash <sha> [--json]` and `watchtower automations auto <id|slug> <tool> off [--json]`. `on` order of checks: AGENT-07 markers → automation exists, parsed → tool exists in the registry → `!AlwaysAsk` (message names D14) → `AdmitsWrite` → `SetAutomationToolGrant` (stale hash → `ErrHashMismatch` → exit non-zero "the recipe changed; reload and confirm again"). `off` is open to anyone, idempotent (exit 0 when no grant).
- Depends on: Tasks 1, 2, 4.

- [ ] **Step 1: Failing tests:**
  - `TestAgent03_AutoGrantRefusedUnderAgentMarkers` — for each marker (`CLAUDECODE`, `CODEX_THREAD_ID`, `CODEX_SANDBOX`, `WATCHTOWER_TERMINAL_SESSION_ID`, `WATCHTOWER_AUTOMATION_RUN_ID`): `on` exits non-zero with the AGENT-07 recovery hint, no grant row; `off` under the marker still works.
  - `TestAutomationsAuto_RefusesStaleHashAlwaysAskAndNotAdmitted` — stale hash; `dismiss_tracks`; `create_jira_issue` with only `jira:read@*` → each refused, no row.
  - `TestAuto03_GrantInactiveAfterEditAndReactivatedByNewHash` — grant on; `automations save` with a changed script (owner, `--confirm-hash` new) → `show --json` grant `active:false`, `list --json` `auto_paused:true`; `auto … on --hash <new>` → active; a trigger/budget-only edit keeps it active (D5).
  - `TestAutomationsAuto_OffIsIdempotent`.
- [ ] **Step 2:** `go test ./cmd -run 'TestAgent03_AutoGrantRefused|TestAutomationsAuto|TestAuto03'` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 command → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): automations auto on/off, owner-only`.

### Task 9: Inventory, feature notes

**Files:**
- Modify: `docs/inventory/agent-actions.md`, `docs/inventory/automations.md`, `docs/inventory/reaction-commands.md` (changelog line only), `docs/features/agent-actions.md`, `docs/features/automations.md`, `docs/inventory/README.md` (module row gains `internal/db/automation_grants.go`, `cmd/automations_auto.go`)

**Interfaces:**
- Consumes: guard names from Tasks 1–8.
- Produces:
  - **AGENT-03**: Observable replaced by spec §14.2's text **verbatim** (incl. "owner-approved 2026-10-14 in ask #265; in code with Automations P2"); the Why gains §14.2's added sentence; Test guards append `TestAgent03_AutoGrantAppliesExternalOnlyOnAutomationSurfaceWithMatchingHash`, `TestAgent03_AutoGrantNeverCoversAnotherAutomationOrSurface`, `TestAgent03_RecipeEditMakesAutoGrantInactive`, `TestAgent03_AlwaysAskIsNeverAuto` (`internal/tools/registry_automation_test.go`), `TestAgent03_AutoGrantRefusedUnderAgentMarkers` (`cmd/automations_auto_test.go`); existing guards unchanged.
  - **AGENT-01** (strengthening): names the `automation` surface and "a dry run never reaches `Propose`"; guard `TestAgent01_AutomationWriteRecordsProposalOnly`, plus `TestAuto12_DryRunWriteNeverReachesRegistry`.
  - **AGENT-07** (strengthening): `automations auto … on` joins the refused commands (with `automations confirm` and `automations save --confirm-hash` from P1); guard `TestAgent03_AutoGrantRefusedUnderAgentMarkers`.
  - Changelog entry dated 2026-10-14 "Automations P2 — AGENT-03 amended per spec §14.2 (owner-approved, ask #265); the automation auto grant and `tool_trust` never cover a call made inside an automation's `agent()` (`Binding.AutomationAgent`, spec §6.5 'proposals stay pending') — a narrowing; AGENT-01/07 strengthened; no guard relaxed". AGENT-03's guard list also gains `TestTrustOrder_AutomationSurface` (its `AutomationAgent` rows).
  - **automations.md**: **AUTO-02** Planned → **Enforced** (write side: `TestAuto02_ToolWriteGoesThroughPropose`, `TestOutput_TargetGateIsOutputsNotTool`, `TestOutput_SlackIsAProposalUnlessGranted`; changelog notes the retirement of P1's interim `TestTool_WriteNotAvailableInP1`); **AUTO-03** Planned → **Enforced** (`TestAuto03_GrantInactiveAfterEditAndReactivatedByNewHash` + the five AGENT-03 guards); AUTO-04/12 gain the output and dry-run guards of Tasks 5–6.
  - **reaction-commands.md** changelog: "Automations P2: `agent_actions` rows with `context_type='automation_run'` reach the strip through `Registry.Propose` from a recipe the owner confirmed (AUTO-06), per the approved design §6.3; the STRIP-01 three-table amendment (spec §14.4, `automation_outputs`) lands with P3". STRIP-01's Observable text itself is not edited in P2.
  - `docs/features/agent-actions.md`: the automation surface, trust order and auto grants. `docs/features/automations.md`: P2 section.
- Depends on: Task 8.

- [ ] **Step 1:** Write the docs.
- [ ] **Step 2:** Every guard named in the inventories exists: `grep -rn '<name>' internal cmd WatchtowerDesktop/Tests` for each → found.
- [ ] **Step 3:** `git add` then `bash scripts/leak-check.sh --staged` → clean.
- [ ] **Step 4:** Commit `docs(automations): AGENT-03 amendment, AUTO-02/03 enforced`.

### Phase gate (controller, once)

- [ ] `bash scripts/dev-health.sh` → not overloaded.
- [ ] `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...` (logs to files, explicit exit codes).
- [ ] Re-check migration numbering against `origin/main`.
- [ ] local-review, then one PR `feature/automations-p2 → feature/automations`.

---

## Self-review against the spec

- §5 `tool` writes + `{wait}` → Task 5; `output.briefing/target/slack` → Task 6; §6.1 surface + `AutomationRunID` + `bindingOf` → Tasks 3–5; §6.2 trust order → Task 3; §6.3 row context → Task 3 (card label and run link: P3 Task 12); §6.4 grants + "a save never carries grants over" → Tasks 2, 8; §9.4 00114 → Task 2; §10 `automations auto` → Task 8; §12.6 → Task 7; §14.2 verbatim → Task 9; §14.3 AGENT-01/07 → Task 9; §18 P2 tests: `TestAgent01_AutomationWriteRecordsProposalOnly`, five AGENT-03 guards, `TestAuto03_GrantInactiveAfterEditAndReactivatedByNewHash`, `TestAuto02_ToolWriteGoesThroughPropose`, `TestToolWait_AppliedRejectedFailed`, `TestToolWait_PauseExcludedFromActiveTime`, `TestTrustOrder_AutomationSurface`, `TestBriefing_IncludesAutomationOutputsSinceLast`, updated `TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces` — all present.
- D5 (hash scope), D14 (AlwaysAsk never auto) → Tasks 2, 3, 8.
- Not in P2 (by spec): the STRIP-01 text amendment and output cards (P3), the run link from the card (P3), the Desktop's SIGUSR2 after an approval on an automation row (P3; P2 relies on the executor's 10 s poll, pinned by `TestToolWait_AppliedRejectedFailed` on the fake clock).
