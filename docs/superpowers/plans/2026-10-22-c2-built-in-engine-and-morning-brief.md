# C2 — Built-in Engine + Morning Brief Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the built-in automation engine (shipped recipes with `origin = 'builtin'`, the `sync` trigger, in-cycle runs, the AUTO-06 amendment, Edit / Reset / upgrade) and move the daily briefing + day plan onto it as the **Morning brief** built-in, keeping today's behaviour.

**Architecture:** One registry of built-ins (`internal/automations/builtin`) maps a `builtin_id` to its shipped recipe bytes (embedded), its cycle slot, its feature ids (the config `*.enabled` keys stay the on/off truth), its prompts and its card parameters. A built-in sync indexer keeps one `automations` row per built-in at the synthetic path `builtin:<id>`, sourced from the shipped bytes or from the owner's copy `<workspace>/automations/.builtin/<id>.md`. At its slot in `runSync` the daemon asks the entry's Go gate whether it is due and, only then, writes one `automation_runs` row and executes the recipe inline on a dedicated executor; the recipe's SDK calls `brief.compose` / `plan.compose` are Go primitives that wrap today's `internal/briefing` / `internal/dayplan` steps (tiers, role instruction, 3-attempt budgets, fresh-install bypass, idempotency, `pipeline_runs`) with the recipe's prompt text.

**Tech Stack:** Go 1.26 (goose SQL migration, goja sandbox, cobra), SQLite, SwiftUI (WatchtowerCore + Desktop app, GRDB, DesignKit).

**Spec:** `docs/superpowers/specs/2026-10-22-inbox-built-in-automations-design.md` (owner-approved, ask #500, including the AUTO-06 amendment §5.2 and the FEAT-01..03 amendment §5.4). This plan is part **C2** of §10. Read §4, §5.1–§5.4, §8, §9, §12 before any task.

## Global Constraints

- Branch off `main` after C1 (`One Inbox`) has merged; PR into `main`. Task 10's Inbox notice goes into C1's one pure read (`InboxFeedQueries.read` → `InboxFeedSnapshot`), C1's `InboxListBuilder.sections(_:filter:…)`, C1's `InboxFilter` table and C1's `badgeCount` body (C1 R1) — never a second read beside it (STRIP-02).
- Migration number: **00150** is the next free number today (latest is `00149_automation_inbox_actions.sql`) — re-check `ls internal/db/migrations | tail -1` immediately before writing the file and take the next free one.
- Every schema change is mirrored into `internal/db/schema.sql`, new tables join `TestAllTablesExist`, and the goldens + Swift test schema are regenerated: `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`.
- A table that is the parent of an `ON DELETE CASCADE` FK is rebuilt under `PRAGMA foreign_keys = OFF` with `-- +goose NO TRANSACTION` (the 00149 pattern), never `defer_foreign_keys`; carry every column, CHECK, index, trigger and the `sqlite_sequence` high-water mark.
- Go tasks verify with `go test ./internal/<pkg>` for the touched packages + `make lint-diff`. Tasks touching `cmd/` run `go test ./cmd -run '<Names>' -timeout 30m`.
- Swift tasks verify with `make lint-swift` + `make test-swift FILTER='<Classes>'` (core tests in `Tests/Core` where possible). `make lint-diff` does not check Swift.
- UI copy is English, built from `WatchtowerDesktop/Sources/DesignKit/` only; no sheets, popovers or modal confirmations for these flows (inline rows instead); add affordances use the "+" icon. Read `docs/design/desktop-style-guide.md` and `docs/review/review-rules.md` "Swift / Desktop conventions" first.
- Never weaken an inventory guard test (`docs/inventory/`): a guard moving with its code keeps its name and every assertion; a guard that would have to relax is a stop-and-ask to the owner.
- Public repo hygiene: no real ids, names, domains or local paths in fixtures, docs or tests (`acme`, `example.com`, `<owner-slack-id>`).
- Each task declares `Depends on:`; independent tasks may run in parallel worktree lanes, Swift tasks included.
- Built-in ids and slots are fixed strings: built-in `morning-brief`; slots `morning_brief` (C2) and, reserved for C3, `custom_tracks`, `tracks`, `reactions`, `ideas`.
- Capabilities for primitives are `builtin:<primitive>` by default (`CapabilityForPrimitive`, Task 2); C2 ships `builtin:brief.compose`, `builtin:plan.compose`. Only `origin = 'builtin'` recipes may declare a `builtin:` capability; in C2 only they may declare a `sync` trigger (the one rule is `syncTriggerAllowed`, Task 2). C3's `track.scan` uses the capability `track:scan` (Personal), see `CapabilityForPrimitive`.
- The config keys `briefing.enabled` and `day_plan.enabled` stay the on/off truth for Morning brief; `briefing.hour` is the one hour (the plan is made in the same run, right after the brief); `day_plan.hour` is retired.
- Exact UI copy (use verbatim): section **Built in**; card labels **When**, **Reads**, **Sends**, **Costs**; buttons **Edit in Chat**, **Turn Off** / **Turn On**, **Run Now**; ⋯ item **Reset to built-in**; inline confirm row "Reset — your changes are lost" with **Reset** and **Cancel**; banner "Built-in version updated" with **Show changes** / **Hide changes** and **Reset to built-in**; unconfirmed-copy line "Your edited copy is not confirmed yet, so it does not run."; Run Now note "Runs at the next sync"; Settings pointer "These now live in Automations → Built in" with **Open Automations**; Inbox notice "Couldn't move Morning brief to Automations" with **Retry**.

## Review Focus

1. **A hand-edited, agent-written or half-written `.builtin/morning-brief.md`** (one byte off the shipped text, a parse error, a symlink): it must never run until the owner confirms it, the brief stops visibly (card line, no silent fallback to the shipped text), and a symlink or special file is never read (shipped text stays). Tests: Task 4 `TestAuto06_HandEditedCopyStopsTheBuiltIn`, `TestBuiltinSync_CopySymlinkIsNeverRead`.
2. **A daemon killed mid-slot**: the `sync` run left `running` ends `interrupted` at the next start, and the next cycle is due again (no briefing row was written, the attempt budget is not charged twice). Test: Task 6 `TestMorningBrief_InterruptedRunDoesNotBlockNextCycle`.
3. **Two producers at once**: Run Now pressed twice, `briefing generate` / `day-plan generate --feedback` from the CLI while the daemon's slot runs — one queued manual run (coalesced), never two briefs for a date, never two plans built from the same base. Tests: Task 4 `TestRunner_RunNowTwiceCoalesces`, Task 7 `TestBriefingGenerate_RefusedWhileSlotRuns`.
4. **A personal recipe that copies the built-in** (`morning-brief.md` in the Personal folder, or one declaring `trigger: {sync: …}` / `builtin:brief.compose`): it parses as an error, never shares the built-in's row, and the Personal scan never marks the built-in row removed. Tests: Task 2 `TestAuto06_PersonalRecipeCannotDeclareSyncOrBuiltinCapability`, Task 1 `TestMarkAutomationsRemovedExcept_LeavesBuiltinRows`, Task 4 `TestBuiltinSync_PersonalSlugTwinIsSeparate`.
5. **An upgrade whose customised prompt-store row is broken or role-specific** (wrong `%s` count, a `briefing.daily_<role>` row, a row Seed would have upgraded): the owner copy carries exactly what ran yesterday (the role-resolved template), and a wrong placeholder count still falls back to the shipped default with a journal note, as today. Tests: Task 8 `TestBuiltinUpgrade_CarriesTheResolvedRolePrompt`, Task 5 `TestComposeBrief_PlaceholderMismatchUsesDefault`.

---

## File Structure

| Path | Responsibility |
|---|---|
| `internal/db/migrations/00150_builtin_automations.sql` (create) | origin/builtin_id/overridden/builtin_base_hash on `automations`, `sync` in both trigger CHECKs, `builtin_migrations` |
| `internal/db/automation_builtins.go` (create) | built-in row upsert, shipped confirmation, enabled mirror, queued-run take, migration records, 7-day cost |
| `internal/db/automations.go` (modify) | new fields + `Confirmed()`; owner-only slug lookup and removal sweep |
| `internal/automations/recipe.go`, `manifest.go`, `hash.go` (modify) | `Scope.BuiltinID`, `sync` trigger, `builtin:` capability, canonical form |
| `internal/automations/sdk_builtin.go` (create) | `builtin.*`, `brief.*`, `plan.*` SDK paths over `Backends.Primitives` |
| `internal/automations/executor*.go` (modify) | poll skips built-in runs; `ExecuteBuiltinInline`; `PrimitiveFailed` classification |
| `internal/automations/builtin/` (create) | registry, embedded recipes, sync indexer, runner, owner-copy render, card info |
| `internal/automations/builtin/recipes/morning-brief.md` (create) | the shipped recipe |
| `internal/automations/builtin/morningbrief.go` (create) | shared brief/plan primitive bodies over pipeline interfaces |
| `internal/briefing/pipeline.go`, `internal/dayplan/{pipeline,prompt,types}.go`, `internal/prompts/resolve.go` (modify) | prompt override seams, `DefaultForRole`, `MovedToBuiltin` |
| `internal/daemon/morning_brief.go` (create) | the slot phase, gate, daemon primitives, legacy fallback switch |
| `cmd/builtins.go`, `cmd/builtin_upgrade.go` (create); `cmd/sync.go`, `cmd/briefing.go`, `cmd/day_plan.go`, `cmd/automations*.go`, `cmd/prompts.go` (modify) | wiring, CLI paths, upgrade step |
| `WatchtowerDesktop/Sources/WatchtowerCore/...` | model fields, presentation, card model, CLI wrappers, readiness hour, Inbox notice |
| `WatchtowerDesktop/Sources/Views/Automations/BuiltinAutomationCard.swift` (create), `AutomationsView.swift`, `Settings/FeaturesSettings.swift`, Inbox views (modify) | the Built in section and card, Settings pointer, Retry card |
| docs | `docs/features/built-in-automations.md` (new), `automations.md`, `CLAUDE.md`, guide pages, CLI reference, inventory |

---

### Task 1: Migration and database layer

**Depends on:** none

**Files:**
- Create: `internal/db/migrations/00150_builtin_automations.sql` (re-check the number)
- Create: `internal/db/automation_builtins.go`, `internal/db/automation_builtins_test.go`
- Modify: `internal/db/automations.go` (struct, `automationCols`, `scanAutomation`, `GetAutomationBySlug`, `MarkAutomationsRemovedExcept`), `internal/db/automation_runs.go` (`TriggerSync`), `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), goldens, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`

**Interfaces:**
- Produces:
  - Columns on `automations`: `origin TEXT NOT NULL DEFAULT 'owner' CHECK (origin IN ('owner','builtin'))`, `builtin_id TEXT` (NULL for owner rows), `overridden INTEGER NOT NULL DEFAULT 0 CHECK (overridden IN (0,1))`, `builtin_base_hash TEXT NOT NULL DEFAULT ''` (content hash of the shipped text an owner copy was made from); `trigger_kind` CHECK gains `'sync'`; table CHECKs `((origin = 'builtin') = (builtin_id IS NOT NULL))` and `(origin = 'owner' OR scope = 'personal')`.
  - Indexes: `idx_automations_scope_slug` becomes `UNIQUE ... ON automations(scope, COALESCE(project_id, 0), slug) WHERE origin = 'owner'`; new `CREATE UNIQUE INDEX idx_automations_builtin_id ON automations(builtin_id) WHERE builtin_id IS NOT NULL`.
  - `automation_runs.trigger` CHECK gains `'sync'` (one in-cycle run of a built-in). `event_json` comment: for a slot run's manual input, `{"builtin": BuiltinInput}`; fields are listed on `automations.BuiltinInput` (`""` when Run Now has no input). No exact key list in the SQL comment (C3 adds `since`).
  - Table `builtin_migrations (builtin_id TEXT PRIMARY KEY, status TEXT NOT NULL CHECK (status IN ('done','failed')), error TEXT NOT NULL DEFAULT '', attempts INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL)`.
  - `db.Automation` gains `Origin string`, `BuiltinID string`, `Overridden bool`, `BuiltinBaseHash string`; consts `db.OriginOwner = "owner"`, `db.OriginBuiltin = "builtin"`, `db.TriggerSync = "sync"`, `db.TriggerKindSync = "sync"`.
  - `func (a Automation) Confirmed() bool` — `ParseError == "" && RemovedAt == nil && ConfirmedHash != "" && ConfirmedHash == ApprovalHash`; `Runnable()` becomes `a.Confirmed() && a.Enabled` (same truth table).
  - `func (a Automation) IsBuiltin() bool`
  - `func (a Automation) RunsAtSlot() bool` — true when the automation's runs are executed only at a cycle slot by the slot executor, never by the executor's poll. In C2 its body is `return a.IsBuiltin()`; doc: "C3 widens this to Personal `custom_tracks` watch recipes". Every slot-run check (`poll.consider`, `ExecuteBuiltinInline`, the `builtin.input` decode, Task 3) uses this predicate, never `IsBuiltin()` directly.
  - `func (db *DB) UpsertBuiltinAutomation(a Automation) (int64, error)` — keyed by `path = "builtin:" + a.BuiltinID`, writes `origin='builtin'`, `builtin_id`, `overridden`, `builtin_base_hash` and the parsed columns; never writes `confirmed_hash`/`enabled`/schedule columns (same rule as `UpsertAutomationIndex`); refuses an empty `BuiltinID`.
  - `func (db *DB) ConfirmShippedBuiltin(id int64, contentHash, approvalHash string, now time.Time) error` — sets `confirmed_hash = approvalHash` only when the row is `origin='builtin'`, its `content_hash = contentHash` and its `approval_hash = approvalHash`; else `ErrHashMismatch` (or `ErrNotBuiltin` for an owner row).
  - `func (db *DB) GetBuiltinAutomation(builtinID string) (*Automation, error)` (`ErrAutomationNotFound` when absent)
  - `func (db *DB) SetBuiltinEnabled(builtinID string, on bool, now time.Time) error` — mirror only; leaves `disabled_reason` alone.
  - `func (db *DB) TakeQueuedBuiltinRun(automationID int64) (*AutomationRun, error)` — the oldest `queued` `manual` run of that automation, nil when none.
  - `func (db *DB) RecordBuiltinMigration(builtinID, status, errText string, now time.Time) error` (increments `attempts`), `func (db *DB) GetBuiltinMigration(builtinID string) (*BuiltinMigration, error)` (nil when none), type `BuiltinMigration{BuiltinID, Status, Error string; Attempts int; UpdatedAt time.Time}`.
  - `func (db *DB) BuiltinCost(automationID int64, pipelines []string, since time.Time) (BuiltinCostSum, error)` — `BuiltinCostSum{USD float64; Reported bool}`: sum of `automation_runs.reported_cost_usd` since `since`, plus `pipeline_runs` cost of `pipelines` on local dates before the built-in's first run.
  - `GetAutomationBySlug` and `MarkAutomationsRemovedExcept` consider `origin = 'owner'` rows only.

- [ ] **Step 1: Write the failing tests** in `internal/db/automation_builtins_test.go`:
  - `TestBuiltinAutomation_UpsertNeverSetsOwnerColumns` — insert, then upsert with a changed `ApprovalHash`; `ConfirmedHash == ""`, `Enabled == false`, `Path == "builtin:morning-brief"`, `Origin == "builtin"`.
  - `TestAuto06_ConfirmShippedBuiltinRefusesOtherBytes` — table: owner row → `ErrNotBuiltin`; built-in row with another content hash → `ErrHashMismatch`, `confirmed_hash` unchanged; matching hashes → confirmed.
  - `TestMarkAutomationsRemovedExcept_LeavesBuiltinRows` — a built-in row and a personal row; `MarkAutomationsRemovedExcept("personal", 0, nil, now)` removes only the personal row.
  - `TestGetAutomationBySlug_IgnoresBuiltinTwin` — personal `morning-brief` and built-in `morning-brief` coexist (no unique violation); the slug lookup returns the personal row.
  - `TestAutomation_RunsAtSlotEqualsIsBuiltin` — an owner row and a built-in row: `RunsAtSlot() == IsBuiltin()` for both.
  - `TestAutomationRuns_SyncTriggerAccepted` — `EnqueueAutomationRun` with `TriggerSync` succeeds; a bogus trigger still fails the CHECK.
  - `TestBuiltinMigration_RecordCountsAttempts` — two `failed` records → `Attempts == 2`; then `done`.
  - `TestBuiltinCost_PipelineRunsOnlyBeforeFirstRun` — pipeline rows on day −3 and day 0 plus a run on day 0 with $0.10: sum = day −3 cost + 0.10, `Reported == true`.
  - `TestMigration00150_KeepsRunsAndChildren` — seed an automation with a run, a step, an output, a state row and a grant at 00149, migrate up: all rows and ids kept, `sqlite_sequence` for both rebuilt tables kept; migrate down: built-in rows and `sync` runs gone, owner rows kept.
  - Existing guards `TestAutomationIndex_RunnableTable`, `TestAutomationIndex_InsertNeverSetsOwnerColumns`, `TestAutomationIndex_UpsertKeepsOwnerColumns` stay untouched and must pass.
- [ ] **Step 2: Run** `go test ./internal/db -run 'Builtin|Migration00150|SyncTrigger|IgnoresBuiltinTwin|LeavesBuiltinRows|RunsAtSlot'` — expected: FAIL (columns and functions missing).
- [ ] **Step 3: Write the migration.** `-- +goose NO TRANSACTION`, `PRAGMA foreign_keys = OFF;`, rebuild `automations` (new columns, CHECKs, indexes) then `automation_runs` (copy 00149's definition verbatim plus `'sync'`, its indexes and the replay cleanup trigger), carry both `sqlite_sequence` rows, create `builtin_migrations`, `PRAGMA foreign_keys = ON;`. Down: delete `sync` runs and built-in rows (children first, explicitly, since FKs are off), rebuild both tables back, drop `builtin_migrations`. Grep `schema.sql` for every trigger and index naming `automations` or `automation_runs` and carry each.
- [ ] **Step 4: Implement** the Go functions above, mirror `schema.sql`, add `builtin_migrations` to `TestAllTablesExist`, regenerate goldens and the Swift test schema.
- [ ] **Step 5: Run** `go test ./internal/db` and `make lint-diff` — expected: PASS.
- [ ] **Step 6: Commit** `feat(db): built-in automation rows, sync trigger, builtin_migrations (00150)`.

---

### Task 2: Recipe grammar — built-in scope, `sync` trigger, `builtin:` capability, hash

**Depends on:** none

**Files:**
- Modify: `internal/automations/recipe.go`, `internal/automations/manifest.go`, `internal/automations/hash.go`, `internal/automations/indexer.go` (`triggerSpecOf`)
- Test: `internal/automations/recipe_test.go`, `manifest_test.go`, `indexer_test.go`

**Interfaces:**
- Produces:
  - `Scope` gains `BuiltinID string`; `Scope.String()` returns `"builtin:" + BuiltinID` when set (else unchanged), so the approval hash binds the built-in id; `validateScope` accepts `{Kind: ScopePersonal, BuiltinID: <id>}` only with a `ValidSlug` id and `WorkbenchID == 0`.
  - `func (s Scope) IsBuiltin() bool`
  - `TriggerSync TriggerKind = "sync"`; `Trigger.Sync string` (the slot); `var SyncSlots = []string{"morning_brief", "custom_tracks", "tracks", "reactions", "ideas"}`. Grammar: `trigger: {sync: <slot>}`; an unknown slot is refused listing `SyncSlots`; whether the scope may use the slot is decided by `syncTriggerAllowed` (below).
  - `func syncTriggerAllowed(scope Scope, slot string, m *Manifest) error` — the one sync-trigger rule, called by `ParseRecipe` after the manifest is parsed. C2 body: `scope.IsBuiltin()` → nil (any slot in `SyncSlots`); else `"a sync trigger is only for built-in automations"`. Doc comment: "C3 allows `custom_tracks` for a Personal recipe holding `track:scan`." No other code checks a sync trigger's scope.
  - Trigger spec JSON / canonical form: `{"sync":"<slot>"}` (`omitempty`, so every existing canonical byte string is unchanged).
  - Capability `builtin` in `capabilitySpecs` with `verbs` = `BuiltinPrimitiveNames` (`var BuiltinPrimitiveNames = []string{"brief.compose", "plan.compose"}` — C3 appends) and a new `builtinOnly bool` spec flag; `ParseManifest` refuses a `builtinOnly` entry outside a built-in scope with `"%q is allowed only in a built-in automation"`.
  - `var PrimitiveCapability = map[string]string{}` — primitive name → capability, for primitives whose capability is not `builtin:<name>` (empty in C2; C3 adds `"track.scan": "track:scan"`). `func CapabilityForPrimitive(name string) string` — the map entry, else `"builtin:" + name`.
  - `func (m *Manifest) AllowPrimitive(name string) (string, error)` — the manifest entry `CapabilityForPrimitive(name)` or `PermissionDenied`.
- [ ] **Step 1: Write the failing tests:**
  - Fixture rule for the two guards below: they use slot `morning_brief` and `builtin:` capabilities only, so C3 adds its `custom_tracks` + `track:scan` cases as new tests without touching an assertion here.
  - `TestParseRecipe_SyncTriggerBuiltinOnly` — same bytes parse under `Scope{Kind: ScopePersonal, BuiltinID: "morning-brief"}` (`Trigger.Kind == TriggerSync`, `Trigger.Sync == "morning_brief"`) and fail under `Scope{Kind: ScopePersonal}` and a workbench scope with the message above.
  - `TestParseRecipe_SyncUnknownSlotRefused`.
  - `TestAuto06_PersonalRecipeCannotDeclareSyncOrBuiltinCapability` — `builtin:brief.compose` in a personal and a workbench recipe → `ManifestError`; in a built-in scope → normalised entry `builtin:brief.compose`; `builtin:nope` refused.
  - `TestCapabilityForPrimitive_DefaultsToBuiltinPrefix` — `CapabilityForPrimitive("brief.compose") == "builtin:brief.compose"`; `AllowPrimitive("plan.compose")` returns `builtin:plan.compose` when declared, `PermissionDenied` when not.
  - `TestApprovalHash_BuiltinScopeAndSyncAreHashed` — the same text under two built-in ids hashes differently; changing the slot changes the hash; `ApprovalFields` lists `scope = "builtin:morning-brief"` and `trigger = {"sync":"morning_brief"}`.
  - `TestApprovalHash_GoldenCanonicalBytes` and `TestApprovalHash_ButtonLabelIsCosmetic` stay byte-identical (guards; do not regenerate).
- [ ] **Step 2: Run** `go test ./internal/automations -run 'SyncTrigger|Sync|BuiltinScope|PersonalRecipeCannot|CapabilityForPrimitive|GoldenCanonical'` — expected: new tests FAIL, goldens PASS.
- [ ] **Step 3: Implement** the grammar, flag and canonical key.
- [ ] **Step 4: Run** `go test ./internal/automations` and `make lint-diff` — PASS.
- [ ] **Step 5: Commit** `feat(automations): built-in scope, sync trigger and builtin: capability`.

---

### Task 3: Primitive SDK and executor support

**Depends on:** Task 1, Task 2

**Files:**
- Create: `internal/automations/sdk_builtin.go`, `internal/automations/sdk_builtin_test.go`
- Modify: `internal/automations/backends.go`, `modules.go` (`DefaultModules` appends `BuiltinModule(b)`), `executor.go` (`poll.consider`, `ExecuteBuiltinInline`), `executor_run.go` (`triggerInfo`, `classifyRunError`), `sandbox.go` (`TriggerInfo.Builtin`), `errors.go`

**Interfaces:**
- Consumes: `db.TriggerSync`, `Automation.IsBuiltin()/RunsAtSlot()/Confirmed()` (Task 1); `Scope.IsBuiltin`, `Manifest.AllowPrimitive`, `CapabilityForPrimitive`, `BuiltinPrimitiveNames` (Task 2).
- Produces:
  ```go
  // BuiltinInput is a slot run's manual input (event_json {"builtin": BuiltinInput}).
  // The fields below are the whole list; C3 adds Since.
  type BuiltinInput struct {
      Only     []string `json:"only,omitempty"`     // primitive names to run; empty = all
      Date     string   `json:"date,omitempty"`     // YYYY-MM-DD; "" = today (local)
      Feedback string   `json:"feedback,omitempty"` // plan.compose only
      Force    bool     `json:"force,omitempty"`    // plan.compose only
  }
  type PrimitiveCall struct {
      Name      string         // "brief.compose"
      BuiltinID string
      Prompt    string         // the recipe's prompt text
      Args      map[string]any // the call's other arguments, as the script passed them
      Trigger   TriggerInfo    // Kind "sync" | "manual"
      Input     BuiltinInput
      Role      string         // the owner profile's role, resolved once per run
  }
  type PrimitiveUsage struct { InputTokens, OutputTokens int; CostUSD float64; Reported bool }
  type PrimitiveResult struct {
      Status string         // "done" | "skipped"
      Fields map[string]any // returned to the script next to status (e.g. briefing_id)
      Note   string         // journalled on the step (e.g. the placeholder fallback)
      Usage  PrimitiveUsage
  }
  type PrimitiveFunc func(ctx context.Context, call PrimitiveCall) (PrimitiveResult, error)
  // Backends gains:
  //   Primitives map[string]PrimitiveFunc  // keyed by primitive name
  //   DefaultPrompt func(builtinID, name, role string) (string, error)
  const ErrNamePrimitiveFailed = "PrimitiveFailed"
  ```
  - JS surface, installed per declared capability (never keyed on the scope): a primitive's namespace (`brief` for `builtin:brief.compose`, `plan` for `builtin:plan.compose`) is installed only when the manifest holds `CapabilityForPrimitive(<primitive>)`; `builtin.*` is installed when the manifest holds any `builtin:` capability. `builtin:` capabilities are `builtinOnly` (Task 2), so in C2 a personal or workbench script sees `undefined` for all of them. `builtin.defaultPrompt(name)` → string; `builtin.input` → the `BuiltinInput` object; `brief.compose({prompt})` and `plan.compose({prompt})` → `{status, ...Fields}`. Unknown argument keys → `ValidationError`; a non-string or empty `prompt` → `ValidationError`.
  - The run's `event_json` `"builtin"` input is decoded into `TriggerInfo.Builtin` / `PrimitiveCall.Input` for every run of an automation that `RunsAtSlot()` (in C2 the built-ins; C3 widens the predicate, not this code).
  - Each primitive call is one journal step `kind = 'llm'`, `name = <primitive>`, `permission = CapabilityForPrimitive(<primitive>)` (`builtin:<primitive>` in C2), carrying the usage; usage is added to the run's meter, so the token budget and `reported_cost_usd` include it; an exhausted budget interrupts as for `llm()`.
  - A primitive's error becomes an `SDKError{Name: ErrNamePrimitiveFailed}`; an uncaught one ends the run `failed` with `error_kind = 'backend'`.
  - Dry run (`TriggerInfo.DryRun`, incl. `draft_automation`): a primitive calls no `PrimitiveFunc`, closes its step `dry_run` with summary `{"would": "<primitive>", "date": "<date>"}` and returns `{status: "dry_run"}` (AUTO-12).
  - `poll.consider` leaves every run of a `RunsAtSlot()` automation untouched (never claims, never cancels): slot automations (in C2, the built-ins) run only at their slot.
  - `func (e *Executor) ExecuteBuiltinInline(ctx context.Context, runID int64) (*db.AutomationRun, error)` — claims and executes in the caller's goroutine; requires `a.RunsAtSlot() && a.Confirmed()` (for a built-in, enabled is the caller's gate), else cancels the run `not_runnable` and returns `ErrNotRunnable`; respects the automation's concurrency (returns `ErrRunNotClaimed` when another run of it is active).
- [ ] **Step 1: Write the failing tests** in `sdk_builtin_test.go` / `executor_test.go`:
  - `TestBuiltinSDK_AbsentOutsideBuiltinScope` — a personal recipe's `typeof brief` is `"undefined"`.
  - `TestBuiltinSDK_NamespacePerDeclaredCapability` — a built-in scope declaring only `builtin:brief.compose`: `typeof brief == "object"`, `typeof plan == "undefined"`, `typeof builtin == "object"`.
  - `TestBuiltinSDK_ComposeCallsPrimitiveWithPrompt` — a fake `PrimitiveFunc` records `Prompt == "P"`, `Trigger.Kind == "sync"`; script gets `{status: "done", briefing_id: 7}`; step row `kind='llm'`, `name='brief.compose'`, `permission='builtin:brief.compose'`, tokens recorded.
  - `TestBuiltinSDK_PermissionDeniedWithoutCapability` — built-in scope, manifest without `builtin:plan.compose` → `PermissionDenied`, primitive not called.
  - `TestBuiltinSDK_UsageCountsAgainstBudget` — usage over `budget.tokens` → run `budget_exceeded`.
  - `TestBuiltinSDK_PrimitiveErrorFailsRunAsBackend`.
  - `TestAuto12_BuiltinPrimitiveDryRunCallsNothing` — dry run: primitive call count 0, step `dry_run`.
  - `TestExecutor_PollNeverClaimsBuiltinRuns` — a runnable built-in with a queued manual run: `Step` starts 0 runs and the run stays `queued`.
  - `TestAuto06_BuiltinInlineRefusesUnconfirmed` — `ExecuteBuiltinInline` on an unconfirmed built-in → run `cancelled`/`not_runnable`, primitive not called.
  - `TestExecutor_BuiltinInlineRunsWhenDisabled` — confirmed, `enabled = 0` → runs (the caller gates).
- [ ] **Step 2: Run** `go test ./internal/automations -run 'BuiltinSDK|BuiltinInline|PollNeverClaimsBuiltin|BuiltinPrimitiveDryRun'` — FAIL.
- [ ] **Step 3: Implement** `BuiltinModule(b Backends) Module` (namespaces per declared capability), the trigger info (`sync` kind; `builtin.input` decoded from `event_json` for every `RunsAtSlot()` run), the poll skip on `RunsAtSlot()` and `ExecuteBuiltinInline` (reuse `claim` + `runClaimed` with `claimKind{inline: true}`).
- [ ] **Step 4: Run** `go test ./internal/automations` (all AUTO guards must stay green) and `make lint-diff` — PASS.
- [ ] **Step 5: Commit** `feat(automations): primitive SDK for built-ins and inline built-in runs`.

---

### Task 4: Built-in registry, shipped recipe, sync indexer, runner (AUTO-06 amendment)

**Depends on:** Task 1, Task 2, Task 3

**Files:**
- Create: `internal/automations/builtin/registry.go`, `recipes/morning-brief.md`, `sync.go`, `runner.go`, `ownercopy.go`, `card.go`, `testmain_test.go`, `registry_test.go`, `sync_test.go`, `runner_test.go`, `testdata/show_morning_brief.json`
- Modify: `docs/inventory/automations.md` (AUTO-06 text, module list, guards, changelog)

**Interfaces:**
- Consumes: Task 1 DB functions, Task 2 grammar, Task 3 `ExecuteBuiltinInline`, `BuiltinInput`.
- Produces (the engine C3 plugs into):
  ```go
  package builtin
  type Slot string
  const (
      SlotMorningBrief Slot = "morning_brief"
      // C3: SlotCustomTracks "custom_tracks", SlotTracks "tracks", SlotReactions "reactions", SlotIdeas "ideas"
  )
  type ParamKind string // "hour" | "clock" (C3 adds "interval", "dictionary")
  type Parameter struct {
      Key   string    // config key, e.g. "briefing.hour" — never part of the recipe or its hash
      Kind  ParamKind
      Label string    // card label
  }
  type PromptRef struct {
      Name     string // the defaultPrompt(name) argument: "brief", "plan"
      PromptID string // prompts registry id: prompts.BriefingDaily, prompts.DayPlanGenerate
  }
  type Entry struct {
      ID            string      // "morning-brief" (slug-valid)
      Name          string      // "Morning brief"
      Slot          Slot
      Recipe        []byte      // embedded shipped bytes
      FeatureIDs    []string    // features registry ids whose ConfigKey is the on/off truth: ["briefing","day-plan"]
      Primitives    []string    // ["brief.compose","plan.compose"]
      Prompts       []PromptRef
      Parameters    []Parameter // [{briefing.hour, hour, "Time"}, {day_plan.working_hours_start, clock, "Working hours from"}, {day_plan.working_hours_end, clock, "to"}]
      Pipelines     []string    // pipeline_runs names for Costs: ["briefing","day_plan"]
      Reads, Sends  []string    // card copy
      When          func(cfg *config.Config) string // "Every morning at the first sync after 08:00"
      RunNow        bool        // the card offers Run Now and `automations run <id>` queues; every entry sets it explicitly (Morning brief: true; C3's reactions: false)
      NoRunNowNote  string      // the CLI refusal when !RunNow (C3's reactions: "Reactions run for each reaction you place")
  }
  func All() []Entry
  func Lookup(id string) (Entry, bool)
  func AtSlot(s Slot) []Entry
  func (e Entry) Enabled(cfg *config.Config) bool          // any FeatureIDs key on (features registry ConfigKey lookup)
  func (e Entry) ShippedContentHash() string
  func (e Entry) DefaultPrompt(name, role string) (string, error) // prompts.DefaultForRole(PromptID, role)
  func OwnerCopyPath(workspaceDir, id string) string      // <ws>/automations/.builtin/<id>.md
  func ParseShipped(e Entry) (*automations.Recipe, error)  // scope {personal, BuiltinID: e.ID}

  // Gate decides, before any run row exists, whether a sync run is due now.
  type Gate interface { Due(ctx context.Context, e Entry, now time.Time) bool }

  type SyncReport struct { Indexed, Confirmed, Overridden []string; Errors map[string]string }
  func Sync(ctx context.Context, d *db.DB, workspaceDir string, cfg *config.Config, now time.Time) (SyncReport, error)
  func SyncOne(ctx context.Context, d *db.DB, workspaceDir string, cfg *config.Config, id string, now time.Time) (*db.Automation, error)

  type InlineExecutor interface { ExecuteBuiltinInline(ctx context.Context, runID int64) (*db.AutomationRun, error) }
  type Runner struct{ /* db, exec, gates map[string]Gate, cfg, clock, logger */ }
  func NewRunner(d *db.DB, exec InlineExecutor, gates map[string]Gate, cfg *config.Config, clock automations.Clock, logger *log.Logger) *Runner
  type SlotOutcome struct { BuiltinID string; RunID int64; Status string; Skipped string } // Skipped: "off" | "not_confirmed" | "not_due" | ""
  func (r *Runner) RunSlot(ctx context.Context, slot Slot) []SlotOutcome
  func (r *Runner) RunNow(ctx context.Context, id string, in automations.BuiltinInput) (*db.AutomationRun, error) // CLI: inline manual run, ignores enabled

  func RenderOwnerCopy(e Entry, prompts map[string]string) ([]byte, error) // shipped text with builtin.defaultPrompt("<name>") replaced by a JSON string literal
  type CardInfo struct { /* the show --json "builtin" block, see Task 7 */ }
  func Card(d *db.DB, cfg *config.Config, e Entry, a *db.Automation, now time.Time) (CardInfo, error)
  ```
- The shipped `recipes/morning-brief.md`: `name: Morning brief`, `trigger: {sync: morning_brief}`, `permissions: [builtin:brief.compose, builtin:plan.compose]`, no outputs, `budget: {tokens: 400000, minutes: 15}`, `concurrency` default 1, a one-paragraph description, and the script:
  ```js
  const failed = [];
  for (const [name, call] of [["brief", brief.compose], ["plan", plan.compose]]) {
    try { call({ prompt: builtin.defaultPrompt(name) }); } catch (e) { failed.push(e); }
  }
  if (failed.length) throw failed[0];
  ```
  (The brief fails, the plan still runs — today's two independent phases.)
- Sync rules: per entry — lstat `OwnerCopyPath`; a regular file → parse under the built-in scope, `overridden = 1`, `builtin_base_hash` kept from the row (set to the current shipped hash on the 0→1 transition); absent → shipped bytes, `overridden = 0`, `builtin_base_hash = ''`; a symlink, directory or special file → shipped bytes plus `Errors[id] = "the edited copy is not a regular file; using the built-in"`. After the upsert: when the row's text is byte-equal to the shipped text (`content_hash == ShippedContentHash()`), call `ConfirmShippedBuiltin` (the amendment: the release is its confirmation). Then `SetBuiltinEnabled(id, e.Enabled(cfg))`.
- Runner rules (`RunSlot`): for each entry at the slot: `!e.Enabled(cfg)` → `Skipped "off"`, nothing read beyond config, no row (FEAT-01); row not `Confirmed()` → cancel its queued manual runs `not_runnable`, `Skipped "not_confirmed"`; a queued manual run (`TakeQueuedBuiltinRun`) → execute it (no gate); else `gate.Due` false → `Skipped "not_due"`, no row; else enqueue `TriggerSync` and `ExecuteBuiltinInline`. `RunNow`: enqueue a manual run with `event_json {"builtin": in}` and execute it inline.
- [ ] **Step 1: Write the failing tests:**
  - `registry_test.go`: `TestRegistry_ShippedRecipesParse` (each entry's bytes parse in its scope; trigger slot == `Entry.Slot`; permissions == `builtin:` + `Primitives`; `Prompts` names cover every `defaultPrompt` call in the script), `TestRegistry_FeatureIDsHaveConfigKeys`, `TestRegistry_RunNowNoteOnlyWhenNoRunNow` (an entry with `RunNow == false` has a non-empty `NoRunNowNote`; Morning brief `RunNow == true`), `TestRegistry_ShowJSONGolden` (writes/compares `testdata/show_morning_brief.json` with `-update`, incl. `"run_now": true`; the Swift test in Task 9 reads the same file).
  - `sync_test.go`: `TestAuto06_ShippedBuiltinRunsWithoutOwnerConfirmation` (fresh DB → row confirmed at the shipped approval hash, `Confirmed() == true`, no `ConfirmAutomation` call), `TestAuto06_OwnerCopyNeedsConfirmation` (copy with an edited prompt → `overridden = 1`, not confirmed), `TestAuto06_HandEditedCopyStopsTheBuiltIn` (a confirmed copy edited on disk → not confirmed after `Sync`; `RunSlot` writes no run row; outcome `not_confirmed`), `TestAuto06_CopyEqualToShippedRuns`, `TestBuiltinSync_CopySymlinkIsNeverRead`, `TestBuiltinSync_ShippedUpdateMovesSilently` (row at old shipped text, new embedded text → new text, confirmed), `TestBuiltinSync_OverriddenKeepsCopyAndFlagsUpdate` (`builtin_base_hash` ≠ new shipped hash → `CardInfo.UpdateAvailable`), `TestBuiltinSync_ResetReturnsToShipped` (remove the copy → `overridden = 0`, base hash cleared, confirmed), `TestBuiltinSync_PersonalSlugTwinIsSeparate`, `TestBuiltinSync_EnabledMirrorsConfig`.
  - `runner_test.go` (fake gate + fake primitives through a real executor): `TestRunner_OffWritesNothing`, `TestRunner_NotDueWritesNoRun`, `TestRunner_DueWritesOneSyncRun` (one row, trigger `sync`, status `succeeded`), `TestRunner_QueuedManualRunsAtSlotWithoutGate`, `TestRunner_RunNowTwiceCoalesces` (two `EnqueueAutomationRun` manual → one row, `coalesced`), `TestRunner_UnconfirmedCancelsQueuedManual`, `TestRunner_RunNowIgnoresEnabled`, `TestRenderOwnerCopy_LiteralPromptParsesAndFlows` (prompt containing a backtick, `%s`, U+2028 → parses; the fake primitive receives the exact text).
- [ ] **Step 2: Run** `go test ./internal/automations/builtin` — FAIL.
- [ ] **Step 3: Implement** the package (embed with `//go:embed recipes/*.md`).
- [ ] **Step 4: Amend `docs/inventory/automations.md`:** AUTO-06 Observable gains: "A built-in automation (`origin = 'builtin'`) whose recipe bytes equal the version shipped in the running app is runnable without the owner's confirmation — the release is its confirmation: the built-in indexer confirms exactly that text with `db.ConfirmShippedBuiltin`, which refuses any other bytes. Everything else holds: the owner's copy (`.builtin/<id>.md`) runs only after the owner confirms it, a hand edit makes it unconfirmed, the one-time upgrade step's carried prompt is confirmed as the owner's content already running (Task 8), and only built-in recipes may declare a `sync` trigger or a `builtin:` capability." Add the new guards above under AUTO-06 (and `TestAuto12_BuiltinPrimitiveDryRunCallsNothing` under AUTO-12), add the new files to **Module**, and a changelog line: "2026-10-22 (board #801, spec 2026-10-22 §5.2, **AUTO-06 amended, owner approved in ask #500**): shipped built-in bytes run without the owner's confirmation … no guard relaxed."
- [ ] **Step 5: Run** `go test ./internal/automations/... ./internal/db` and `make lint-diff` — PASS.
- [ ] **Step 6: Commit** `feat(automations): built-in registry, sync indexer and slot runner (AUTO-06 amendment)`.

---

### Task 5: Prompt override seams in briefing and day plan

**Depends on:** none

**Files:**
- Modify: `internal/briefing/pipeline.go`, `internal/dayplan/pipeline.go`, `internal/dayplan/prompt.go`, `internal/dayplan/types.go`, `internal/prompts/resolve.go`, `internal/prompts/tuner.go`, `cmd/prompts.go`
- Test: `internal/briefing/pipeline_test.go`, `internal/dayplan/prompt_test.go`, `internal/prompts/resolve_test.go`, `cmd/prompts_test.go`

**Interfaces:**
- Produces:
  - `briefing.RunOptions{Prompt string}`; `func (p *Pipeline) RunForDateWith(ctx context.Context, date string, opts RunOptions) (int, error)` — `RunForDate` = `RunForDateWith(ctx, date, RunOptions{})`. Non-empty `Prompt` replaces the store-resolved template; the placeholder check (`countVerbs` vs `prompts.Defaults[id]`) applies to it, a mismatch uses the default and logs as today; `WithRoleInstruction` is applied to whichever template is used. Everything else (owner adoption, idempotency per (owner, date), gathers, `blankUnshownIDs`, `briefing.daily` routing) unchanged.
  - `func (p *Pipeline) LastPromptNote() string` — "" or the fallback sentence, for the journal note.
  - `dayplan.RunOptions.Prompt string` — same override and the same placeholder check against `prompts.Defaults[prompts.DayPlanGenerate]` (new for the day plan; mismatch → default + log). `dayplan.Pipeline.LastPromptNote() string`.
  - `func prompts.DefaultForRole(id, role string) string` — `Defaults[id+"_"+role]` when present, else `Defaults[id]`.
  - `var prompts.MovedToBuiltin = map[string]string{BriefingDaily: "morning-brief", DayPlanGenerate: "morning-brief"}`; the tuner skips these ids; `watchtower prompts show <id>` prints a first line `Used by the Morning brief built-in — change it in Automations → Built in.` for them.
- [ ] **Step 1: Write the failing tests:** `TestRunForDateWith_PromptOverrideReplacesStoredTemplate` (stored row "A", override "B %s…" with the default's verb count → generator sees B with the role instruction prefix), `TestComposeBrief_PlaceholderMismatchUsesDefault` (override with one `%s` fewer → default used, `LastPromptNote()` non-empty), `TestRunForDateWith_ExistingBriefingStillIdempotent`, `TestDayPlanRun_PromptOverride`, `TestDayPlanRun_PromptPlaceholderMismatchUsesDefault`, `TestDefaultForRole`, `TestTuner_SkipsMovedPrompts`, `TestPromptsShow_MovedPromptNote`.
- [ ] **Step 2: Run** `go test ./internal/briefing ./internal/dayplan ./internal/prompts` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same packages, `go test ./cmd -run 'Prompts' -timeout 30m`, `make lint-diff` — PASS.
- [ ] **Step 5: Commit** `feat(briefing,dayplan): prompt override seam for the Morning brief built-in`.

---

### Task 6: Daemon — the Morning brief slot

**Depends on:** Task 4, Task 5

**Files:**
- Create: `internal/daemon/morning_brief.go`, `internal/daemon/morning_brief_test.go`, `internal/automations/builtin/morningbrief.go` (+ test)
- Modify: `internal/daemon/daemon.go` (`runSync` slot, gates use `briefing.hour` for the plan), `internal/daemon/daemon_gates_test.go`, `internal/daemon/owner_test.go`, `internal/config/config.go` + `defaults.go` (retire `day_plan.hour`), `cmd/sync.go` (wiring), `cmd/builtins.go` (create: `wireBuiltins`), `cmd/builtins_test.go` (create), `docs/inventory/features.md`

**Interfaces:**
- Consumes: `builtin.Runner`, `builtin.Gate`, `automations.PrimitiveFunc`, `briefing.RunOptions`, `dayplan.RunOptions.Prompt`.
- Produces:
  ```go
  // internal/automations/builtin/morningbrief.go — shared primitive bodies
  type BriefRunner interface {
      RunForDateWith(ctx context.Context, date string, opts briefing.RunOptions) (int, error)
      AccumulatedUsage() (int, int, float64, int)
      LastPromptNote() string
  }
  type PlanRunner interface {
      Run(ctx context.Context, opts dayplan.RunOptions) (*db.DayPlan, error)
      AccumulatedUsage() (int, int, float64, int)
      LastPromptNote() string
  }
  type MorningBriefHooks struct {
      // BriefDue/PlanDue are the sync-run gates (nil = always due: the CLI).
      BriefDue, PlanDue func(now time.Time) bool
      // Track wraps one real attempt (daemon: trackedPipelineRun + attempt budget + stamps; CLI: direct).
      TrackBrief func(date string, run func() (int, error)) (int, error)
      TrackPlan  func(date string, run func() (*db.DayPlan, error)) (*db.DayPlan, error)
      Owner      func() (db.Owner, error)
      Now        func() time.Time
  }
  func MorningBriefPrimitives(brief BriefRunner, plan PlanRunner, h MorningBriefHooks) map[string]automations.PrimitiveFunc
  ```
  Usage per call is the delta of `AccumulatedUsage()` around the call (the shared-pipeline precedent). `brief.compose`: in a `sync` run returns `{status: "skipped"}` when `BriefDue(now)` is false; result fields `briefing_id` (0 = no data yet). `plan.compose`: `skipped` when `PlanDue(now)` is false; `Feedback`/`Force` from `call.Input` (a non-empty feedback implies force); result fields `plan_id`, `items`. An entry in `Input.Only` that excludes a primitive → `skipped`.
  ```go
  // internal/daemon/morning_brief.go
  func (d *Daemon) SetBuiltins(r *builtin.Runner, active map[string]bool) // active[id] false = legacy phase for that producer (Task 8)
  func (d *Daemon) MorningBriefPrimitives() map[string]automations.PrimitiveFunc
  // BuiltinPrimitives is the one map the slot executor gets: the union of every
  // built-in's primitives. C2 body: return d.MorningBriefPrimitives(). C3 extends this body.
  func (d *Daemon) BuiltinPrimitives() map[string]automations.PrimitiveFunc
  func (d *Daemon) MorningBriefGate() builtin.Gate
  func (d *Daemon) phaseMorningBrief(ctx context.Context, now time.Time)
  ```
  `phaseMorningBrief` replaces `d.phaseBriefing(ctx)` + `d.runDayPlanPhases(ctx, now)` at the same place in `runSync`: when `active["morning-brief"]` is false it runs the legacy pair unchanged; otherwise `d.builtins.RunSlot(ctx, builtin.SlotMorningBrief)`, then `d.runDayPlanConflictPhase(ctx, now, owner)` (stays Go, gated `day_plan.enabled`). The gate: `briefDue = cfg.Briefing.Enabled && pipe != nil && shouldRunBriefingAt(now) && briefingHasOwner(now)`; `planDue = cfg.DayPlan.Enabled && shouldRunDayPlan(now, owner)`; `Due = briefDue || planDue`; `shouldRunDayPlan`'s hour is `cfg.Briefing.Hour` (default `config.DefaultBriefingHour`). Attempt files (`briefing_attempts.txt`, `day_plan_attempts.txt`), `last_briefing.txt`, `briefingFresh`/`dayPlanFresh`, the no-owner log lines and `pipeline_runs` names `briefing`/`day_plan` are unchanged.
  - `cmd/builtins.go`: `func wireBuiltins(d *daemon.Daemon, cfg *config.Config, database *db.DB, gen digest.Generator, logger *log.Logger) *builtin.Runner` — builds the slot executor — a dedicated `automations.NewExecutor(database, b, …)` that never `Run`s — from `b := automationBackends(cfg, database, gen)` (`cmd/automations_backends.go`, the main executor's backends, so later slot recipes have the read tools) and then sets `b.Primitives = d.BuiltinPrimitives()` and `b.DefaultPrompt = …`; runs `builtin.Sync`; and is called in `runSyncDaemon` independently of `automationsOK` (a failed owner-recipe upgrade step never stops the brief).
  - `config.DayPlanConfig.Hour`, `DefaultDayPlanHour` and the `day_plan.hour` default are removed (a key left in an owner's yaml is ignored).
- [ ] **Step 1: Write the failing tests** (`morning_brief_test.go`, real DB, fake generator):
  - `TestMorningBrief_DueRunMakesBriefThenPlanInOneRun` — one `automation_runs` row (`sync`, `succeeded`), one `briefings` row, one `day_plans` row, `pipeline_runs` rows `briefing` and `day_plan`; the plan prompt contains the brief.
  - `TestMorningBrief_PlanWaitsForBriefingHour` — `day_plan.enabled`, hour 9, now 08:30, a plan existed yesterday → no run; 09:05 → plan made.
  - `TestMorningBrief_FreshInstallBypassesHour` — no briefing/day plan ever: runs before the hour.
  - `TestMorningBrief_ThreeFailedAttemptsStopForTheDay` — erroring generator: three cycles make three failed runs, the fourth cycle writes no run.
  - `TestMorningBrief_SecondCycleSameDayWritesNoRun`.
  - `TestMorningBrief_BriefFailsPlanStillRuns` — run `failed`/`backend`, plan row exists.
  - `TestMorningBrief_InterruptedRunDoesNotBlockNextCycle` — a `running` sync run at start → `interrupted`; next cycle due, one attempt charged at most.
  - `TestMorningBrief_LegacyPathWhenNotActive` — `active` false → legacy phases run, zero `automation_runs` rows.
  - `TestMorningBrief_ConflictPhaseStillEveryCycle`.
  - `TestBuiltinPrimitives_HoldsMorningBriefPrimitives` — `d.BuiltinPrimitives()` holds `brief.compose` and `plan.compose`, and every name in `BuiltinPrimitiveNames` has a func (so C3's additions extend it without touching this test).
  - `TestWireBuiltins_SlotExecutorHasMainBackends` (in `cmd/builtins_test.go`) — the slot executor's backends carry the read-tool registry from `automationBackends` and the `Primitives` map; wiring works with `automationsOK == false`.
  - Move, keeping names and assertions: `TestFeatureGates_DisabledPhaseWritesNoPipelineRun` cases `briefing` and `day_plan` now drive `phaseMorningBrief` (both active and legacy) and additionally assert zero `automation_runs` rows; `TestOwner02_DaemonBriefingNoOwnerIsBenignAndLoggedOnce` and `TestOwner02_DaemonDayPlanNoOwnerLoggedOncePerUTCDay` drive `phaseMorningBrief` with the same log lines, counts and zero budget, plus zero `automation_runs` rows.
- [ ] **Step 2: Run** `go test ./internal/daemon -run 'MorningBrief|BuiltinPrimitives|FeatureGates|Owner02'` and `go test ./cmd -run 'WireBuiltins' -timeout 30m` — FAIL.
- [ ] **Step 3: Implement** the shared primitives, the daemon phase, gate, wiring and the config removal (fix compile sites: `FeatureReadiness` dual path is Task 9).
- [ ] **Step 4: Amend `docs/inventory/features.md`:** FEAT-01's phase list replaces `phaseBriefing`, `runDayPlanPhase` with "the Morning brief built-in's slot (`phaseMorningBrief`: no `automation_runs` row, no AI call while `briefing.enabled` and `day_plan.enabled` are off)"; FEAT-02/03 wording: "the switch for Briefing and Day Plan is the Morning brief built-in's Turn On/Off, which writes these keys through the feature-toggle path"; changelog line "2026-10-22 (board #801, spec §5.4, **FEAT-01..03 amended in wording, owner approved in ask #500**) … guard cases kept, `automation_runs` assertion added; no guard relaxed." Also add the same note to the OWNER-02 entry's guard list in its inventory file (guard names unchanged).
- [ ] **Step 5: Run** `go test ./internal/daemon ./internal/automations/builtin ./internal/config` and `go test ./cmd -run 'Sync|Daemon' -timeout 30m`, `make lint-diff` — PASS.
- [ ] **Step 6: Commit** `feat(daemon): Morning brief built-in at the briefing slot; day_plan.hour retired`.

---

### Task 7: CLI paths for built-ins

**Depends on:** Task 4, Task 5, Task 6

**Files:**
- Modify: `cmd/briefing.go`, `cmd/day_plan.go`, `cmd/automations.go`, `cmd/automations_edit.go`, `cmd/automations_run.go`, `cmd/automations_list.go`, `cmd/automations_auto.go`, `cmd/builtins.go`, `internal/automations/authoring/draft.go`, `internal/automations/authoring/save.go`
- Test: `cmd/builtins_test.go` (extend; created in Task 6), `cmd/automations_test.go`, `cmd/day_plan_test.go`, `cmd/owner02_test.go` (unchanged guard, must pass), `internal/automations/authoring/draft_test.go`, `save_test.go`

**Interfaces:**
- Consumes: `builtin.Runner.RunNow`, `builtin.SyncOne`, `builtin.Card`, `builtin.MorningBriefPrimitives` (CLI hooks: no gates, direct tracking, no attempt budget, no `pipeline_runs` — today's CLI behaviour).
- Produces:
  - `briefing generate` and `day-plan generate [--date] [--force] [--feedback]` keep their flags and output, and run `RunNow("morning-brief", BuiltinInput{Only: ["brief.compose"] | ["plan.compose"], Date, Feedback, Force})` on a CLI executor (`func newCLIBuiltinRunner(cfg, database, gen, logger) *builtin.Runner`), so the prompt is the built-in's current recipe (shipped or the owner's confirmed copy). Owner check first (`RequireOwner`) exactly as today; an unconfirmed copy → `Morning brief: your edited copy is not confirmed yet — confirm it in Automations → Built in`; another run of it active → `Morning brief is running now — try again in a minute`. Both refusals print that exact text on stderr and exit ≠ 0 (the Desktop's inline Regenerate row shows the stderr text, C1 Task 8 `testRegenerateShowsTheCLIRefusal`). Both commands still work with the feature off (today's forcing).
  - `automations run <id>` on a built-in goes through its `builtin.Entry`: refused with `e.NoRunNowNote` when `!e.RunNow`; refused when `!e.Enabled(cfg)` (`turn it on first`); else enqueues a manual run and sends `signalSyncNow` (the daemon runs it at the slot of the next cycle); JSON adds `"at_next_sync": true`.
  - `automations reset <id> [--json]` (new, owner-only: `refuseUnderAgent` + `confirmWithOwner` like `delete`): removes the owner copy (regular file only), `SyncOne`, JSON `{"automation_id", "overridden": false, "approval_hash"}`.
  - `automations enable|disable <id>` on a built-in: refused with `A built-in turns on and off with its features: watchtower features enable|disable briefing day-plan` (the Desktop uses the feature path, Task 11). `automations delete` and `automations auto` on a built-in: refused (`built-ins cannot be deleted; turn it off instead` / `built-ins get no auto grants (AUTO-03)`).
  - `automations save --path builtin:<id>` resolves to `builtin.OwnerCopyPath` (creates `.builtin/` 0700), writes atomically, `SyncOne`, then `--confirm-hash` as today. `--expect-content-hash` for a built-in target compares against the copy's hash when the copy exists, else the shipped text's hash (so the first save from the Desktop passes the row's `content_hash`).
  - `automations validate --against <id>` of a built-in parses in its built-in scope.
  - `automations show <id> --json` adds `"builtin": {"id", "slot", "overridden", "shipped_hash", "base_hash", "update_available", "shipped_text", "default_prompts": {"brief": "...", "plan": "..."}, "when", "reads": [], "sends": [], "parameters": [{"key", "kind", "label", "value"}], "feature_ids": [], "enabled", "run_now", "copy_error", "costs": {"usd", "days": 7, "reported"}}` (`null` for owner rows; empty slices `[]`, never `null`). `list --json` rows add `origin`, `builtin_id`, `overridden`.
  - `draft_automation` gains `builtin_id` (`jsonschema: the built-in this draft edits`), parsing in that scope; `save_automation` refuses a `builtin_id` (`a built-in is saved from its panel`).
- [ ] **Step 1: Write the failing tests:** `TestBriefingGenerate_UsesOwnerCopyPrompt`, `TestBriefingGenerate_RefusedForUnconfirmedCopy` (pins both refusal strings verbatim on stderr and a non-zero exit, for `briefing generate` and `day-plan generate --feedback`), `TestBriefingGenerate_RefusedWhileSlotRuns`, `TestAutomationsRun_BuiltinWithoutRunNowRefused` (a test entry with `RunNow: false` → exit ≠ 0 with its `NoRunNowNote`, no run row), `TestDayPlanGenerate_FeedbackForcesAndKeepsManualItems`, `TestDayPlanGenerate_WorksWithFeatureOff`, `TestAuto09_BuiltinRunNowOnlyQueues` (run row `queued`, signal sent, nothing executed by the CLI), `TestAutomationsReset_RemovesCopyAndConfirmsShipped`, `TestAutomationsReset_RefusedUnderAgentMarkers`, `TestAutomationsCLI_BuiltinEnableDisableDeletePointers`, `TestAuto03_BuiltinGetsNoAutoGrant`, `TestAutomationsSave_BuiltinPathWritesOwnerCopy` (first save with the row's `content_hash` passes; second save with a stale hash refused), `TestAutomationsShow_BuiltinBlockGolden` (pins the key set; uses `internal/automations/builtin/testdata/show_morning_brief.json`), `TestDraftAutomation_BuiltinScope`, `TestSaveAutomation_RefusesBuiltin`. `TestOwner02_UserTriggeredCommandsFailWithoutOwner` must stay green unchanged.
- [ ] **Step 2: Run** `go test ./cmd -run 'Builtin|BriefingGenerate|DayPlanGenerate|AutomationsReset|AutomationsRun|Owner02' -timeout 30m` and `go test ./internal/automations/authoring` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same, `make lint-diff` — PASS.
- [ ] **Step 5: Commit** `feat(cmd): built-in CLI paths — generate through the recipe, reset, save copy, show block`.

---

### Task 8: One-time upgrade step for Morning brief

**Depends on:** Task 4, Task 6, Task 7

**Files:**
- Create: `cmd/builtin_upgrade.go`, `cmd/builtin_upgrade_test.go`
- Modify: `cmd/builtins.go` (call order), `cmd/automations.go` (`upgrade-builtins` subcommand), `docs/inventory/automations.md` (AUTO-06 guard + changelog sentence)

**Interfaces:**
- Consumes: `builtin.Sync`, `builtin.RenderOwnerCopy`, `db.RecordBuiltinMigration`, `db.GetBuiltinMigration`, `db.ConfirmAutomation`, `prompts.Resolve`, `db.GetPrompt` (`Customized`).
- Produces:
  - `func upgradeBuiltins(cfg *config.Config, database *db.DB, now time.Time, logger *log.Logger) map[string]bool` — returns `active[id]`; called by `wireBuiltins` after `builtin.Sync`, before `d.SetBuiltins`. Per entry with no `done` record: (1) on/off needs nothing (the config keys are the truth); (2) for each `PromptRef`, resolve today's template with the owner profile's role (`prompts.Resolve(store, PromptID, role)`) and read the row it came from (the role variant row when it exists, else the base row); when that row is `customized`, collect it; (3) if any were collected and no owner copy exists, write `RenderOwnerCopy(e, collected)` to `OwnerCopyPath`, `SyncOne` (sets `overridden = 1`, `builtin_base_hash` = the current shipped hash), then `ConfirmAutomation(id, approvalHash, now)` (the owner's content already running); (4) `RecordBuiltinMigration(id, "done", "", now)`. Any error → `RecordBuiltinMigration(id, "failed", err.Error(), now)`, `active[id] = false` (the legacy phases keep running), logged. Runs under agent markers too (it carries only content already running and introduces no code); idempotent — a `done` record skips the entry, an existing owner copy is never overwritten.
  - `watchtower automations upgrade-builtins [--json]` — runs `upgradeBuiltins` now for `failed` entries; JSON `{"results": [{"builtin_id", "status", "error"}]}`; the Desktop's **Retry** calls it and then restarts the daemon (the daemon picks its path at start).
- [ ] **Step 1: Write the failing tests:** `TestBuiltinUpgrade_NoCustomPromptRecordsDone` (no copy written, `active` true), `TestBuiltinUpgrade_CustomPromptBecomesConfirmedCopy` (copy parses, `overridden = 1`, `Confirmed()`, the slot run passes the carried text), `TestBuiltinUpgrade_CarriesTheResolvedRolePrompt` (a customised `briefing.daily_<role>` row and a customised base row: the role row is carried, as `GetForRole` resolved it), `TestBuiltinUpgrade_IsIdempotent` (second call writes nothing, attempts unchanged), `TestBuiltinUpgrade_FailureKeepsLegacyAndRecords` (unwritable `.builtin` dir → `failed`, `active` false, error text kept), `TestBuiltinUpgrade_RetryCommandRunsFailedOnly`, `TestAuto06_UpgradeConfirmsOnlyCarriedPrompt` (the confirmed hash is the hash of exactly `RenderOwnerCopy`'s bytes).
- [ ] **Step 2: Run** `go test ./cmd -run 'BuiltinUpgrade|UpgradeConfirms' -timeout 30m` — FAIL.
- [ ] **Step 3: Implement.** Add the guard to AUTO-06's list and one changelog sentence: "the one-time upgrade step is the fourth `ConfirmAutomation` caller: it confirms only the owner copy it rendered from a customised prompt-store row that was already running."
- [ ] **Step 4: Run** the same, `make lint-diff` — PASS.
- [ ] **Step 5: Commit** `feat(cmd): one-time Morning brief upgrade step and Retry command`.

---

### Task 9: Swift Core — models, presentation, card model, readiness

**Depends on:** Task 1, Task 7

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/AutomationModels.swift`, `Services/Automations/AutomationTriggerText.swift`, `AutomationCardPresentation.swift`, `AutomationFailureWatch.swift`, `AutomationListSections.swift`, `AutomationsCLI.swift`, `Services/FeatureReadiness.swift`, `Models/Readiness.swift`, `Services/EmptyStateCopy.swift`, `Services/GettingReadyPolicy.swift`, and every `dayPlanHour` call site outside WatchtowerCore (`Services/ReadinessCenter.swift`, `Services/HomeCenter.swift`, `App/AppState+EmptyState.swift`, `App/AppState+ScreenContext.swift`, `Views/Components/TabEmptyState.swift`) and every C1 Inbox call site of `dayPlanHour` (`InboxFilterBar` / `InboxDayPane` empty states) — `rg -n dayPlanHour WatchtowerDesktop` returns nothing after this task
- Create: `Services/Automations/BuiltinAutomationCardModel.swift`, `Services/Automations/BuiltinUpgradeNotice.swift`
- Test: `Tests/Core/BuiltinAutomationCardModelTests.swift`, `Tests/Core/BuiltinAutomationDetailDecodingTests.swift`, `Tests/Core/AutomationTriggerTextTests.swift`, `Tests/Core/AutomationListSectionsTests.swift`, `Tests/Core/FeatureReadinessTests.swift`, `Tests/Core/BuiltinUpgradeNoticeTests.swift`

**Interfaces:**
- Consumes: the Task 1 columns, the Task 7 `show --json` `builtin` block and CLI verbs.
- Produces (Go↔Swift dual paths, each named in a doc comment pointing at its Go twin):
  1. `Automation` gains `origin: Origin` (`enum Origin: String { case owner, builtin }`), `builtinID: String?`, `overridden: Bool`, `builtinBaseHash: String`, `var isBuiltin: Bool` (twin: `db.Automation`).
  2. Run trigger `"sync"` decodes (twin: `db.TriggerSync`); `AutomationCardPresentation` trigger label `"At its slot in the sync cycle"`; `AutomationFailureWatch.backgroundTriggers` gains `"sync"`; `AutomationTriggerText` for `{"sync": "morning_brief"}` → `"Every morning, at the first sync after its time"` (the hour comes from the card's `when`).
  3. `AutomationCardPresentation.permissionLine`: `builtin:brief.compose` → `"Write your daily brief"`, `builtin:plan.compose` → `"Plan your day"` (twin: `BuiltinPrimitiveNames`).
  4. `struct BuiltinAutomationDetail: Decodable` mirroring the `show --json` `builtin` block (twin: `builtin.CardInfo`), incl. `runNow: Bool` (`run_now`, twin: `builtin.Entry.RunNow`) and `parameters: [Parameter]` with `struct Parameter: Decodable { key, label: String; kind: Kind; value }` and `enum Kind: String, Decodable { case hour, clock }` (twin: `builtin.ParamKind`; C3 adds `.interval`, `.dictionary`); decoded from the shared golden `internal/automations/builtin/testdata/show_morning_brief.json` read through `#filePath` (the `ArtifactsContract` fixture pattern).
  5. `FeatureReadiness` day plan uses `briefingHour` (twin: the daemon's `shouldRunDayPlan` hour); `Readiness.dayPlanHour`, `ReadinessCenter.dayPlanHour` and the `dayPlanHour` arguments are removed, call sites pass `briefingHour`.
  6. `AutomationListSections.make` puts every `isBuiltin` item in a first section titled `"Built in"` (`AutomationListSections.builtinTitle`), never in Personal.
  7. `AutomationsCLI.Op` gains `.reset(id)` (`automations reset <id> --json`), `.upgradeBuiltins` (`automations upgrade-builtins --json`); `show` decodes the optional `builtin` block; `save` passes `path` unchanged (`builtin:<id>` is accepted by the CLI).
  8. `package struct BuiltinUpgradeNotice: Equatable, Sendable` (`builtinID: String`, `error: String`, `updatedAt: Date`; `Equatable`/`Sendable` because it lives in C1's `InboxFeedSnapshot`, Task 10) — `static func load(_ db: Database) throws -> [BuiltinUpgradeNotice]` over `builtin_migrations WHERE status = 'failed'` (twin: `db.RecordBuiltinMigration`); a missing `builtin_migrations` table → `[]` (C1's `zeroIfTableMissing` rule: only "no such table"); title `"Couldn't move \(Self.name(for: builtinID)) to Automations"`; `static func name(for id: String) -> String` — a static table, twin of `builtin.Entry.Name` (`morning-brief` → `Morning brief`), the id itself as fallback; C3 adds its rows.
  - `@Observable final class BuiltinAutomationCardModel` (`@MainActor`): `init(automation: Automation, cli: AutomationsCLI)`; `func load() async` (calls `show`); state `detail: BuiltinAutomationDetail?`, `loadError: String?`, `resetConfirming: Bool`, `showingChanges: Bool`, `isWorking: Bool`; `var cardState: CardState` (`.shipped`, `.ownCopyConfirmed`, `.ownCopyUnconfirmed`, `.copyError(String)`); `var updateBanner: Bool` (`overridden && update_available`); `var costsLine: String` (`"About $%.2f in the last 7 days"`, `"No AI cost in the last 7 days"` when 0 and reported, `"Cost not reported"`); `var changes: OwnerAskSnapshotDiff?` (owner copy vs `shipped_text`, only while `showingChanges`); `func beginReset()`, `func cancelReset()`, `func confirmReset() async` (clears `resetConfirming` only after the CLI succeeds; error kept in `loadError`); `func runNow() async`.
- [ ] **Step 1: Write the failing tests** (`Tests/Core`): `testDecodesSharedGoldenBlock`, `testEmptyListsDecodeAsEmpty`, `testSyncTriggerDecodesAndLabels`, `testSyncIsABackgroundTrigger`, `testBuiltinPermissionLines`, `testBuiltinItemsListedInBuiltIn`, `testCardStateForShippedCopyAndUnconfirmed`, `testUpdateBannerOnlyWhenOverriddenAndUpdated`, `testCostsLineCases`, `testResetKeepsConfirmRowOnFailure`, `testResetClearsOnSuccess`, `testShowChangesDiffsCopyAgainstShipped`, `testDayPlanReadinessUsesBriefingHour` (twin of `TestMorningBrief_PlanWaitsForBriefingHour`), `testUpgradeNoticeListsFailedOnly`, `testUpgradeNoticeNameFallsBackToTheID` (`name(for: "morning-brief") == "Morning brief"`, `name(for: "x-y") == "x-y"`), `testUpgradeNoticeOnASchemaWithoutTheTable`, `testDecodesRunNow`.
- [ ] **Step 2: Run** `make test-swift FILTER='BuiltinAutomationCardModelTests|BuiltinAutomationDetailDecodingTests|AutomationTriggerTextTests|AutomationListSectionsTests|FeatureReadinessTests|BuiltinUpgradeNoticeTests'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same filter, `make lint-swift` — PASS.
- [ ] **Step 5: Commit** `feat(desktop-core): built-in models, card model, readiness on briefing hour`.

---

### Task 10: Desktop views — Built in section, card, Settings pointer, Inbox Retry

**Depends on:** Task 9

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Automations/BuiltinAutomationCard.swift`
- Modify: `Views/Automations/AutomationsView.swift`, `AutomationListRow.swift`, `AutomationEditorPanel.swift` / `AutomationDraftColumn.swift` (built-in save buttons), `Services/FeatureManagerService.swift` (`disableNow`), `Views/Settings/FeaturesSettings.swift`, `Services/ConfigService.swift` (drop `dayPlanHour`), `Views/Inbox/InboxSplitView.swift`, `InboxReadingPane.swift`, `WatchtowerCore/Services/Inbox/InboxCards.swift` (C1: `InboxFeedSnapshot`), `WatchtowerCore/Database/Queries/InboxFeedQueries.swift` (C1: `read`, `observedTables`), `WatchtowerCore/Services/Inbox/InboxListBuilder.swift` (C1's `sections(_:filter:…)`), `WatchtowerCore/Services/Actions/ActionStripViewModel.swift` (the `InboxSelection` enum and C1's `badgeCount` body only)
- Test: `Tests/Core/InboxAllKindsBuilderTests.swift` (C1, extended), `Tests/Core/InboxFeedQueriesTests.swift` (C1, extended), `Tests/FeatureManagerServiceTests.swift`, `Tests/Core/AutomationDraftFooterTests.swift`, `Tests/BuiltinAutomationCardViewTests.swift` (create)

**Interfaces:**
- Consumes: `BuiltinAutomationCardModel`, `BuiltinUpgradeNotice`, `AutomationsCLI.reset/upgradeBuiltins`, `FeatureManagerService.enableNow`.
- Produces:
  - `func FeatureManagerService.disableNow(_ ids: [String], restart: @MainActor () async throws -> Void) async -> (disabled: [String], restarted: Bool, busy: Bool)` — mirror of `enableNow`, writes only the named keys (FEAT-04).
  - The built-in card (panel detail when a Built in row is selected): header name + **Turn Off**/**Turn On** (through `featureManager.enableNow/disableNow(detail.featureIDs)` + daemon restart — the FEAT-03 hooks run inside `features enable`), **Run Now** (hidden when `detail.runNow == false`; disabled while off; shows "Runs at the next sync" after queueing), **Edit in Chat** (opens the existing editor panel on the automation; for a built-in the editor's context block adds the `default_prompts` with one line "To change a prompt, replace builtin.defaultPrompt(\"<name>\") with the text, keeping every %s in order."), ⋯ menu with **Reset to built-in** (only when `overridden`) → inline confirm row; **When** (the `when` line plus the parameters as a hour picker 0–23 and two `HH:MM` fields, with a **Save** that appears on change and writes through `ConfigService` + daemon restart — outside the recipe and its hash), **Reads**, **Sends**, **Costs**; the "Built-in version updated" banner with **Show changes** (inline diff, the draft column's diff rows) and **Reset to built-in**; the unconfirmed-copy line. No Delete for built-ins (row context menu too).
  - Draft footer for a built-in: **Save** (confirms) and, when the built-in is off, **Save and Turn On** (save + confirm, then `enableNow`). No other footer changes.
  - Settings → Features: the Briefing and Day Plan tuning sections are removed and `FeatureManagerSection` hides the `briefing` and `day-plan` rows; one row "These now live in Automations → Built in" with **Open Automations** (navigates to `.automations`).
  - Inbox, inside C1's one pure read (STRIP-02):
    - `InboxFeedSnapshot` gains `package var builtinNotices: [BuiltinUpgradeNotice] = []`, filled inside `InboxFeedQueries.read` by `BuiltinUpgradeNotice.load(db)` in the same `dbPool.read` (missing table → empty, C1's rule); `InboxFeedQueries.observedTables` gains `builtin_migrations`.
    - `InboxListItem.builtinNotice(BuiltinUpgradeNotice)` / `InboxSelection.builtinNotice(String)` (the built-in id); C1's `InboxListBuilder.sections(_:filter:…)` puts the notices first in **Needs your decision** under the `All` and `Automations` filters only (never Day, Messages, Tracks, Ideas).
    - Its pane: the title, the recorded error as secondary text, **Retry** → `upgradeBuiltins` then daemon restart; the card disappears when the next load has no `failed` row.
    - Badge: the badge formula is C1 R1's (which already lists "+ built-in upgrade notices (C2)"); C1's `badgeCount` body gains `+ notices.count` (`BuiltinUpgradeNotice.load` through `zeroIfTableMissing`).
- [ ] **Step 1: Write the failing tests:**
  - Extend C1's `testFilterShowsOnlyItsKind` (`InboxAllKindsBuilderTests`) with a notice case: a snapshot with one notice → the notice is in **Needs your decision** under `.all` and `.automations` and absent from the other four filters; the existing per-filter assertions stay.
  - Extend C1's `testBadgeCountsDecisionsUnreadMessagesLatestUnreadDayAndDueReminders` (`InboxFeedQueriesTests`) with a second case: the same fixture plus one `failed` `builtin_migrations` row and one `done` row → `badgeCount == 7`; the existing no-notice fixture still expects `6`.
  - `testReadFillsBuiltinNoticesInTheSameRead` (`InboxFeedQueriesTests`): one `failed` row → `read(...).builtinNotices.count == 1`; C1's `testRefreshIsStillOnePureRead` stays green with the row seeded.
  - `testBuiltinNoticeInNeedsYourDecision` (`InboxAllKindsBuilderTests`: first rows of the section, before proposals).
  - `testRunNowHiddenWhenRunNowFalse` (`BuiltinAutomationCardViewTests`).
  - `testDisableNowWritesOnlyNamedKeysAndRestartsOnce`, `testBuiltinFooterOffersSaveAndTurnOnWhenOff`, `testBuiltinFooterHasNoDelete`.
- [ ] **Step 2: Run** `make test-swift FILTER='InboxAllKindsBuilderTests|InboxFeedQueriesTests|ActionStripAllKindsTests|InboxListBuilderTests|BuiltinAutomationCardViewTests|FeatureManagerServiceTests|AutomationDraftFooterTests'` — FAIL (new) / PASS (C1's and B's existing tests).
- [ ] **Step 3: Implement** the views from DesignKit components only.
- [ ] **Step 4: Run** the same filter, `make lint-swift`, `make desktop-shots DESKTOP_SHOTS=<scratch dir>` and look at the Built in section, a shipped card, an overridden card with the banner and Show changes open, the Reset confirm row, Settings → Features and the Inbox notice in light and dark.
- [ ] **Step 5: Commit** `feat(desktop): Automations → Built in, Morning brief card, Settings pointer, Inbox Retry`.

---

### Task 11: Docs — feature note, guide, CLI reference, skill

**Depends on:** Task 7, Task 8, Task 10

**Files:**
- Create: `docs/features/built-in-automations.md`
- Modify: `docs/features/automations.md` (a "Built-ins (C2)" section + header line), `CLAUDE.md` (Feature Notes entry), `docs/guide/features/automations.md`, `docs/guide/features/briefings.md`, `docs/guide/features/day-plan.md`, `docs/guide/reference/cli.md`, `docs/guide/reference/settings.md`, `docs/guide/concepts/features-on-and-off.md`, `docs/guide/troubleshooting/no-briefing-or-day-plan.md`, `internal/skills/shipped/create-automation.md` ("Editing a built-in" section; bump the pack version where the skill pack requires it)

**Interfaces:**
- Consumes: the shipped behaviour of Tasks 1–10.
- [ ] **Step 1: Write the feature note:** registry and slots, the row model (`builtin:<id>`, `.builtin/<id>.md`, `overridden`, `builtin_base_hash`), the AUTO-06 amendment and its guards, the `sync` trigger and in-cycle runs (dedicated executor, poll skip, Run Now at the next sync), the primitive contract (`PrimitiveCall`/`PrimitiveResult`, journal as `llm` steps, usage in the meter), Morning brief (gates, attempts, files, `pipeline_runs` names, conflict phase stays Go, `day_plan.hour` retired), CLI paths, the upgrade step and its legacy fallback, the Go↔Swift dual paths (the eight listed in Task 9 plus `run_now` and the config keys), the Inbox notice inside C1's `InboxFeedQueries.read` and the badge formula (cite C1 R1, do not restate it), v1 limits (legacy phases kept until the release after C3; deleting the copy by hand equals Reset), and "How C3 plugs in", as numbered steps in exactly this order (the order C3 follows; C3 appends its own "C3" section and does not rewrite this one): (1) a `builtin.Entry` in `All()` (incl. `RunNow`/`NoRunNowNote`); (2) its `Slot` constant (already reserved in `SyncSlots`); (3) its primitive names appended to `BuiltinPrimitiveNames`; (4) a `PrimitiveCapability` entry only when its capability is not `builtin:<name>` (`CapabilityForPrimitive`), and a `syncTriggerAllowed` case only when a non-built-in scope may use the slot; (5) its `Gate`; (6) its `PrimitiveFunc`s added to `Daemon.BuiltinPrimitives()`; (7) its `PromptRef`s and `Parameter`s; (8) the golden show JSON `testdata/show_<id>.json`, plus a `BuiltinUpgradeNotice.name(for:)` row on the Swift side.
- [ ] **Step 2: Update the guide pages** per `docs/guide/WRITING.md` (user words, no internals); every page stays under 8 192 bytes.
- [ ] **Step 3: Run** `go test ./docs/guide ./internal/skills/...` — PASS.
- [ ] **Step 4: Commit** `docs: built-in automations and the Morning brief`.

---

### Task 12: Phase gate and owner review

**Depends on:** Task 1–Task 11

- [ ] **Step 1:** `bash scripts/dev-health.sh` — not `HEALTH: overloaded`.
- [ ] **Step 2:** `make test` (incl. `go test ./cmd/... -timeout 30m`), `make test-swift`, `make lint-all` — all green; `go test -race ./internal/automations/... ./internal/daemon -run 'Builtin|MorningBrief'`.
- [ ] **Step 3:** Re-read `docs/inventory/automations.md`, `features.md` and the OWNER file: every guard listed exists by name and passes; `git diff origin/main -- '*_test.go'` shows no deleted or relaxed assertion in a `TestAuto*`, `TestFeat*`/`TestFeatureGates*`, `TestFastForward*` or `TestOwner02*` test.
- [ ] **Step 4:** Manual check on a scratch workspace (never the live DB): fresh install → brief and plan before the hour; Edit in Chat → Save → copy confirmed and used by `briefing generate`; hand-edit the copy → card shows the unconfirmed line and no run; Reset → shipped again; Turn Off → no runs, Settings pointer; failed upgrade (read-only `.builtin`) → Inbox notice → Retry.
- [ ] **Step 5:** Run the `local-review` skill on the branch, fix accepted findings, then open the PR and ask the owner (an `ask_owner` in Russian) to review the AUTO-06 / FEAT wording and the Built in card screenshots before merge.

---

## Rulings on spec ambiguities

- Owner copy path: §5.2 names both `.builtin/<id>.md` and `builtin-<id>.md`; the plan uses `<workspace>/automations/.builtin/<id>.md` (the Personal scanner already ignores directories, so no new skip rule).
- The built-in row's path stays `builtin:<id>` whether or not an owner copy exists (one row per built-in, history and costs continuous); `overridden` says the text comes from the copy.
- Origin is carried in the scope: `Scope{Kind: personal, BuiltinID}` with `Scope.String() = "builtin:<id>"`, so the approval hash binds the built-in id and existing canonical bytes are unchanged.
- The amendment is implemented as a dedicated confirmation (`ConfirmShippedBuiltin`) of byte-equal shipped text by the built-in indexer, not as a change to `Runnable()`; an owner copy byte-equal to the shipped text is runnable too (the amendment's wording is "bytes equal").
- `builtin.defaultPrompt(name)` takes the prompt's name (`"brief"`, `"plan"`) because Morning brief has two prompts; it returns the shipped default for the owner's role (`DefaultForRole`), never the DB prompt store.
- Primitive signatures: `brief.compose({prompt})`, `plan.compose({prompt})`; the date, feedback and force come from Go (the run's input or today), not from the script, so a recipe cannot aim the brief at another date.
- A sync run is created only when the Go gate says due (no row per cycle); Run Now's manual run skips the gate but not idempotency (an existing brief is kept, the plan is regenerated only with feedback/force).
- On/off for a two-key built-in: on = either key on; Turn On/Off writes both keys; each primitive keeps its own key's gate (today's independent phases).
- `day_plan.hour` is dropped from config and the Desktop; the readiness copy uses `briefing.hour` for the plan.
- `briefing generate` / `day-plan generate` run the built-in's recipe inline as a manual run limited by `only`, requiring a confirmed recipe but not the feature switch (today's forcing).
- Primitive steps are journalled as `kind = 'llm'` (name = primitive) to avoid rebuilding `automation_run_steps`; built-in runs carry the new run trigger `sync`.
- The legacy `phaseBriefing`/`runDayPlanPhase` stay in code as the failure fallback of §8 and are removed in a later release.
- The upgrade step carries the template today's `GetForRole` actually resolved (a customised role row wins over a customised base row) and confirms only the copy it rendered.
- Foreground `watchtower sync` never ran the briefing; nothing changes there.
