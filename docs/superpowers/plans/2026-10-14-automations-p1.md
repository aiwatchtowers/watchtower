# Automations P1 (core) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Automations core — recipe + manifest parser, goja sandbox with the P1 SDK (`llm`, read `tool`, `state`, `output.inbox`/`report`, `log`), the run/step journal, a cron scheduler and a run executor in the daemon, token budgets, and the `watchtower automations` CLI — with every seam P2–P6 build on.

**Architecture:** A recipe is a Markdown file indexed into `automations` (migration 00113); the executor always runs the indexed copy. Triggers (scheduler tick, CLI `run`) only insert `queued` rows; one executor goroutine in the daemon claims them under a per-automation concurrency check, runs the script in a fresh goja runtime whose only world is the SDK modules, journals every SDK call as a step, debits tokens, and commits state + outputs only on success. The daemon wakes the scheduler/executor through its own `SIGUSR2` watcher, never through the sync loop.

**Tech Stack:** Go 1.26, SQLite (`modernc.org/sqlite`, goose migrations), `github.com/dop251/goja` (new), `github.com/robfig/cron/v3` (new, parser only), cobra, `github.com/google/jsonschema-go` (already a dependency), Swift only for the AGENT-07 marker constant and the regenerated test schema.

**Spec:** `docs/superpowers/specs/2026-10-14-automations-design.md` (decisions in §20, ask #270, and §20.1, asks #271–#273 and #277). Business spec: `docs/superpowers/specs/2026-10-14-automations-business.md`.

**Branch:** work lands on `feature/automations` (one PR for this phase into it). Never `main`.

## Global Constraints

- All repo text English; repo is public — fixtures use `acme`, `example.com`, `<corp-domain>`; no real ids, no local absolute paths in tests (use `t.TempDir()`).
- Inner loop only: `go test ./internal/<pkg>` (no `-count=1` reflexively), `go test ./cmd -run '<Name>'` (never the whole `./cmd` package per task), `make test-swift FILTER=<Class>`, `make lint-diff`. The full gate (`make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`) runs once at the end of the phase by the controller.
- Tests that start a subprocess kill its process group and wait for it in `t.Cleanup` (P1 starts none except through fakes; keep it that way).
- Transactions are `BEGIN IMMEDIATE`; read-only reads use `BeginTx(ctx, &sql.TxOptions{ReadOnly: true})`; never hold a write tx across an LLM call or script execution.
- Migration number **00113** (`origin/main` ends at 00112 on 2026-10-14). Before merging, re-check `internal/db/migrations` on `origin/main`; if 00113 is taken, renumber and verify by table presence, not goose version.
- Every exact value below comes from the spec; do not change one without the spec changing first:
  - Recipe: max file 256 KiB; slug `^[a-z0-9][a-z0-9-]{0,63}$`; `name` 1–80 chars; exactly one ```` ```js ```` / ```` ```javascript ```` block; unknown frontmatter key = parse error; `workbench:` key = parse error (D15); a `usd` key inside `budget` = parse error (D4).
  - Defaults/bounds: `budget.tokens` default 50000, `1000 ≤ tokens ≤ 2000000`; `budget.minutes` default 5, `1..60`; `concurrency` default 1, `1..4`; `missed` default `run_once` (`run_once|skip`); `pause_timeout_hours` default 72, `1..168`; `trigger` exactly one of `schedule|button|event|manual`; `button.label` 1–24 chars, `button.confirm` default false; event types `slack.new_messages`, `gmail.new_messages`, `jira.issue_changed`, `calendar.event_changed`, `confluence.page_changed`.
  - Sandbox limits: SDK result ≤ 256 KiB serialised (else `ResultTooLarge`, never truncated); list tools `limit` default 50, max 200 (injected/clamped); `llm` input ≤ 200 KiB; state ≤ 64 KiB (`StateTooLarge`); `output.*` body ≤ 64 KiB; `log` 4 KiB per call, 200 calls per run; step `args_json`/`result_summary` clipped 4 KiB; run `summary` clipped 1 KiB; email body clipped 32 KiB; D23 reads (ask #277): calendar event and Jira release `description` clipped 4 KiB, meeting recap `source_text` and `recap` clipped 32 KiB.
  - Executor: `maxConcurrentRuns = 2` (running only; waiting not counted); poll 10 s; schedule grace 2 min; cron 5-field, local time zone.
  - Budgets are tokens (D4): debit per `llm` call = `Usage.InputTokens + Usage.OutputTokens`; a call with no usage debits `ceil(len(prompt+input+reply)/4)` and sets `tokens_estimated`; `reported_cost_usd` stored only when the provider reports one, display only. Daily cap config `automations.daily_budget_tokens` default `2000000`, local calendar day, dry runs included.
  - Source tags: `automation.llm` (light, added to `digest.TierForSource`'s light switch) and `automation.llm.strong` (strong, added to `allowedStrongSources` with reason "the owner chose tier: strong in the recipe").
  - Wake: `daemon.AutomationWakeSignal = syscall.SIGUSR2` (D1); `SIGUSR1` keeps meaning "sync".
  - Personal recipe folder `<config.WorkspaceDir()>/automations/` (D8).
  - Registry surface `"automation"`, context type `"automation_run"`.
  - Feature `automations` (config key `automations.enabled`, default ON, D12).
  - AGENT-07 marker list gains `WATCHTOWER_AUTOMATION_RUN_ID` (Go `cmd/actions.go` and Swift `Constants.agentEnvMarkers`).
- `list_emails`/`get_email` read only `gmail_messages`/`imap_messages`, never a live API; no per-flavour gating (D2).
- Guard tests for inventory contracts are named `TestAuto0N_…` / `TestAuto1N_…` and never weakened.

## Review Focus

1. **A recipe edited on disk while one of its runs is in flight** — the run keeps executing the snapshot it claimed (`recipe_snapshot`), and the next rescan makes the automation non-runnable until confirmed if `approval_hash` changed. Pinned in Task 10 (`TestAuto06_EditDuringRunDoesNotAffectRunningSnapshot`).
2. **A script that catches every error and loops** (`while(true){try{llm("x")}catch(e){}}`) — `BudgetExceeded`/deadline interrupts cannot be swallowed by JS `catch`; the run still ends `budget_exceeded`/`timed_out`. Pinned in Task 6 (`TestSandbox_InterruptIsNotCatchable`) and Task 10 (`TestAuto08_CatchAllLoopStillEndsOnBudget`).
3. **Recipe files with CRLF line endings, a UTF-8 BOM, or invalid UTF-8** — CRLF and BOM parse like LF/no-BOM (same `approval_hash` as the LF twin); invalid UTF-8 is a parse error naming the file. Pinned in Task 3 (`TestRecipe_CRLFAndBOMNormalised`, `TestRecipe_InvalidUTF8Refused`).
4. **`state.set` with values JSON cannot represent** (functions, `undefined`, cyclic objects, `NaN`/`Infinity`, BigInt) — a `ValidationError` thrown at the `set` call, nothing buffered; never a panic at commit time. Pinned in Task 7 (`TestState_RejectsUnserialisableValues`).
5. **Two executors racing for one queued row** (the daemon and a CLI `dry-run`, or two daemons during a restart) — exactly one claim wins; the loser does nothing. Pinned in Task 2 (`TestAuto05_ConcurrentClaimsOneWinner`).

---

## File structure

| Path | Responsibility |
|---|---|
| `internal/db/migrations/00113_automations.sql` | tables §9.1–9.4 (no `automation_tool_grants` — that is 00114/P2) |
| `internal/db/schema.sql` | mirror |
| `internal/db/automations.go` | index rows (`automations`) |
| `internal/db/automation_runs.go` | runs, steps, state, outputs, queue, claim, finish/commit, daily tokens |
| `internal/automations/limits.go` | every constant of Global Constraints (plus `MaxEventsPerRun`) |
| `internal/automations/recipe.go`, `hash.go` | parsing, normalisation, hashes |
| `internal/automations/manifest.go`, `capabilities.go` | grammar, matching, widening, tool → capability table |
| `internal/automations/sandbox.go`, `errors.go` | goja runtime, SDK registration seam, interrupt, error mapping |
| `internal/automations/journal.go`, `meter.go`, `commit.go` | step journal, token/time meter, state/output buffer |
| `internal/automations/backends.go` | `Backends`, `ToolRegistry` and the backend interfaces later phases implement (`ShellRunner`, `WorkbenchResolver`) |
| `internal/automations/sdk_llm.go`, `sdk_tool.go`, `sdk_state.go`, `sdk_output.go`, `sdk_log.go`, `modules.go` | P1 SDK modules |
| `internal/automations/dryrun_memory.go` | `DryRunInMemory` (a dry run that writes no row at all — P3's `draft_automation`) |
| `internal/automations/indexer.go` | folder → index rows |
| `internal/automations/executor.go` | claim/run/finish loop |
| `internal/automations/scheduler.go`, `clock.go` | cron ticks, missed policy |
| `internal/automations/automationstest/` | `FakeClock`, `FakeGenerator`, `FakeRegistry`, `SeedAutomation` — exported for P2–P6 tests |
| `internal/tools/emails.go` | `list_emails`, `get_email` |
| `internal/tools/automation_reads.go` (+ `internal/db/automation_reads.go` for helpers none of the existing ones fit) | the D23 local reads (ask #277): `list_inbox`, `list_calendar_events`, `list_meeting_recaps`, `get_meeting_recap`, `list_meeting_notes`, `list_day_plans`, `get_day_plan`, `list_reminders`, `list_jira_sprints`, `list_jira_releases` |
| `cmd/automations_registry.go` | `buildAutomationRegistry` — `buildToolRegistry` + the memory tools |
| `internal/tools/registry.go` | `AutomationSurface`, `AutomationContextType` constants only (Binding changes are P2) |
| `internal/daemon/automation_wake.go`, `internal/daemon/daemon.go` | SIGUSR2 watcher; goroutine start |
| `internal/config/config.go` | `AutomationsConfig` |
| `internal/features/registry.go` | `automations` feature |
| `internal/digest/models.go`, `internal/digest/tier_scan_test.go` | source tags |
| `cmd/automations.go`, `cmd/automations_run.go`, `cmd/automations_wake.go` | CLI |
| `cmd/actions.go`, `WatchtowerDesktop/Sources/WatchtowerCore/Utilities/Constants.swift` | AGENT-07 marker |
| `docs/inventory/automations.md`, `docs/inventory/README.md`, `docs/inventory/agent-actions.md` (changelog), `docs/features/automations.md`, `CLAUDE.md` | docs |

---

### Task 1: Migration 00113 and the automation index store

**Files:**
- Create: `internal/db/migrations/00113_automations.sql`, `internal/db/automations.go`, `internal/db/automations_test.go`
- Modify: `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), golden snapshot + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerated)

**Interfaces:**
- Consumes: nothing.
- Produces (package `db`):
  - Tables `automations`, `automation_runs`, `automation_run_steps`, `automation_state`, `automation_outputs` exactly as spec §9.1–§9.4, with `budget_tokens` (not usd), `tokens_estimated`, `reported_cost_usd REAL NULL`, `error_kind` CHECK list, indexes incl. unique `(automation_id, event_cycle) WHERE event_cycle IS NOT NULL` and partial unique `(automation_id, trigger) WHERE status='queued'`, `automation_runs.event_json` documented in the migration's column comment and in `schema.sql` as: `''` for every non-event run; for `trigger='event'` exactly `{"cycles": ["<cycle id>", …], "events": [<event>, … at most 100], "count": <total matched>, "truncated": <bool>}` (spec §8; the shape P4's bus writes and the executor decodes), unique `(scope, COALESCE(project_id,0), slug)`, CHECK `(scope='workbench') = (project_id IS NOT NULL)`.
  - `type Automation struct { ID int64; Slug, Scope string; ProjectID int64 /*0 = personal*/; Path, Name, TriggerKind, TriggerSpec, MissedPolicy string; Concurrency, BudgetTokens, BudgetMinutes, PauseTimeoutHours int; PermissionsJSON, OutputsJSON, RecipeText, ContentHash, ApprovalHash, ConfirmedHash, ParseError string; Enabled bool; LastScheduledFor, NextRunAt, RemovedAt *time.Time; CreatedAt, UpdatedAt time.Time }`
  - `func (a Automation) Runnable() bool` — `ParseError == "" && Enabled && RemovedAt == nil && ConfirmedHash != "" && ConfirmedHash == ApprovalHash`.
  - `func (d *DB) UpsertAutomationIndex(a Automation) (id int64, err error)` — keyed by `path`; never touches `confirmed_hash`, `enabled`, `last_scheduled_for` of an existing row; clears `removed_at`.
  - `func (d *DB) GetAutomation(id int64) (*Automation, error)`; `func (d *DB) GetAutomationBySlug(scope string, projectID int64, slug string) (*Automation, error)`; both return `ErrNotFound`.
  - `type AutomationFilter struct { Scope string; ProjectID int64; TriggerKind string; RunnableOnly bool; IncludeRemoved bool }`; `func (d *DB) ListAutomations(f AutomationFilter) ([]Automation, error)` (slug order).
  - `func (d *DB) MarkAutomationsRemovedExcept(scope string, projectID int64, keepPaths []string, now time.Time) (int, error)`.
  - `func (d *DB) SetAutomationEnabled(id int64, enabled bool, now time.Time) error` — enabling sets `last_scheduled_for = now`.
  - `func (d *DB) ConfirmAutomation(id int64, hash string) error` — `ErrHashMismatch` when `hash != approval_hash` (row unchanged).
  - `func (d *DB) SetAutomationSchedule(id int64, lastScheduledFor, nextRunAt *time.Time) error`.
  - `func (d *DB) DeleteAutomation(id int64) error` (cascade).
  - `var ErrHashMismatch = errors.New("approval hash does not match the recipe")`.
- Depends on: none.

- [ ] **Step 1: Write failing tests** in `internal/db/automations_test.go`:
  - `TestMigration00113_AutomationTables` — every table and index exists after `Open(":memory:")`; inserting a workbench row with NULL `project_id` → CHECK error; personal with non-NULL → CHECK error.
  - `TestAutomationIndex_UpsertKeepsOwnerColumns` — upsert, `ConfirmAutomation(h)`, `SetAutomationEnabled(true)`, upsert again with new `RecipeText` → `confirmed_hash`, `enabled`, `last_scheduled_for` unchanged, `recipe_text` updated.
  - `TestAutomationIndex_ConfirmRefusesStaleHash` — `ConfirmAutomation(id, "other")` → `ErrHashMismatch`, `confirmed_hash` still ''.
  - `TestAutomationIndex_RunnableTable` — table over parse error / disabled / removed / unconfirmed / confirmed-but-changed (`approval_hash` ≠ `confirmed_hash`) / ok → only ok is runnable.
  - `TestAutomationIndex_EnableSetsLastScheduledForNow`.
  - `TestAutomationIndex_MarkRemovedExcept` — two rows, keep one path → other gets `removed_at`; re-upsert clears it.
  - `TestAutomationIndex_SlugUniquePerScope` — same slug personal + workbench 1 + workbench 2 allowed; duplicate in one scope → error.
  - Add the five tables to `TestAllTablesExist`.
- [ ] **Step 2:** `go test ./internal/db -run 'TestMigration00113|TestAutomationIndex|TestAllTablesExist'` → FAIL.
- [ ] **Step 3:** Write the migration (Up + Down), mirror into `schema.sql`, implement `automations.go`.
- [ ] **Step 4:** `go test ./internal/db -run 'TestSchemaGolden|TestDesktopTestSchema' -update`, then the Step 2 command → PASS; `go test ./internal/db` → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): migration 00113 and the automation index store`.

### Task 2: Runs, steps, state, outputs, queue and claim store

**Files:**
- Create: `internal/db/automation_runs.go`, `internal/db/automation_runs_test.go`

**Interfaces:**
- Consumes: Task 1 tables and `Automation`.
- Produces (package `db`):
  - Constants `RunQueued, RunRunning, RunWaiting, RunSucceeded, RunFailed, RunBudgetExceeded, RunTimedOut, RunCancelled, RunExpired = "queued", …`; triggers `TriggerSchedule, TriggerCatchUp, TriggerButton, TriggerEvent, TriggerManual, TriggerDryRun`; waiting reasons `WaitNone="", WaitApproval, WaitAsk, WaitSession, WaitApp`; error kinds `ErrKindScript, ErrKindPermission, ErrKindBudget, ErrKindDailyCap, ErrKindTimeout, ErrKindInterrupted, ErrKindNotRunnable, ErrKindExpired, ErrKindCancelled, ErrKindBackend`.
  - `type AutomationRun struct { ID, AutomationID int64; Trigger string; ScheduledFor *time.Time; EventCycle, EventJSON string; RerunOf int64; Status, WaitingReason, RecipeHash, RecipeSnapshot string; BudgetTokens, BudgetMinutes int; InputTokens, OutputTokens int64; TokensEstimated bool; ReportedCostUSD *float64; ActiveMS int64; Error, ErrorKind, Summary string; QueuedAt time.Time; StartedAt, FinishedAt *time.Time }`
  - **Queue insert API:** `type EnqueueRequest struct { AutomationID int64; Trigger string; ScheduledFor *time.Time; EventCycle, EventJSON string; RerunOf int64; AdvanceScheduleTo *time.Time; NextRunAt *time.Time; Now time.Time }`; `func (d *DB) EnqueueAutomationRun(r EnqueueRequest) (runID int64, coalesced bool, err error)` — one tx, checks in this order: (1) if `EventCycle` is set and a run of the automation already carries that cycle — in its `event_cycle` column **or** in its `event_json` `cycles` array (a cycle P4 merged into an earlier queued run, `json_each`) → returns that run, `coalesced=true`; (2) if a `queued` row of (automation, trigger) exists → returns its id, `coalesced=true`, inserts nothing (P4 then merges the new cycle's events into it with `db.MergeQueuedAutomationRunEvents`, which never creates a run and never touches `event_cycle`); else inserts. When `AdvanceScheduleTo` is set, `last_scheduled_for`/`next_run_at` advance in the same tx (whether or not a row was inserted).
  - `func (d *DB) NextQueuedAutomationRuns(limit int) ([]AutomationRun, error)` (oldest `queued_at` first).
  - `func (d *DB) ClaimAutomationRun(runID int64, recipeHash, recipeSnapshot string, budgetTokens, budgetMinutes int, now time.Time) (bool, error)` — one conditional UPDATE: `status='queued'` AND active (`running`+`waiting`) count of the automation `< automations.concurrency`; snapshots hash/snapshot/budgets.
  - `func (d *DB) CancelQueuedNotRunnable(runID int64, now time.Time) error` → `cancelled`, `error_kind='not_runnable'`.
  - `func (d *DB) CancelAutomationRun(runID int64, now time.Time) (bool, error)` — `queued|running|waiting → cancelled`, `error_kind='cancelled'`; false if already terminal.
  - `func (d *DB) SetAutomationRunWaiting(runID int64, reason string) error` — from `running` (→ `waiting` with `reason`) **or from `waiting`** (reason change only: `waiting_reason` updated, status and `active_ms` untouched — P5's `session()` moves `app` → `session` inside one wait without a running blip); any other status → `ErrRunNotActive`. `ResumeAutomationRun(runID int64) error` only from `waiting`.
  - `type AutomationEventPayload struct { Cycles []string `json:"cycles"`; Events []json.RawMessage `json:"events"`; Count int `json:"count"`; Truncated bool `json:"truncated"` }` — the `event_json` shape of Task 1 (slices never nil when marshalled); P4's bus and merge write it, the executor decodes it.
  - `func (d *DB) GetAutomationRun(id int64) (*AutomationRun, error)`; `ListAutomationRuns(automationID int64, limit int) ([]AutomationRun, error)`; `ListActiveAutomationRuns() ([]AutomationRun, error)`.
  - `type RunUsage struct { InputTokens, OutputTokens int64; Estimated bool; ReportedCostUSD *float64; ActiveMS int64 }`; `func (d *DB) AddAutomationRunUsage(runID int64, u RunUsage) error`.
  - `type RunFinish struct { Status, ErrorKind, Error, Summary string; Now time.Time }`; `type RunCommit struct { StateJSON json.RawMessage /*nil = unchanged*/; Outputs []AutomationOutput }`; `func (d *DB) FinishAutomationRun(runID int64, f RunFinish, c *RunCommit) error` — conditional on `status IN ('running','waiting')`, else `ErrRunNotActive`; a non-nil `c` is accepted only with `Status == RunSucceeded` (else `ErrCommitOnFailure`) and is written in the same tx.
  - `var ErrRunNotActive, ErrCommitOnFailure error`.
  - `func (d *DB) MarkInterruptedAutomationRuns(now time.Time) (int, error)` — every `running`/`waiting` → `failed`, `error_kind='interrupted'`.
  - `func (d *DB) AutomationTokensBetween(from, to time.Time) (int64, error)` — sum of input+output over runs with `started_at` in `[from,to)`.
  - `func (d *DB) MarkAutomationRunStep(id int64, status string, link StepFinish) error` — a **non-final** update: writes `status` and only the non-zero `link.ActionID`/`AskID`/`SessionID`; `finished_at` stays NULL (a step that waits — P2 `{wait:true}`, P5 `session()`/`ask()`).
  - Steps: `type AutomationRunStep struct { ID, RunID int64; Seq int; Kind, Name, ArgsJSON, ResultSummary, Status string; Auto bool; Permission string; ActionID, AskID, SessionID int64; InputTokens, OutputTokens int64; TokensEstimated bool; ReportedCostUSD *float64; DurationMS int64; Error string; StartedAt time.Time; FinishedAt *time.Time }`; `func (d *DB) AppendAutomationRunStep(s AutomationRunStep) (int64, error)` (assigns `seq` = max+1 in tx); `type StepFinish struct { Status, ResultSummary, Error string; Auto bool; ActionID, AskID, SessionID int64; InputTokens, OutputTokens int64; TokensEstimated bool; ReportedCostUSD *float64; DurationMS int64; Now time.Time }`; `func (d *DB) FinishAutomationRunStep(id int64, f StepFinish) error`; `func (d *DB) ListAutomationRunSteps(runID int64) ([]AutomationRunStep, error)`.
  - State/outputs: `func (d *DB) GetAutomationState(automationID int64) (json.RawMessage, error)` (`{}` when absent); `type AutomationOutput struct { ID, AutomationID, RunID int64; Kind, Title, Body, Priority string; CreatedAt time.Time; ReadAt, DismissedAt *time.Time }`; `func (d *DB) ListAutomationOutputs(kind string, limit int) ([]AutomationOutput, error)`.
- Depends on: Task 1.

- [ ] **Step 1: Failing tests** in `internal/db/automation_runs_test.go`:
  - `TestEnqueue_InsertsQueued` — row `queued`, `queued_at` = Now.
  - `TestRun_CoalescesSecondTrigger` — two `manual` enqueues → same id, second `coalesced=true`, one row; a `button` enqueue alongside → separate row.
  - `TestEnqueue_EventCycleOncePerAutomation` — same `EventCycle` twice (second after the first finished) → coalesced, still one row.
  - `TestEnqueue_EventCycleMergedIntoEarlierRunIsCoalesced` — a finished event run with `event_cycle` A and `event_json.cycles` [A, B] (seeded by raw SQL, as P4's merge leaves it); enqueue with `EventCycle` B → coalesced onto it, no row inserted.
  - `TestEnqueue_EventCycleCheckedBeforeQueuedCoalescing` — a queued event run of cycle A; enqueue cycle A again → returns it with `coalesced=true`; enqueue cycle B → returns it with `coalesced=true` (the caller merges).
  - `TestEnqueue_AdvancesScheduleAtomically` — `AdvanceScheduleTo` set and coalesced → `last_scheduled_for` still advances.
  - `TestAuto05_OneActiveRunPerAutomation` (db level) — concurrency 1, two queued: first claim true, second false until the first finishes, then true.
  - `TestAuto05_ConcurrencyN` — concurrency 3: three claims true, fourth false.
  - `TestAuto05_ConcurrentClaimsOneWinner` — 8 goroutines claim the same queued row on a file DB (`t.TempDir()`) → exactly one `true`.
  - `TestAuto04_FinishCommitOnlyOnSuccess` — `FinishAutomationRun(failed, commit)` → `ErrCommitOnFailure`, state and outputs byte-identical, run still running; `succeeded` with commit → state replaced and outputs inserted in one tx.
  - `TestFinish_RefusesTerminalRun` — after `CancelAutomationRun`, `FinishAutomationRun(succeeded, commit)` → `ErrRunNotActive`, nothing committed.
  - `TestAuto08_RestartMarksInterrupted` (db level) — running + waiting rows → `failed`/`interrupted`; queued untouched.
  - `TestRunWaiting_ReasonChangeWhileWaiting` — `running` → `waiting`/`app`; again with `session` → still `waiting`, reason `session`, `active_ms` unchanged; on a `succeeded` run → `ErrRunNotActive`.
  - `TestSteps_MarkIsNonFinal` — `MarkAutomationRunStep(id, "waiting", StepFinish{ActionID: 7})` → status `waiting`, `action_id` 7, `finished_at` NULL; a later `FinishAutomationRunStep` closes it.
  - `TestEventPayload_MarshalsEmptyArrays` — zero `AutomationEventPayload` → `{"cycles":[],"events":[],"count":0,"truncated":false}`.
  - `TestAutomationTokensBetween_LocalDayWindow` — runs at 23:59 and 00:01 local split across days.
  - `TestSteps_SeqIsDenseAndOrdered` — 3 appends → seq 1,2,3; finish writes tokens/duration.
- [ ] **Step 2:** `go test ./internal/db -run 'TestEnqueue|TestRun_|TestRunWaiting|TestAuto0|TestFinish_|TestAutomationTokens|TestSteps_|TestEventPayload'` → FAIL.
- [ ] **Step 3:** Implement `automation_runs.go`.
- [ ] **Step 4:** Step 2 command → PASS; `go test ./internal/db` → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): run queue, claim, journal and commit store`.

### Task 3: Recipe parser and hashes

**Files:**
- Create: `internal/automations/limits.go`, `internal/automations/recipe.go`, `internal/automations/hash.go`, `internal/automations/recipe_test.go`, `internal/automations/testdata/recipes/*.md`

**Interfaces:**
- Consumes: nothing (the manifest is parsed in Task 4; `ParseRecipe` calls `ParseManifest` once Task 4 lands — Task 3 stores the raw `[]string` and Task 4 wires validation).
- Produces (package `automations`):
  - `limits.go`: every constant of Global Constraints, exported: `MaxRecipeBytes, MaxSDKResultBytes, DefaultListLimit, MaxListLimit, MaxLLMInputBytes, MaxStateBytes, MaxOutputBodyBytes, MaxLogBytes, MaxLogCalls, StepClipBytes, SummaryClipBytes, EmailBodyClipBytes, MaxConcurrentRuns, PollInterval, ScheduleGrace, DefaultBudgetTokens, MinBudgetTokens, MaxBudgetTokens, DefaultBudgetMinutes, MinBudgetMinutes, MaxBudgetMinutes, DefaultConcurrency, MaxConcurrency, DefaultPauseTimeoutHours, MaxPauseTimeoutHours, DefaultDailyBudgetTokens, MaxEventsPerRun` (`MaxEventsPerRun = 100`, spec §8 — P4's bus consumes it).
  - `type ScopeKind string` (`ScopePersonal`, `ScopeWorkbench`); `type Scope struct { Kind ScopeKind; WorkbenchID int64 }`; `func (s Scope) String() string` → `"personal"` / `"workbench:<id>"`.
  - `type TriggerKind string` (`TriggerSchedule`, `TriggerButton`, `TriggerEvent`, `TriggerManual`); `type ButtonTrigger struct { Label string; Confirm bool }`; `type EventTrigger struct { Type string; Where map[string]string }`; `type Trigger struct { Kind TriggerKind; Schedule string; Button *ButtonTrigger; Event *EventTrigger }`; `var EventTypes = []string{"slack.new_messages","gmail.new_messages","jira.issue_changed","calendar.event_changed","confluence.page_changed"}`.
  - `type MissedPolicy string` (`MissedRunOnce`, `MissedSkip`); `type Budget struct { Tokens, Minutes int }`.
  - `type Recipe struct { Slug, Name string; Trigger Trigger; Missed MissedPolicy; Concurrency int; Permissions []string; Outputs []string; Budget Budget; PauseTimeoutHours int; Description, Script string; ScriptLine int /*1-based file line of the script's first line*/; Scope Scope }`
  - `type ParseError struct { Line int; Msg string }` (implements `error`, `"line N: msg"`).
  - `func ValidSlug(s string) bool`; `func ParseRecipe(slug string, data []byte, scope Scope) (*Recipe, error)` — normalises CRLF→LF and strips a UTF-8 BOM before anything else; validates cron with `cron.ParseStandard`.
  - `func ContentHash(data []byte) string` (hex sha256 of raw bytes); `func ApprovalHash(r *Recipe) string` — hex sha256 of canonical JSON `{"permissions":[sorted normalised],"outputs":[sorted],"scope":r.Scope.String(),"script":r.Script}` (keys in that order, no HTML escaping).
- Depends on: none (parallel with Tasks 1–2).

- [ ] **Step 1:** `go get github.com/robfig/cron/v3@<latest tag ≥ 2 weeks old>`; failing tests in `recipe_test.go`:
  - `TestRecipe_ParsesFrontmatterDescriptionAndOneJSBlock` — fixture `ok.md` → fields, defaults (`tokens 50000, minutes 5, concurrency 1, missed run_once, pause 72`), `ScriptLine` = line after the fence, description excludes the block.
  - `TestRecipe_AcceptsJavascriptInfoString`.
  - `TestRecipe_RejectsZeroOrTwoJSBlocks` — 0 blocks, 2 blocks → `*ParseError`.
  - `TestRecipe_RejectsUnknownKeyAndBadSlug` — key `permision:` → error naming the key; slug `Bad_Slug`, `-x`, 65 chars → `ValidSlug` false.
  - `TestRecipe_RejectsWorkbenchKey` (D15) and `TestRecipe_RejectsUSDBudget` (`budget: {usd: 1}` → error) (D4).
  - `TestRecipe_BudgetBounds` — tokens 999 / 2000001 / minutes 0 / 61 / concurrency 0 / 5 / pause 0 / 169 → errors; 1000 / 2000000 / 1 / 60 / 4 / 168 → ok.
  - `TestRecipe_TriggerExactlyOne` — none, two kinds → error; bad cron `"61 * * * *"` → error; event type `foo.bar` → error; button label '' / 25 chars → error.
  - `TestRecipe_TooLarge` — 256 KiB + 1 byte → error.
  - `TestRecipe_CRLFAndBOMNormalised` — CRLF + BOM twin of `ok.md` parses equal and has the same `ApprovalHash` (Review Focus 3).
  - `TestRecipe_InvalidUTF8Refused` (Review Focus 3).
  - `TestApprovalHash_IgnoresNameTriggerBudgetChangesOnScriptAndPermissions` — changing name/description/trigger/missed/budget/concurrency/pause keeps the hash; changing one script byte, adding a permission, adding an output, or switching scope personal→workbench:1 changes it; permission order does not matter.
- [ ] **Step 2:** `go test ./internal/automations -run 'TestRecipe|TestApprovalHash'` → FAIL.
- [ ] **Step 3:** Implement (`gopkg.in/yaml.v3` with `KnownFields(true)`).
- [ ] **Step 4:** Step 2 command → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): recipe parser and approval hash`.

### Task 4: Permission manifest

**Files:**
- Create: `internal/automations/manifest.go`, `internal/automations/capabilities.go`, `internal/automations/manifest_test.go`
- Modify: `internal/automations/recipe.go` (`ParseRecipe` validates via `ParseManifest`; `ApprovalHash` uses normalised entries)

**Interfaces:**
- Consumes: `Scope` (Task 3); `tools.Access` and `(*tools.Tool).VisibleOn` from `internal/tools`; read-only `db` lookups for account labels (`slack_accounts`, `google_accounts`, `email_accounts`, `calendar_accounts`).
- Produces:
  - `type Permission struct { Raw string; Capability, Verb, Scope string; Tool string; MCPServer, MCPGlob string; Shell string }`; `func ParsePermission(s string) (Permission, error)`; `func (p Permission) String() string` (normalised form: lower-case capability/verb/scope; Jira project and Confluence space scopes upper-case).
  - `type Manifest struct { /* unexported */ }`; `func ParseManifest(entries []string, outputs []string, scope Scope) (*Manifest, error)` — refuses unknown capability/verb, `@scope` on a scope-less capability, missing scope on a scoped one, `write` on the read-only capabilities `meetings` and `dayplan` (ask #277), and `shell:`/`session:`/`ask:` in a personal recipe (D7); folds duplicates; outputs ⊆ {inbox, briefing, report, target, slack}.
  - `func (m *Manifest) Normalized() []string` (sorted); `func (m *Manifest) Outputs() []string`.
  - `type PermissionDenied struct { Needed string }` (`error`).
  - Checks — each returns `(admittedBy string, err error)` with `err` a `*PermissionDenied`: `AllowTool(ctx context.Context, d *db.DB, t *tools.Tool, args json.RawMessage) (string, error)` (S1: `d` resolves account ids/addresses to labels; also denies when `!t.VisibleOn("automation")`; a `ScopeOf` error — e.g. an `account_id` of no account — is a `*PermissionDenied` naming `<capability>:<verb>@*`, never a panic), `AllowLLM(tier string)`, `AllowOutput(kind string)`, `AllowCapability(capability, verb, scope string)` (for `agent:run`, `ask:owner`, `session:start[@kind]` — used by P5/P6), `AllowMCP(server, tool string)`, `AllowShell(cmd string)`.
  - `type CallScope struct { Values []string }` — one scope unit a call touches; it is covered when **any** of `Values` matches the entry's scope (case-insensitive equality or `path.Match` glob); `Values[0]` is the canonical form used in `PermissionDenied.Needed`. `type ToolCapability struct { Capability, Verb, ScopeArg string; ScopeOf func(ctx context.Context, d *db.DB, args json.RawMessage) ([]CallScope, error) }` (S1) — `ScopeOf == nil` reads `args[ScopeArg]` verbatim (one unit); a scoped tool returning no unit has an **absent** scope (only `@*` or `tool:<name>` admits it); a call is admitted by a capability entry only when **every** unit is covered (`needed` = the first uncovered unit). `var ToolCapabilities map[string]ToolCapability` — the real argument names of each tool:
    - Jira reads: `list_jira_issues → jira read`, `project`; `get_jira_issue → jira read`, the project prefix of `key` (`ABC-123` → `ABC`; a key without `-` → absent); `get_jira_status_history → jira read`, one unit per entry of `keys` (its prefix); `get_jira_time_in_status → jira read`, `project` when given, else one unit per `issue_keys` prefix, else absent (`board_id` alone → absent); `list_jira_projects → jira read`, absent; `list_jira_sprints → jira read` (ask #277), upper(`project`) when given, else the `jira_boards.project_key` of `board_id` (unknown board or empty key → absent), else absent; `list_jira_releases → jira read` (ask #277), upper(`project`), else absent.
    - Account-scoped reads: `list_emails`/`get_email → gmail read`, `account` resolved to one unit `{label, address}` of the Google or IMAP account (unknown account → absent; the tool itself then refuses it); `list_calendar_events → calendar read` (ask #277), `account` resolved to one unit `{label, address}` of a Google account or `{label}` of a `calendar_accounts` row (unknown → absent; the tool refuses it), no `account` → absent (only `calendar:read@*`); `list_messages → slack read`, **always absent**; `list_upcoming_events → calendar read`, **always absent** (both tools read every connected workspace/calendar and take no account argument — the `list_messages` ruling below).
    - Local reads, no scope: `list_targets/get_target → targets read`, `list_tracks/get_track/get_track_counts → tracks read`, `list_ideas/get_idea → ideas read`, `list_digests/get_digest/get_today_briefing → digests read`, `list_people/get_person/find_experts → people read`, `list_transcripts/get_transcript → transcripts read`; (ask #277) `list_meeting_recaps/get_meeting_recap/list_meeting_notes → meetings read`, `list_day_plans/get_day_plan → dayplan read`, `list_reminders → targets read` (mirrors `remind_me → targets write`).
    - **Broad knowledge tools — `tool:` only (spec §3.1, §20.1 D21, ask #273):** `search_knowledge`, `get_knowledge_document` and `get_task_context` have **no** `ToolCapabilities` entry (their results can carry content of any synced source whatever the account scopes); only `tool:<name>` admits each, and the denial's `needed` is `tool:<name>`. There is no `knowledge` capability: `ParseManifest` refuses `knowledge:read`/`knowledge:write` with "there is no knowledge capability; list the tools: tool:search_knowledge, tool:get_knowledge_document, tool:get_task_context".
    - **Other `tool:`-only reads (ask #277, spec §3.1, §20.1 D23):** `list_inbox`, `memory_recall`, `memory_open`, `memory_map` (cross-source, D21's rule), `get_writing_style` (single-purpose) have no `ToolCapabilities` entry; `needed` is `tool:<name>`. No `inbox` or `memory` capability exists (an `inbox:read`/`memory:read` entry is a parse error as an unknown capability).
    - Write tools of §6.1 (consumed by P2; listed now so P2 adds no entry): `create_target`/`remind_me → targets write`, `create_idea → ideas write`, `create_track → tracks write` (no scope); `create_jira_issue → jira write`, upper(`project_key`); `add_jira_comment/transition_jira_issue/assign_jira_issue/update_jira_issue → jira write`, the project prefix of `key`; `send_slack_message → slack write`, `account_id` resolved to one unit `{label, team_domain}` of `slack_accounts`; with no `account_id`, the unit of the only enabled Slack account when exactly one exists, else absent.
    - **`list_messages` ruling (settles the account-scope gap; owner-confirmed in ask #273, spec §20.1 D22):** `list_messages` has no account argument and a raw id or a channel/person name matches in every connected workspace, so no per-account entry can bound what it returns. Its scope is always absent: only `slack:read@*` or `tool:list_messages` admits it, and `slack:read@<label>` never does (the denial's `needed` is `slack:read@*`). The same rule applies to `list_upcoming_events` (`calendar:read@*`). A per-account `list_messages` would need an `account` argument on the shared tool — the owner kept v1 at `slack:read@*` only (ask #273; feature note, v1 limits).
  - `func ClampListLimit(t *tools.Tool, args json.RawMessage) json.RawMessage` (S9, exported) — for a tool whose input schema has a `limit` property: absent/0 → `DefaultListLimit` (50), above `MaxListLimit` (200) → 200; other tools' args returned unchanged. The single implementation: P1's `tool()`, P6's `agent()` gates and the `--surface automation` MCP server all call it.
  - `func Covers(old, new []string) []string` — entries of `new` not covered by `old`.
- Depends on: Task 3.

- [ ] **Step 1: Failing tests** in `manifest_test.go`:
  - `TestManifest_GrammarTable` — valid: `gmail:read@work`, `jira:read@PAY`, `jira:read@*`, `tool:create_target`, `tool:search_knowledge`, `mcp:github/list_*`, `shell:"make release"`, `shell:"echo \"hi\""`, `llm:strong`, `agent:run`, `ask:owner`, `session:start`, `session:start@codex`, `targets:read`, `meetings:read`, `dayplan:read`; invalid: `gmail:read` (no scope), `targets:read@x`, `knowledge:read`, `knowledge:write`, `meetings:write`, `dayplan:read@x`, `inbox:read`, `memory:read`, `llm:medium`, `jira:delete@PAY`, `shell:make release` (unquoted), `shell:"unterminated`, `mcp:github`, `mcp:*/x`, `foo:read`, `tool:`, empty.
  - `TestManifest_PersonalRefusesShellSessionAsk` (D7) — each in personal → error; in workbench:1 → ok.
  - `TestManifest_ScopeMatching` — `jira:read@PAY` admits `list_jira_issues{project:"pay"}` (case-insensitive), denies `{project:"OPS"}`, denies `{}` (absent scope needs `@*`); `jira:read@*` admits all three; `jira:read@P*` admits `PAY`.
  - `TestManifest_ToolPermissionAdmitsWithoutCapability` — `tool:list_jira_issues` admits `{project:"OPS"}`.
  - `TestManifest_JiraScopeFromRealArgs` (S1) — `jira:read@PAY` admits `get_jira_issue{key:"PAY-1"}`, denies `{key:"OPS-1"}` (`needed` `jira:read@OPS`); `get_jira_status_history{keys:["PAY-1","OPS-2"]}` → denied, `needed` `jira:read@OPS`; `get_jira_time_in_status{issue_keys:["PAY-3"]}` admitted, `{board_id:4}` → needs `jira:read@*`; `jira:write@PAY` (fake tools of those names with `Surfaces: ["automation"]`) admits `create_jira_issue{project_key:"pay"}` and `add_jira_comment{key:"PAY-7"}`, denies `{project_key:"OPS"}` / `{key:"OPS-1"}` with `needed` `jira:write@OPS`; `{key:"nodash"}` → needs `jira:write@*`.
  - `TestManifest_SlackWriteScopeByAccountLabel` (S1, file DB) — Slack accounts `work` (id 1) and `home` (id 2): `slack:write@work` admits `send_slack_message{account_id:1}`, denies `{account_id:2}` (`needed` `slack:write@home`); no `account_id` with two enabled accounts → only `slack:write@*` admits; with only `work` enabled → `slack:write@work` admits.
  - `TestManifest_ScopeOfErrorIsADeniedNotAPanic` — `account_id` of a missing account → `*PermissionDenied` naming `slack:write@*`.
  - `TestManifest_EmailScopeMatchesLabelOrAddress` — Google account label `work`, address `owner@example.com`: `gmail:read@work` and `gmail:read@owner@example.com` each admit `list_emails{account:"owner@example.com"}` and `{account:"work"}`; `gmail:read@home` denies with `needed` `gmail:read@work`.
  - `TestManifest_UnscopedSourceReadsNeedStar` (the `list_messages` ruling) — `slack:read@work` denies `list_messages{channel:"releases"}` with `needed` `slack:read@*`; `slack:read@*` and `tool:list_messages` admit it; `calendar:read@work` denies `list_upcoming_events{}`, `calendar:read@*` admits.
  - `TestManifest_D23ToolScopes` (ask #277, file DB) — Google account `work` (calendar enabled), CalDAV account `team`: `calendar:read@work` admits `list_calendar_events{account:"work"}` and `{account:"owner@example.com"}`, denies `{account:"team"}` (`needed` `calendar:read@team`) and `{}` (`needed` `calendar:read@*`); board 7 with `project_key` `PAY`: `jira:read@PAY` admits `list_jira_sprints{board_id:7}`, `{project:"pay"}`, `list_jira_releases{project:"PAY"}`, denies `list_jira_sprints{}` and `list_jira_releases{}` (`needed` `jira:read@*`), and a board with empty `project_key` (`needed` `jira:read@*`); `meetings:read` admits the three meeting tools, `dayplan:read` the two day-plan tools, `targets:read` `list_reminders`; every capability present denies `list_inbox`, `memory_recall`, `memory_open`, `memory_map`, `get_writing_style` with `needed` `tool:<name>`, and each `tool:<name>` admits only its tool (fake tools of those names with `Surfaces: ["automation"]`).
  - `TestManifest_MeetingsAndDayplanReadOnly` (ask #277) — `meetings:write`, `dayplan:write` → parse errors; `Covers([meetings:read],[dayplan:read])` = `[dayplan:read]`.
  - `TestManifest_KnowledgeToolsOnlyByToolEntry` (ask #273) — `targets:read` + `people:read` (every other capability present too) deny `search_knowledge`, `get_knowledge_document`, `get_task_context` with `needed` `tool:<name>`; `tool:search_knowledge` admits only `search_knowledge`; `knowledge:read` is a parse error whose message names the three `tool:` entries; `ToolCapabilities` has no entry for the three.
  - `TestClampListLimit` — a schema with `limit`: absent → 50, 0 → 50, 1000 → 200, 30 → 30; a schema without `limit` → args byte-identical.
  - `TestManifest_ToolNotOnAutomationSurfaceDenied` — `get_confluence_page` with `tool:get_confluence_page` → denied.
  - `TestManifest_LLMStrongImpliesLight`, `TestManifest_OutputGate`.
  - `TestManifest_MCPGlob` — `mcp:github/list_*` admits `github/list_prs`, denies `github/create_pr`, `gitlab/list_prs`.
  - `TestManifest_ShellExactOnly` — `shell:"make release"` admits `make release` only; denies `make release `, ` make release`, `make  release`, `make release && rm -rf x`, `make`, `make releases`.
  - `TestManifest_CoversWidening` — `Covers([jira:read@PAY],[jira:read@*])` = `[jira:read@*]`; `Covers([jira:read@*],[jira:read@PAY])` = `[]`; `Covers([llm:strong],[llm:light])` = `[]`; `Covers([llm:light],[llm:strong])` = `[llm:strong]`; shell entries compare byte-exact.
  - `TestToolCapabilities_CoversEveryAutomationTool` — for every tool in `buildToolRegistry`-equivalent list visible on `automation` (P1: read tools + `list_emails`/`get_email`), there is a `ToolCapabilities` entry or it is in the explicit `toolOnlyTools` allowlist in the test (which holds exactly `search_knowledge`, `get_knowledge_document`, `get_task_context` — D21 — and, once Task 5b registers them, `list_inbox`, `memory_recall`, `memory_open`, `memory_map`, `get_writing_style` — D23; Task 5b extends the list and runs the test over `buildAutomationRegistry`).
  - `TestManifest_NormalizedIsSortedAndDeduped`.
- [ ] **Step 2:** `go test ./internal/automations -run 'TestManifest|TestToolCapabilities|TestClampListLimit'` → FAIL.
- [ ] **Step 3:** Implement; wire into `ParseRecipe`/`ApprovalHash`.
- [ ] **Step 4:** `go test ./internal/automations` → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): permission manifest grammar and matching`.

### Task 5a: Email read tools and the automation surface constants

**Files:**
- Create: `internal/tools/emails.go`, `internal/tools/emails_test.go`
- Modify: `internal/tools/registry.go` (constants), `cmd/actions_registry.go` (register both tools), the `TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces` pin, `internal/db` read helpers if none fit (`ListLocalEmails`, `GetLocalEmail` in `internal/db/emails_read.go`)

**Interfaces:**
- Consumes: `gmail_messages`, `imap_messages`, `google_accounts`, `email_accounts`.
- Produces:
  - `const AutomationSurface = "automation"`, `const AutomationContextType = "automation_run"` in `internal/tools`.
  - `func NewListEmails() *Tool` — `Access: AccessRead`, `Surfaces: []string{AutomationSurface}`; args `{account (label or address, required), since? (RFC 3339), limit? (default 50, max 200), unread_only? bool}`; result `{account, messages: [{id, thread_id, from, subject, snippet, date, unread, permalink}]}` newest first, local store only.
  - `func NewGetEmail() *Tool` — args `{account, id}`; result adds `to, cc, body` (body clipped 32 KiB, `truncated: true`).
  - Neither tool is added to `tools.ReadTools()` (dev-mode MCP never mounts them).
- Depends on: none.

- [ ] **Step 1: Failing tests** in `emails_test.go` (seed one Google account label `work`, address `owner@example.com`, and one IMAP account label `home`):
  - `TestListEmails_ReadsLocalStoreOnly` — results from seeded rows; the tool has no client factory (constructor takes none) — pinned by its signature.
  - `TestListEmails_AccountByLabelOrAddress` — `work` and `owner@example.com` both resolve; unknown account → `*ValidationError` "unknown account".
  - `TestListEmails_IMAPAccount` — `home` lists `imap_messages`.
  - `TestListEmails_SinceLimitUnreadOnly` — limit 0 → 50, 500 → 200; `since` filters; `unread_only`.
  - `TestGetEmail_ClipsBodyAt32KiB` — 40 KiB body → 32 KiB + `truncated: true`.
  - `TestEmailTools_NotOnDevSurface` — not in `ReadTools()`; `VisibleOn("main")` false; `VisibleOn("automation")` true.
  - Update the registry pin test to include both tools with their surface.
- [ ] **Step 2:** `go test ./internal/tools -run 'TestListEmails|TestGetEmail|TestEmailTools'` and `go test ./cmd -run TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 commands → PASS; `go test ./internal/tools` → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): local-store email read tools for the automation surface`.

### Task 5b: More local-store reads and the automation registry (ask #277, spec §6.1, §20.1 D23)

**Files:**
- Create: `internal/tools/automation_reads.go`, `internal/tools/automation_reads_test.go`, `cmd/automations_registry.go`, `cmd/automations_registry_test.go`; `internal/db/automation_reads.go` (+ test) only for helpers no existing one fits (`ListCalendarEventsRange`, `ListMeetingRecaps`, `GetMeetingRecapByID`, `ListMeetingNotes`, `ListReminders`, `ListJiraSprints`, `ListJiraReleases` — reuse `GetInboxItems`, `GetMeetingRecap`, `GetMeetingNotesForEvent`, `ListDayPlans`, `GetDayPlan`, `GetDayPlanItems` where they fit)
- Modify: `internal/tools/memory.go` (`memory_open` skips `BumpMemoryAccess` when `call.Binding.Surface == AutomationSurface`), `internal/tools/style.go` (`get_writing_style` `Surfaces` gains `AutomationSurface`), `cmd/actions_registry.go` (register the ten new tools in `buildToolRegistry`), the `TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces` pin, `internal/automations/manifest_test.go` (`TestToolCapabilities_CoversEveryAutomationTool` runs over `buildAutomationRegistry`'s list, `toolOnlyTools` extended)

**Interfaces:**
- Consumes: Task 5a's `AutomationSurface`; Task 4's `ToolCapabilities` (the D23 entries are already there); `db.ResolveOwner` (OWNER-01) for the day plan's user; `tools.DependentReadTools`, `memoryVaultPath(cfg)` (existing in `cmd`); `inbox_items`, `calendar_events`/`calendar_calendars`/`google_accounts`/`calendar_accounts`, `meeting_recaps`, `meeting_notes`, `day_plans`, `day_plan_items`, `reminders`, `jira_sprints`, `jira_boards`, `jira_releases`.
- Produces — every new tool `Access: AccessRead`, `Surfaces: []string{AutomationSurface}`, local store only (constructors take no client factory), **not** in `tools.ReadTools()`; `limit` default 50, max 200 (the schema has `limit`, so P1's `ClampListLimit` applies); arrays `[]`, never `null`:
  - `func NewListInbox() *Tool` — args `{status?: "pending"|"snoozed"|"resolved"|"dismissed"|"all" (default "pending"), priority?: "high"|"medium"|"low", trigger_type?, since? (RFC 3339, on created_at), limit?}`; archived rows excluded; newest first; result `{items: [{id, trigger_type, item_class, status, priority, snippet, why_matters, permalink, channel_id, sender_user_id, snooze_until, target_id, read_at, created_at, updated_at}]}` (`raw_text`, `context`, `thread_digest`, `draft_reply` are not returned).
  - `func NewListCalendarEvents() *Tool` — args `{from (RFC 3339, required), to (RFC 3339, required, > from), account?, limit?}`; events with `start_time` in `[from, to)`, past included, cancelled included with their status, ordered by start; `account` = a Google account label/address or a `calendar_accounts` label (unknown → `*ValidationError` "unknown account"); result `{events: [{id, calendar_id, calendar, account, title, start, end, all_day, location, organizer, attendees, status, html_link, conference_url, description, description_truncated}]}` with `description` clipped 4 KiB.
  - `func NewListMeetingRecaps() *Tool` — args `{since?, until? (RFC 3339, on the event start, else the recap's created_at), limit?}`; result `{recaps: [{id, event_id, event_title, event_start, transcript_id, created_at, updated_at}]}` newest first.
  - `func NewGetMeetingRecap() *Tool` — args `{id?} | {event_id?}` (exactly one); result adds `recap` (the parsed `recap_json`; above 32 KiB serialised it is returned as clipped text with `recap_truncated: true`) and `source_text` clipped 32 KiB with `source_truncated`.
  - `func NewListMeetingNotes() *Tool` — args `{event_id?, since?, limit?}` (at least one of `event_id`, `since`); result `{notes: [{id, event_id, type, text, is_checked, sort_order, task_id, created_at, updated_at}]}` — `text` whole (a note is one short row; no `get_meeting_note`).
  - `func NewListDayPlans() *Tool` — args `{since? (YYYY-MM-DD), limit?}`; the owner's plans (`db.ResolveOwner`; an unresolved owner → the OWNER-02 error, never an empty list); result `{plans: [{id, plan_date, status, has_conflicts, conflict_summary, generated_at, item_count, done_count}]}`.
  - `func NewGetDayPlan() *Tool` — args `{date? (YYYY-MM-DD, default today in the local zone) | id?}`; result the plan plus `items: [{id, kind, source_type, source_id, title, description, rationale, start_time, end_time, duration_min, priority, status, order_index, tags}]`; no plan for that date → `{plan: null, items: []}`.
  - `func NewListReminders() *Tool` — args `{status?: "pending"|"done"|"dismissed"|"all" (default "pending"), due_before? (RFC 3339), limit?}`; result `{reminders: [{id, account_id, message_ref, note, remind_at, status, created_at, done_at}]}` soonest first.
  - `func NewListJiraSprints() *Tool` — args `{project?, board_id?, state?: "active"|"future"|"closed", limit?}`; joined to `jira_boards` (a `project` keeps sprints of its boards); result `{sprints: [{account_id, id, board_id, board_name, project_key, name, state, goal, start_date, end_date, complete_date}]}`.
  - `func NewListJiraReleases() *Tool` — args `{project?, released?: bool, include_archived?: bool (default false), limit?}`; result `{releases: [{account_id, id, project_key, name, description, description_truncated, release_date, released, archived}]}` with `description` clipped 4 KiB.
  - Existing tools: `memory_open` — on the `automation` surface no access-stat bump (AUTO-02/AUTO-12: automation reads write nothing); its result is unchanged. `get_writing_style` — `Surfaces` + `AutomationSurface` (its other surfaces unchanged). `get_confluence_page` is **not** touched: a live network read stays off the `automation` surface (D23 is local store only). `memory_recall`, `memory_map`, `list_jira_projects` — unchanged (surface-less).
  - `cmd`: `func buildAutomationRegistry(cfg *config.Config, database *db.DB) *tools.Registry` — `buildToolRegistry(cfg, database)` plus `memory_map`, `memory_open`, `memory_recall` from `tools.DependentReadTools(tools.ReadDeps{MemoryVaultPath: memoryVaultPath(cfg)})` (no `RetrieveShadowDB`, so recall writes no shadow row; `load_skill` not added). It is the registry every automation path uses: the daemon's executor (Task 11), the CLI's `dry-run` (Task 12), P3's `draft_automation` backends, P6's runtime-B `agent()`. `buildToolRegistry` itself does not gain the memory tools (the chat MCP server registers them from `DependentReadTools`; doing both would register them twice).
- Depends on: Tasks 4, 5a.

- [ ] **Step 1: Failing tests** (`automation_reads_test.go`, temp file DB seeded with `acme`/`example.com` fixtures; times seeded from `time.Now()`):
  - `TestListInbox_DefaultsToPendingNotArchived` — pending, snoozed, resolved and an archived pending row → only the pending one; `status:"all"` → all but the archived; `priority`, `trigger_type`, `since` filter; limit 0 → 50, 500 → 200; the four large text columns absent from the JSON.
  - `TestListCalendarEvents_RangeIncludesPast` — events yesterday, today, next week; `[yesterday, tomorrow)` → the first two in start order; `to <= from` → `*ValidationError`.
  - `TestListCalendarEvents_AccountFilter` — Google account `work` and CalDAV account `team`: `account:"work"` lists only `work`'s calendars, `"owner@example.com"` the same, `"team"` only `caldav:` calendars; unknown → "unknown account"; description 10 KiB → 4 KiB + `description_truncated: true`.
  - `TestMeetingRecapTools_ListAndGet` — list newest first with event title/start; `get` by `id` and by `event_id` equal; both → `*ValidationError`; `source_text` 40 KiB → 32 KiB + `source_truncated`; a 40 KiB `recap_json` → clipped text + `recap_truncated`.
  - `TestMeetingRecapTools_NotesOfOneEvent` — `list_meeting_notes{event_id}` returns its notes in `sort_order`; neither `event_id` nor `since` → `*ValidationError`.
  - `TestDayPlanTools_OwnerPlanAndItems` — owner resolved: `list_day_plans` counts items/done; `get_day_plan{}` returns today's plan with items in `order_index`; a date with no plan → `{plan: null, items: []}`; owner unresolved → the OWNER-02 error.
  - `TestListReminders_StatusAndDue` — default pending soonest first; `due_before` filters; `status:"all"`.
  - `TestJiraSprintReleaseTools_ProjectAndBoard` — board 7 `PAY`, board 8 `OPS`: `list_jira_sprints{project:"pay"}` → board 7's sprints with `project_key` `PAY`; `{board_id:8}` → board 8's; `state` filters; `list_jira_releases{project:"PAY"}` excludes archived unless `include_archived`; `released:false` filters; description clipped 4 KiB.
  - `TestD23Tools_AutomationSurfaceOnly` — each of the ten: not in `ReadTools()`, `VisibleOn("automation")` true, `VisibleOn("main")` false; `get_writing_style` visible on `main`, `project`, `automation`; `get_confluence_page` still not visible on `automation`.
  - `TestMemoryOpen_NoAccessBumpOnAutomationSurface` — open with a `Binding{Surface: "automation"}` → node returned, `access_count` unchanged; the same open with `Binding{Surface: "main"}` → bumped (existing behaviour kept).
  - `TestBuildAutomationRegistry_AddsMemoryTools` (`cmd`) — the three memory tools present, `load_skill` absent, `buildToolRegistry` unchanged (no memory tools); `memory_recall` on this registry writes no `memory_retrieve_shadow` row.
  - Update `TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces` — the ten tools with `["automation"]`, `get_writing_style` with its new surface list (`get_confluence_page` unchanged); `TestToolCapabilities_CoversEveryAutomationTool` over `buildAutomationRegistry`, `toolOnlyTools` = the D21 three + `list_inbox`, `memory_recall`, `memory_open`, `memory_map`, `get_writing_style`.
- [ ] **Step 2:** `go test ./internal/tools -run 'TestListInbox|TestListCalendarEvents|TestMeetingRecapTools|TestDayPlanTools|TestListReminders|TestJiraSprintReleaseTools|TestD23Tools|TestMemoryOpen_NoAccessBump'`, `go test ./internal/automations -run TestToolCapabilities`, `go test ./cmd -run 'TestBuildAutomationRegistry|TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces'` → FAIL.
- [ ] **Step 3:** Implement (existing memory tests stay green unmodified).
- [ ] **Step 4:** Step 2 commands → PASS; `go test ./internal/tools ./internal/db` → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): more local-store reads for the automation surface (ask #277)`.

### Task 6: goja sandbox and the SDK registration seam

**Files:**
- Create: `internal/automations/sandbox.go`, `internal/automations/errors.go`, `internal/automations/journal.go`, `internal/automations/meter.go`, `internal/automations/commit.go`, `internal/automations/sandbox_test.go`
- Modify: `go.mod`/`go.sum` (`github.com/dop251/goja`, a tagged/pseudo version at least two weeks old, pinned)

**Interfaces:**
- Consumes: `Recipe`, `Manifest` (Tasks 3–4); `db.AutomationRun`, `db.AppendAutomationRunStep`, `db.MarkAutomationRunStep`, `db.FinishAutomationRunStep`, `db.AddAutomationRunUsage` (Task 2); `tools.Binding`, `tools.AutomationSurface`, `tools.AutomationContextType`.
- Produces:
  - Error names (constants, the JS `Error.name` values): `ErrNamePermissionDenied="PermissionDenied"`, `ErrNameResultTooLarge`, `ErrNameStateTooLarge`, `ErrNameValidation="ValidationError"`, `ErrNameTool="ToolError"`, `ErrNameBudget="BudgetExceeded"`, `ErrNameNotAvailable="NotAvailable"`; `type SDKError struct { Name, Message, Needed string }` (`error`).
  - Interrupt reasons: `type InterruptReason string` — `InterruptTimeout`, `InterruptBudget`, `InterruptDailyCap`, `InterruptCancel`.
  - **Journal:** `type Journal struct{…}`; `func NewJournal(d *db.DB, runID int64, dryRun bool) *Journal`; `func NewMemoryJournal() *Journal` (same type, no DB: rows live only in memory, ids are the step's `seq` — P3's `draft_automation` dry run, which must write nothing); `func (j *Journal) Begin(kind, name string, args any) *Step` (writes the row at start, `args_json` clipped 4 KiB); `func (s *Step) ID() int64` (the row id; the `seq` for a memory journal); `func (s *Step) Mark(status string, link db.StepFinish) error` (S4 — the one non-final update: sets `status` and, from `link`, only the non-zero `ActionID`/`AskID`/`SessionID`; `finished_at` stays NULL; P2's `{wait:true}` passes `{ActionID}`, P5's `ask()` `{AskID}`, P5's `session()` a zero link); `func (s *Step) OK(result any)`, `func (s *Step) Fail(err error)`, `func (s *Step) Denied(needed string)`, `func (s *Step) Finish(f db.StepFinish)` (generic: P2 uses status `proposed/applied/rejected/failed` + `ActionID` + `Auto`, P5 `AskID`/`SessionID`), `func (s *Step) Usage(in, out int64, estimated bool, reportedUSD *float64)`; `func (j *Journal) Count() int`; `func (j *Journal) Steps() []db.AutomationRunStep` (the steps this journal recorded, in `seq` order, as they stand now — both kinds keep the copy).
  - **Meter:** `type Meter struct{…}`; `func NewMeter(budget Budget, dailyRemaining int64, clock Clock) *Meter`; `func (m *Meter) BeforeCall() error` (`*SDKError{Name: BudgetExceeded}` when run remainder ≤ 0; `InterruptDailyCap`-flagged error when the daily remainder ≤ 0); `func (m *Meter) Debit(in, out int64) (crossed InterruptReason)`; `func (m *Meter) PauseActive()` / `ResumeActive()` (seam for P2/P5 waits — active-time deadline re-armed); `func (m *Meter) Deadline() time.Time`; `func (m *Meter) Remaining() Budget` (for P6 `agent()` carving).
  - **Commit buffer:** `type CommitBuffer struct{…}`; `func NewCommitBuffer(committedState json.RawMessage) *CommitBuffer`; `Get(key string) (any, bool)`, `Set(key string, v any) error` (`ValidationError` on unserialisable, `StateTooLarge` > 64 KiB), `All() map[string]any`, `AddOutput(o db.AutomationOutput) error` (`ResultTooLarge` body > 64 KiB), `Commit() *db.RunCommit` (nil state when untouched).
  - **SDK registration seam:** `type Env struct { Ctx context.Context; Run *db.AutomationRun; Automation *db.Automation; Recipe *Recipe; Manifest *Manifest; DryRun bool; Journal *Journal; Meter *Meter; Buffer *CommitBuffer; Wait Waiter }`; `func (e *Env) Binding() tools.Binding` (P1: `{Surface: AutomationSurface, ContextType: AutomationContextType, ContextID: strconv(run id), WorkbenchID: project id}`; P2 adds `AutomationRunID`); `type Waiter interface { Wait(ctx context.Context, reason string, ready func(context.Context) (bool, error)) error }` (sets the run `waiting`, pauses the meter, polls `ready` every `PollInterval` or on wake, resumes); `type SDKFunc func(env *Env, call goja.FunctionCall, rt *goja.Runtime) (any, error)`; `type Module interface { Name() string; Install(def Definer) }`; `type Definer interface { Define(path string, fn SDKFunc) }` (dotted paths: `llm`, `state.get`, `output.inbox`) — **a later module's `Define` of an already defined path replaces the earlier one** (S3, last wins in `DefaultModules` order; P2's `ToolWriteModule` replaces `tool` this way and delegates reads to P1's read function).
  - **Sandbox:** `type Sandbox struct{…}`; `func NewSandbox(env *Env, modules []Module) (*Sandbox, error)` (fresh `goja.Runtime`; installs `trigger` read-only object, modules; no `require`, `console`, timers; result values serialised and size-checked at the SDK boundary; Go errors → JS `Error` with `name`); `func PreParse(script string) error` (refuses `async`, `await`, `Promise`, `setTimeout`, `setInterval` with "the script API is synchronous"); `func (s *Sandbox) Run() (returned any, err error)`; `func (s *Sandbox) Interrupt(reason InterruptReason)`; `type ScriptError struct { Message, Stack string; Line int /*recipe file line*/ }`.
  - `type TriggerInfo struct { Kind string; RunID int64; ScheduledFor *time.Time; CatchUp bool; Button string; Events []map[string]any; Truncated bool; DryRun bool }` (exposed as `trigger`; S5: `trigger.events` is the decoded `event_json.events` of a `trigger='event'` run and `undefined` for every other trigger, `trigger.truncated` is `event_json.truncated` and `false` otherwise — filled by the executor, Task 10).
- Depends on: Tasks 2, 3, 4.

- [ ] **Step 1: Failing tests** in `sandbox_test.go` (a test module defining `echo`, `big`, `boom`):
  - `TestAuto07_NoRequireFsNetTimers` — `typeof require`, `typeof console`, `typeof setTimeout`, `typeof fetch`, `typeof XMLHttpRequest` all `"undefined"`.
  - `TestRecipe_AsyncScriptRefused` / `TestSandbox_PreParseRefusesAsync` — `async function f(){}`, `await x`, `new Promise(…)`, `setTimeout(f,1)` → error "the script API is synchronous".
  - `TestAuto08_InterruptOnTimeout` — `while(true){}` with `Meter` deadline 1 s (fake clock driving a real timer of 1 s is fine) → returns within 2 s with `InterruptTimeout`.
  - `TestSandbox_InterruptIsNotCatchable` — `while(true){try{echo(1)}catch(e){}}` + `Interrupt(InterruptBudget)` → run stops with `InterruptBudget` (Review Focus 2).
  - `TestSandbox_ResultTooLargeIsAnErrorNotATruncation` — `big()` returning 257 KiB → JS error `name === "ResultTooLarge"`, step `error`.
  - `TestSandbox_SDKErrorHasName` — `boom()` returning `SDKError{Name:"ToolError"}` → `e.name === "ToolError"` catchable.
  - `TestSandbox_ErrorLineMapsToFile` — script throwing on its 3rd line with `ScriptLine` 12 → `ScriptError.Line == 14`.
  - `TestSandbox_TriggerIsReadOnly` — `trigger.kind = "x"` has no effect (strict mode assignment throws).
  - `TestSandbox_TriggerEventsAreReadOnly` — `TriggerInfo{Events: [{…}], Truncated: true}`: `trigger.events.push(1)` throws in strict mode or leaves the array unchanged; `trigger.truncated === true`; with `Events: nil` → `typeof trigger.events === "undefined"`, `trigger.truncated === false`.
  - `TestDefiner_LaterModuleReplacesPath` (S3) — module A defines `echo` returning 1, module B (installed after A) defines `echo` returning 2 → the script sees 2; a path defined once is unaffected.
  - `TestJournal_MarkIsNonFinalAndKeepsLink` — `Begin` → `Mark("waiting", db.StepFinish{ActionID: 7})` → row `waiting`, `action_id` 7, `finished_at` NULL; `OK(…)` afterwards closes it; `ID()` equals the row id.
  - `TestMemoryJournal_WritesNoRows` — `NewMemoryJournal()`: `Begin`/`Mark`/`OK`/`Denied` → `Steps()` holds them in order with statuses and clipped args, `ID()` = seq; `automation_run_steps` row count unchanged (no DB is even opened).
  - `TestMeter_ActiveTimeExcludesPause` — fake clock: 2 min active, pause 1 h, resume → deadline = start + minutes + 1 h.
  - `TestMeter_BeforeCallRefusesWhenSpent`; `TestMeter_DailyRemainderInterrupts`.
  - `TestCommitBuffer_StateTooLarge`; `TestCommitBuffer_UntouchedStateCommitsNil`.
  - `TestJournal_ClipsArgsAndResult` — 10 KiB args → 4 KiB stored.
- [ ] **Step 2:** `go test ./internal/automations -run 'TestAuto07|TestAuto08_InterruptOnTimeout|TestSandbox|TestMeter|TestCommitBuffer|TestJournal|TestMemoryJournal|TestDefiner|TestRecipe_AsyncScriptRefused'` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 command → PASS; `go test ./internal/automations` → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): goja sandbox, journal, meter and the SDK seam`.

### Task 7: P1 SDK modules — llm, tool (read), state, output, log

**Files:**
- Create: `internal/automations/backends.go`, `sdk_llm.go`, `sdk_tool.go`, `sdk_state.go`, `sdk_output.go`, `sdk_log.go`, `modules.go`, `sdk_test.go`; `internal/automations/automationstest/{fakes.go,clock.go,seed.go}`
- Modify: `internal/digest/models.go` (`automation.llm` light), `internal/digest/tier_scan_test.go` (`automation.llm.strong` allowlist entry with reason)

**Interfaces:**
- Consumes: Task 6 seam; `digest.Generator`, `digest.WithSource`, `digest.Usage`; Task 4 checks.
- Produces:
  - `type ToolRegistry interface { Get(name string) (*tools.Tool, bool); CallRead(ctx context.Context, name string, args json.RawMessage, b tools.Binding) (any, error); Propose(ctx context.Context, name string, args json.RawMessage, b tools.Binding) (tools.Receipt, error) }` (P1 calls only `Get`/`CallRead`; `*tools.Registry` satisfies it).
  - `backends.go`: `type Backends struct { DB *db.DB; Generator digest.Generator; Registry ToolRegistry; Clock Clock; Shell ShellRunner; Workbench WorkbenchResolver }` — `DB` is used for read-only lookups only (`AllowTool`'s account labels); `Shell` and `Workbench` are **nil until P5** wires them (a module that needs a nil backend throws `NotAvailable`); P6 appends `MCP MCPCaller` and `Agent AgentRunner` the same way (new fields, never a rename). The interfaces P5 implements are declared here so no later phase changes `Backends`' existing fields:
    - `type ShellCommand struct { Cmd, Dir string; Env []string; Deadline time.Time }`; `type ShellResult struct { ExitCode int; Stdout, Stderr string; StdoutTruncated, StderrTruncated bool }`; `type ShellRunner interface { Run(ctx context.Context, c ShellCommand) (ShellResult, error) }`.
    - `type WorkbenchInfo struct { ID int64; Folder string; Protected bool; DefaultAgent string /* "claude"|"codex" */ }`; `type WorkbenchResolver interface { Workbench(ctx context.Context, id int64) (WorkbenchInfo, error) }`.
  - `const SourceLLMLight = "automation.llm"`, `SourceLLMStrong = "automation.llm.strong"`.
  - Modules: `func LLMModule(b Backends) Module`, `func ToolModule(b Backends) Module` (its read path calls the exported `ClampListLimit`, Task 4), `func StateModule() Module`, `func OutputModule() *OutputMod` (S2: `*OutputMod` implements `Module`; `func (m *OutputMod) RegisterOutputKind(kind string, fn SDKFunc)` defines `output.<kind>`; P1 registers `inbox` and `report` itself), `func LogModule() Module`; `func DefaultModules(b Backends) []Module` returns them in that order — **P2–P6 append their modules to this slice in `DefaultModules`**, and register further output kinds there on the `*OutputMod` with closures over `b` (`out.RegisterOutputKind("briefing", …)`, P2), since `SDKFunc`'s `Env` carries no backends.
  - Behaviour pinned by spec §5: `llm(prompt, {input, schema, tier})` — permission `llm:<tier>` (default light); input serialised ≤ 200 KiB; with `schema` one retry then `ValidationError`; tokens debited; `reported_cost_usd` from `Usage` when the generator reports one. `tool(name, args)` — read tools only in P1 (a write tool → `NotAvailable` "writes arrive in a later phase" — P2 replaces this branch); `limit` injected (50) / clamped (200) for tools whose schema has a `limit` property; registry `ValidationError` → JS `ValidationError`; other errors → `ToolError`. `state.get/set/all`. `output.inbox({title, body, priority?})`, `output.report({title, body})` → buffered. `log(...)` → step `kind='log'`, ≤ 200 calls (the 201st throws `ValidationError`).
  - Dry run: `output.*` and `state.set` steps get status `dry_run`; reads and `llm` run for real.
  - `automationstest`: `type FakeClock struct` (`Now`, `Advance(d)`, `After`, `Set(t)`), `type FakeGenerator struct { Replies []string; Usage []digest.Usage; Calls []FakeCall }` (implements `digest.Generator`), `type FakeRegistry struct { Tools map[string]*tools.Tool; ReadResults map[string]any; Proposed []FakeProposal }`, `func SeedAutomation(t *testing.T, d *db.DB, recipeText string, opts SeedOptions) db.Automation` (parses, indexes, confirms, enables).
- Depends on: Task 6.

- [ ] **Step 1: Failing tests** in `sdk_test.go`:
  - `TestLLM_DefaultLightTierAndSourceTag` — FakeGenerator sees ctx source `automation.llm`; `{tier:"strong"}` → `automation.llm.strong`.
  - `TestLLM_StrongNeedsStrongPermission` — manifest `llm:light`, `{tier:"strong"}` → `PermissionDenied`, generator not called.
  - `TestLLM_SchemaRetryOnceThenValidationError` — replies `"nope"`, `"still no"` → 2 calls, `ValidationError`; replies `"x"`, `{"a":1}` → parsed object on 2nd call.
  - `TestLLM_InputTooLarge` — input 201 KiB → `ResultTooLarge`-class error (`ValidationError` "input too large"), no call.
  - `TestLLM_DebitsInputPlusOutputTokens` — usage 100/50 → run usage 150; no usage → estimate `ceil(len/4)`, `tokens_estimated=1`.
  - `TestAuto01_DeniedCallThrowsAndWritesDeniedStep` — `tool("list_jira_issues",{project:"OPS"})` with `jira:read@PAY` → JS catch sees `PermissionDenied`, `e.needed == "jira:read@OPS"`, FakeRegistry records zero calls, step `denied` with `permission`.
  - `TestTool_ReadThroughCallReadWithAutomationBinding` — binding surface `automation`, context `automation_run`/run id.
  - `TestTool_LimitInjectedAndClamped` — no limit → 50; 1000 → 200.
  - `TestTool_WriteNotAvailableInP1` — `create_target` with `tool:create_target` → `NotAvailable`, no `Propose`.
  - `TestState_ReadsCommittedPlusOwnSets`; `TestState_RejectsUnserialisableValues` — function, `undefined`, cyclic object, `NaN`, `Infinity`, BigInt → `ValidationError` (Review Focus 4).
  - `TestOutput_GateAndBodyLimit` — no `outputs:[inbox]` → `PermissionDenied`; 65 KiB body → error.
  - `TestLog_Capped` — 201st `log` throws.
  - `TestOutputMod_RegisterOutputKind` (S2) — a kind registered on the `*OutputMod` before `Install` is callable as `output.<kind>`; an unregistered kind (`output.email`) is `undefined`.
  - `TestBackends_NilShellAndWorkbenchAllowed` — `DefaultModules(Backends{Generator, Registry, Clock})` (no `DB`, `Shell`, `Workbench`) installs and runs a P1 script without panicking.
  - `TestAuto11_EveryCallHasOneStep` — script with 1 llm, 1 read, 1 denied, 1 state.set, 1 output, 1 log → exactly 6 steps, statuses ok/ok/denied/ok/ok/ok.
  - Tier scan: `go test ./internal/digest -run TestTierForSource` stays green with the two tags.
- [ ] **Step 2:** `go test ./internal/automations -run 'TestLLM|TestTool_|TestState|TestOutput|TestLog|TestAuto01|TestAuto11|TestBackends'` → FAIL.
- [ ] **Step 3:** Implement modules, fakes, tier tags.
- [ ] **Step 4:** Step 2 command and `go test ./internal/digest` → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): P1 SDK modules and test fakes`.

### Task 8: Indexer

**Files:**
- Create: `internal/automations/indexer.go`, `internal/automations/indexer_test.go`

**Interfaces:**
- Consumes: `ParseRecipe`, `ContentHash`, `ApprovalHash`, `ValidSlug`; `db.UpsertAutomationIndex`, `db.MarkAutomationsRemovedExcept`, `db.ListAutomations`.
- Produces:
  - `func PersonalDir(workspaceDir string) string` → `<workspaceDir>/automations`.
  - `func WorkbenchDir(folder string) string` → `<folder>/.watchtower/automations` (P5 consumes).
  - `type SkipNote struct { Path, Reason string }`; `type RescanReport struct { Indexed, Unchanged, Removed int; Skipped []SkipNote; NeedConfirmation []int64 }`.
  - `type Indexer struct{…}`; `func NewIndexer(d *db.DB, workspaceDir string, clock Clock) *Indexer`; `func (ix *Indexer) RescanPersonal(ctx context.Context) (RescanReport, error)`; `func (ix *Indexer) RescanFolder(ctx context.Context, scope Scope, dir string) (RescanReport, error)` (P5 calls it with `ScopeWorkbench`); `func (ix *Indexer) Changed(dir string) bool` (directory mtime since last scan — the scheduler's cheap check).
  - Rules: a missing directory = empty (not an error); stems failing `ValidSlug`, non-`.md` files ignored (stems reported as skipped); a parse error is indexed with `parse_error` set (not runnable); a new `schedule` automation gets `last_scheduled_for = now` on first index; files gone → `removed_at`.
- Depends on: Tasks 1, 3, 4.

- [ ] **Step 1: Failing tests:**
  - `TestRescan_MissingDirIsEmpty`.
  - `TestRescan_IndexesNewRecipeUnconfirmedAndDisabled` — `Runnable()` false, `NeedConfirmation` lists it.
  - `TestRescan_UnchangedContentIsNoop` — second rescan `Unchanged=1`, `updated_at` unchanged.
  - `TestRescan_ChangedOutsideWatchtowerNeedsConfirmation` — confirm + enable, rewrite the script on disk, rescan → `approval_hash` changed, not runnable; a description-only edit keeps it runnable.
  - `TestRescan_ParseErrorIndexedNotRunnable`.
  - `TestRescan_BadSlugAndOtherExtensionsSkipped`.
  - `TestRescan_RemovedFileMarked`.
  - `TestRescan_FirstIndexSetsLastScheduledForNow` (fake clock).
- [ ] **Step 2:** `go test ./internal/automations -run TestRescan` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 command → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): recipe folder indexer`.

### Task 9: Scheduler

**Files:**
- Create: `internal/automations/clock.go`, `internal/automations/scheduler.go`, `internal/automations/scheduler_test.go`

**Interfaces:**
- Consumes: Indexer (Task 8); `db.ListAutomations`, `db.EnqueueAutomationRun` (with `AdvanceScheduleTo`), `db.SetAutomationSchedule`.
- Produces:
  - `type Clock interface { Now() time.Time; After(d time.Duration) <-chan time.Time }`; `type RealClock struct{}`.
  - `type Scheduler struct{…}`; `func NewScheduler(d *db.DB, ix *Indexer, clock Clock, wake func()) *Scheduler`; `func (s *Scheduler) Run(ctx context.Context) error` (ticks at each minute boundary); `func (s *Scheduler) Tick(ctx context.Context, now time.Time) error` (the test seam; also rescans the personal folder when `Changed`); `wake` is called after any insert (the executor's wake).
  - Rules (spec §7.2, AUTO-10): due times in `(last_scheduled_for, now]` via `cron.ParseStandard` in `time.Local`; due within `ScheduleGrace` (2 min) of `now` → one `schedule` run with `scheduled_for`; older → missed: `run_once` → one `catch_up` run for the latest missed time, `skip` → none; when the latest due time in the window is on time, only that one `schedule` run is inserted and the older missed ones are folded into it (no extra catch-up); `last_scheduled_for` advances to the latest due time in the same tx; `next_run_at` updated; only runnable automations are considered.
- Depends on: Tasks 2, 8.

- [ ] **Step 1: Failing tests** (FakeClock, `time.Local` set to a fixed zone in the test, e.g. `Europe/Berlin` via `time.LoadLocation`, restored in cleanup):
  - `TestScheduler_OnTimeWithinGrace` — cron `0 9 * * *`, tick at 09:01 → one `schedule` run, `scheduled_for` 09:00.
  - `TestAuto10_SleepAcrossTwoDueTimesRunsOnceCatchUp` — last 08:00 day 1, `0 9,17 * * *`, tick at day 2 08:00 → exactly one `catch_up` run with `scheduled_for` day 1 17:00; `last_scheduled_for` = day 1 17:00.
  - `TestAuto10_SkipPolicyRunsNone` — same with `missed: skip` → no row, `last_scheduled_for` advanced.
  - `TestAuto10_RestartDoesNotRepeatCatchUp` — tick twice at the same `now` (new Scheduler instance) → still one row.
  - `TestScheduler_NewAndReenabledDoNotCatchUp` — first index at 10:00 with `0 9 * * *`, tick at 10:01 → none; disable 2 days, enable, tick → none.
  - `TestScheduler_DSTTransition` — spring-forward day with `30 2 * * *` → no duplicate, no crash; fall-back day → one run.
  - `TestScheduler_UnconfirmedNeverQueued`.
  - `TestScheduler_CoalescesWhileQueued` — tick inserts; next due while the first is still queued → no second row, `last_scheduled_for` advanced.
  - `TestScheduler_ClockBackwardsNoDuplicate` — `now` earlier than `last_scheduled_for` → nothing.
  - `TestAuto09_SchedulerOnlyQueues` — FakeGenerator records zero calls after ticks.
- [ ] **Step 2:** `go test ./internal/automations -run 'TestScheduler|TestAuto10|TestAuto09_Scheduler'` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 command → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): cron scheduler with missed-run policy`.

### Task 10: Executor

**Files:**
- Create: `internal/automations/executor.go`, `internal/automations/executor_test.go`, `internal/automations/dryrun_memory.go`, `internal/automations/dryrun_memory_test.go`

**Interfaces:**
- Consumes: Tasks 2, 6, 7 (sandbox, modules, fakes), config `DailyBudgetTokens`.
- Produces:
  - `type ExecutorOptions struct { MaxConcurrent int /*default MaxConcurrentRuns*/; DailyBudgetTokens int64; Modules func(b Backends) []Module /*default DefaultModules*/; Logger *log.Logger }`.
  - `type Executor struct{…}`; `func NewExecutor(d *db.DB, b Backends, opts ExecutorOptions) *Executor`; `func (e *Executor) Run(ctx context.Context) error` (marks interrupted runs at start, then loops on `PollInterval` or `Wake`); `func (e *Executor) Wake()` (non-blocking); `func (e *Executor) Step(ctx context.Context) (started int, err error)` (one poll: cancel not-runnable, claim up to free slots, start goroutines — the test seam); `func (e *Executor) ExecuteInline(ctx context.Context, runID int64) (*db.AutomationRun, error)` (claims and runs in the caller's goroutine — CLI `dry-run`); `func (e *Executor) Wait()` (waits for in-flight goroutines; tests).
  - `func (e *Executor) Waiter() Waiter` — the `Waiter` P2/P5 use (polls `ready` every `PollInterval`, wakes on `Wake`, honours cancel, `pause_timeout_hours` → `expired`).
  - Run lifecycle (spec §7): claim with snapshot of `recipe_text`/`approval_hash`/budgets; re-parse the snapshot (never the file); daily remaining = `DailyBudgetTokens − AutomationTokensBetween(local day)`; ≤ 0 → finish `budget_exceeded`/`daily_cap` without running; build `TriggerInfo` (S5: for `trigger='event'` decode `event_json` as `db.AutomationEventPayload` into `Events`/`Truncated`; a malformed payload ends the run `failed`/`backend` before the script starts, never a panic) + `Env` + modules + `Sandbox`; arm the deadline timer; every `PollInterval` re-read the run status — `cancelled` by the CLI → `Interrupt(InterruptCancel)`; on return: success → `FinishAutomationRun(succeeded, commit)` (summary = last `output.report` title else `String(returned)` clipped 1 KiB); script error → `failed`/`script`; interrupts → `timed_out`/`timeout`, `budget_exceeded`/`budget`|`daily_cap`, cancel → no-op (already `cancelled`); a `PermissionDenied` the script did not catch → `failed`/`permission`. Dry run (`trigger='dry_run'`): `Env.DryRun = true`, never commits.
  - **In-memory dry run** (P3's `draft_automation`, AGENT-06 — writes nothing, not even a run row): `type DryRunOptions struct { Budget Budget; Modules func(Backends) []Module /* nil = DefaultModules */ }`; `type DryRunReport struct { Steps []db.AutomationRunStep; Outputs []db.AutomationOutput; InputTokens, OutputTokens int64; Estimated bool; Status, Error string }`; `func DryRunInMemory(ctx context.Context, b Backends, r *Recipe, opts DryRunOptions) (*DryRunReport, error)` — `Env.DryRun = true`, `Env.Run` a synthetic `&db.AutomationRun{ID: 0, Trigger: db.TriggerDryRun}`, `Env.Journal = NewMemoryJournal()`, `Env.Wait` nil (every wait-capable call returns `{status:"dry_run"}` before it would wait), daily remainder unbounded (a draft's tokens are not counted toward the daily cap — stated v1 limit), the commit buffer is never committed; `Status` is the terminal status the run would have had (`succeeded`, `failed`, `budget_exceeded`, `timed_out`), `Outputs` the buffered would-be outputs. Never touches `Backends.DB` except `AllowTool`'s read-only lookups.
- Depends on: Tasks 2, 6, 7.

- [ ] **Step 1: Failing tests** (`automationstest` fakes, file DB):
  - `TestExecutor_RunsQueuedToSucceeded` — state and outputs committed, summary set, steps present.
  - `TestAuto04_FailedRunLeavesStateAndOutputsUnchanged` — four sub-tests: throw (`failed`), `while(true){}` with 1-minute budget on a short real deadline (`timed_out`), FakeGenerator usage over budget (`budget_exceeded`), CLI cancel mid-run (`cancelled`) → `automation_state`/`automation_outputs` byte-identical to before.
  - `TestAuto04_SucceededCommitsStateAndOutputsAtomically`.
  - `TestAuto08_InterruptOnBudget` — FakeGenerator reporting 30000 tokens per call, `budget.tokens` 50000: second call crosses → `budget_exceeded`; a third `llm` never reaches the generator.
  - `TestAuto08_CatchAllLoopStillEndsOnBudget` — `while(true){try{llm("x")}catch(e){}}` → `budget_exceeded` (Review Focus 2).
  - `TestAuto08_DailyCap` — prior runs today used 1,999,000 of 2,000,000 → new run ends `budget_exceeded`/`daily_cap` (crossing mid-run also interrupts); a run yesterday does not count.
  - `TestBudget_EstimatesTokensWhenUsageMissing`.
  - `TestAuto05_OneActiveRunPerAutomation` (executor level) — two queued of one automation, `Step` → one started.
  - `TestExecutor_MaxConcurrentRuns` — three automations queued, `MaxConcurrent` 2 → two running.
  - `TestAuto06_UnconfirmedRecipeIsCancelledNotRun` — `not_runnable`, generator untouched (non-dry triggers).
  - `TestAuto06_DryRunOfUnconfirmedRecipeRuns` — `ExecuteInline` of a `dry_run` row of an unconfirmed but parsable recipe runs with writes as `dry_run`; a parse-error recipe → `failed`/`not_runnable`.
  - `TestAuto06_ExecutorRunsIndexedCopyNotFile` — file on disk differs from `recipe_text` → indexed script runs.
  - `TestAuto06_EditDuringRunDoesNotAffectRunningSnapshot` — rescan with a changed script while a run blocks in a FakeGenerator call → run finishes with the old script; automation now not runnable (Review Focus 1).
  - `TestAuto08_RestartMarksInterrupted` — running row left by a "previous" executor → `Run` marks it `failed`/`interrupted` before anything else.
  - `TestAuto12_DryRunWritesNoActionsOutputsOrState` — `ExecuteInline` on a `dry_run` row: zero `agent_actions` rows, no outputs, state unchanged, output/state steps `dry_run`, `llm` tokens counted on the run.
  - `TestExecutor_CancelQueued` — CLI cancel of a queued run → never started.
  - `TestExecutor_UncaughtPermissionDeniedFailsWithPermissionKind`.
  - `TestWaiter_PauseTimeoutExpires` — fake clock past `pause_timeout_hours` → `expired`; `ready` true earlier → resumes and active time excludes the pause.
  - `TestExecutor_EventRunExposesTriggerEvents` (S5) — a queued event run whose `event_json` holds two events → the script returns `trigger.events.length + ":" + trigger.events[0].channel + ":" + trigger.truncated` = `"2:releases:false"`.
  - `TestExecutor_NonEventRunHasNoEvents` — manual run → `typeof trigger.events === "undefined"`, `trigger.truncated === false`.
  - `TestExecutor_MalformedEventJSONFailsAsBackend` — `event_json = "{"` → `failed`/`backend`, generator untouched.
  - `TestDryRunInMemory_WritesNoRows` — script calls `llm`, a read `tool`, `state.set`, `output.inbox`, `log` → report has 5 steps, `output`/`state` steps `dry_run`; `automation_runs`, `automation_run_steps`, `automation_state`, `automation_outputs`, `agent_actions` row counts unchanged.
  - `TestDryRunInMemory_BudgetBound` — `opts.Budget{Tokens: 50000, Minutes: 5}`, FakeGenerator 30000 tokens per call, script calls `llm` 3× → `Status == "budget_exceeded"`, the third call never reaches the generator.
- [ ] **Step 2:** `go test ./internal/automations -run 'TestExecutor|TestAuto04|TestAuto05_One|TestAuto06|TestAuto08|TestAuto12|TestBudget|TestWaiter|TestDryRunInMemory'` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 command → PASS; `go test -race ./internal/automations -run 'TestExecutor|TestAuto05'` once at the end.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): run executor with budgets, cancel and restart`.

### Task 11: Daemon wiring, wake signal, config and feature

**Files:**
- Create: `internal/daemon/automation_wake.go`, `internal/daemon/automation_wake_test.go`
- Modify: `internal/daemon/daemon.go` (fields, setter, goroutines in `Run`), `cmd/sync.go` (wire scheduler/executor when the daemon starts), `internal/config/config.go` (+ defaults), `internal/features/registry.go` (+ registry test expectations)

**Interfaces:**
- Consumes: `NewIndexer`, `NewScheduler`, `NewExecutor`, `DefaultModules`, `buildAutomationRegistry` (Task 5b — never `buildToolRegistry` directly), `cliGenerator`/`cliPooledGenerator`.
- Produces:
  - `const AutomationWakeSignal = syscall.SIGUSR2`; `func WatchAutomationWake(ctx context.Context) <-chan struct{}` (non-blocking coalescing sends, closed on ctx done — the `WatchTrigger` contract).
  - `type AutomationRunner interface { Run(ctx context.Context) error; Wake() }`; `func (d *Daemon) SetAutomations(scheduler, executor AutomationRunner)`; `Run` starts both as goroutines (only when set and `cfg.Automations.Enabled`), forwards each wake to both, and never calls `runSync` for it.
  - Config: `type AutomationsConfig struct { Enabled bool `mapstructure:"enabled"`; DailyBudgetTokens int64 `mapstructure:"daily_budget_tokens"` }`; field `Automations AutomationsConfig `mapstructure:"automations"``; defaults `automations.enabled = true`, `automations.daily_budget_tokens = 2000000`.
  - Feature registry entry `ID: "automations"`, `ConfigKey: "automations.enabled"`, `Cost: CostMedium`, `Enabled: cfg.Automations.Enabled`, English description/tagline/benefits (Icon `gearshape.2`).
- Depends on: Tasks 5b, 8, 9, 10.

- [ ] **Step 1: Failing tests:**
  - `TestDaemon_AutomationWakeSignalDoesNotStartSync` — inject a fake `AutomationRunner` and a wake channel; firing it calls `Wake` once and the sync counter stays at the initial sync only.
  - `TestWatchAutomationWake_CoalescesAndCloses`.
  - `TestDaemon_AutomationsDisabledStartsNothing`.
  - `TestConfig_AutomationsDefaults`.
  - Feature registry tests updated for the new entry (`go test ./internal/features`).
- [ ] **Step 2:** `go test ./internal/daemon -run 'TestDaemon_Automation|TestWatchAutomationWake'`, `go test ./internal/config -run TestConfig_Automations`, `go test ./internal/features` → FAIL.
- [ ] **Step 3:** Implement and wire in `cmd/sync.go` (daemon path only).
- [ ] **Step 4:** Step 2 commands → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): daemon scheduler/executor goroutines and SIGUSR2 wake`.

### Task 12: `watchtower automations` CLI and the AGENT-07 marker

**Files:**
- Create: `cmd/automations.go`, `cmd/automations_run.go`, `cmd/automations_wake.go`, `cmd/automations_test.go`
- Modify: `cmd/actions.go` (`agentEnvMarkers` += `automations.RunEnvMarker`), `cmd/actions_test.go` (marker table), `WatchtowerDesktop/Sources/WatchtowerCore/Utilities/Constants.swift` (`agentEnvMarkers` += `"WATCHTOWER_AUTOMATION_RUN_ID"`), `WatchtowerDesktop/Tests/Core/ConstantsAgentMarkersTests.swift`

**Interfaces:**
- Consumes: everything above; `dry-run` builds its `Backends.Registry` with `buildAutomationRegistry` (Task 5b), like the daemon.
- Produces:
  - `const RunEnvMarker = "WATCHTOWER_AUTOMATION_RUN_ID"` in `internal/automations`.
  - `func wakeAutomations(cfg *config.Config) (running bool, err error)` in `cmd/automations_wake.go` — `daemon.FindConfirmedProcess(pidFilePath(cfg))` then `syscall.Kill(pid, daemon.AutomationWakeSignal)`; no daemon → `(false, nil)`. P1 adds no `wake` subcommand; P3 Task 5 adds `automations wake` in the same file over this function, and P5's `session-launched`/`session-ended` call it.
  - Commands (spec §10, P1 subset), all with `--json` where listed: `list [--workbench N]` (`next_run_at`, last status, 7-day tokens), `show <id|slug>` (row, hashes, `widening` vs confirmed via `Covers`, `runnable`, `needs_confirmation`), `validate <file> [--workbench N]` (no DB write; `--workbench` sets the scope the `approval_hash` is computed for; without `--json` exit 1 with errors; with `--json` a parse error is `ok:false` with exit 0 — the Desktop decodes it; exit 1 only on a usage error), `rescan [--workbench N]` (`--workbench` accepted and routed to `RescanFolder` with the workbench folder — P5 relies on it), `run <id> [--rerun-of R]` (`{"run_id", "coalesced", "daemon_running"}`; prints `daemon not running; the run starts when it does` and exits 0 when none), `dry-run <id>` / `dry-run --file F` (`--file` must lie in the personal folder or a workbench's `.watchtower/automations/`; the folder is rescanned first and the file's index row is used — any other path → error "save it first"; enqueues `trigger='dry_run'` and executes via `ExecuteInline`, printing the steps; dry runs are exempt from the confirmation gate because they write nothing (AUTO-12), but dry-running an **unconfirmed** recipe is the owner's alone (ask #271, spec §20.1 D16): refused under every AI-agent marker of AGENT-07 (`WATCHTOWER_AUTOMATION_RUN_ID` included), with `refuseUnderAgent`'s message and the hint "only the owner can dry-run a recipe that is not confirmed yet; use Dry run on its card in Automations", so an agent cannot read data through a manifest the owner never confirmed; a confirmed recipe dry-runs under markers too), `cancel <run-id>`, `runs <id> [--limit N]`, `steps <run-id>`, `enable|disable <id>`, `confirm <id> --hash <sha>` (refused under markers), `save --file F [--path P] [--confirm-hash <sha>]` (atomic write through the existing `fsutil.WriteFileAtomic(path, data, 0o644)` into the personal folder or `P` — the one helper P3's `save_automation` and P6's `install-template` reuse; rescan, then confirm when the flag is given — the flag refused under markers), `delete <id>`, `outputs [--kind K]`.
  - Refusal message for marker-gated verbs reuses `refuseUnderAgent` (its recovery hint included).
  - **Pinned `--json` keys** (the Desktop's contract, taken from P3 Task 5; later phases may add keys, never rename or drop one; every array is `[]`, never `null`):
    - `show <id> --json` → `{"id", "slug", "scope", "project_id", "path", "name", "description", "script", "recipe_text", "trigger_kind", "trigger_spec", "permissions": [], "outputs": [], "budget_tokens", "budget_minutes", "concurrency", "missed_policy", "pause_timeout_hours", "enabled", "runnable", "needs_confirmation", "parse_error", "content_hash", "approval_hash", "confirmed_hash", "widening": []}` (P2 adds `grants`).
    - `validate <file> --json` → `{"ok": bool, "errors": [string], "slug", "name", "scope", "approval_hash", "content_hash", "permissions": [], "outputs": [], "widening": []}` — `widening` = every normalised permission (P3 adds `--against <id>`, which computes it with `Covers` against that automation).
    - `run <id> --json` → `{"run_id", "coalesced", "daemon_running"}`.
    - `dry-run <id> --json` (and `--file`) → `{"run_id", "status", "error", "input_tokens", "output_tokens"}` — the run row exists, so the Desktop reads its steps from the DB by `run_id`.
    - `save … --json` → `{"automation_id", "path", "approval_hash", "confirmed"}` (P3 adds `--expect-content-hash <sha>`, a refusal before the write).
- Depends on: Tasks 1–11.

- [ ] **Step 1: Failing tests** (`cmd/automations_test.go`, temp workspace via the existing cmd test harness):
  - `TestAutomationsCLI_ValidateReportsErrorsWithoutWriting`.
  - `TestAutomationsCLI_RescanListShow` — new recipe listed with `needs_confirmation: true`.
  - `TestAutomationsCLI_ConfirmRefusedUnderAgentMarkers` — per marker incl. `WATCHTOWER_AUTOMATION_RUN_ID`: non-zero exit, `confirmed_hash` unchanged; without markers → confirmed; stale hash → error.
  - `TestAutomationsCLI_SaveIsAtomicAndIndexes` — save writes the file (no temp left), rescans; `--confirm-hash` under a marker refused and the file not written.
  - `TestAuto09_RunCommandOnlyQueues` — `run` inserts one `queued` row and executes nothing (FakeGenerator untouched); second `run` → `coalesced: true`; with no daemon prints the not-running line, exit 0.
  - `TestAutomationsCLI_DryRunPrintsSteps` — FakeGenerator injected through the cmd test seam; run row `trigger='dry_run'`.
  - `TestAutomationsCLI_DryRunUnconfirmedRefusedUnderAgentMarkers` (ask #271) — unconfirmed recipe, per marker of `agentEnvMarkers` incl. `CLAUDECODE` and `WATCHTOWER_AUTOMATION_RUN_ID` → refused, non-zero exit, no run row, FakeGenerator untouched; the same recipe without markers (the owner, the Desktop's CLI child) → runs; confirmed recipe under a marker → allowed; `--file` naming an unconfirmed recipe file under a marker → refused the same way; `--file` outside the recipe folders → "save it first".
  - `TestAutomationsCLI_CancelAndDelete`.
  - `TestAutomationsCLI_ShowJSONKeys` / `TestAutomationsCLI_ValidateJSONKeys` / `TestAutomationsCLI_RunJSONKeys` / `TestAutomationsCLI_DryRunJSONKeys` / `TestAutomationsCLI_SaveJSONKeys` — exact key sets above.
  - `TestAutomationsCLI_JSONEmptyArraysNotNull` — `show` and `validate` of a recipe with no permissions/outputs → `[]` not `null` for `permissions`, `outputs`, `widening`, `errors`.
  - `TestAutomationsCLI_ValidateParseErrorIsOkFalse` — with `--json`: exit 0, `ok:false`, `errors` non-empty; without `--json`: exit 1.
  - `TestAgent07_CLIApproveRefusedUnderAgent` gains the new marker row (strengthening).
  - Swift: `ConstantsAgentMarkersTests` asserts the new marker.
- [ ] **Step 2:** `go test ./cmd -run 'TestAutomationsCLI|TestAuto09_RunCommand|TestAgent07'`, `make test-swift FILTER=ConstantsAgentMarkersTests` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 commands → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): watchtower automations CLI and the run env marker`.

### Task 13: Inventory, feature note, CLAUDE.md

**Files:**
- Create: `docs/inventory/automations.md`, `docs/features/automations.md`
- Modify: `docs/inventory/README.md` (module row: `internal/automations/`, `internal/db/automations.go`, `internal/db/automation_runs.go`, `internal/db/migrations/00113_automations.sql`, `cmd/automations*.go`, `internal/daemon/automation_wake.go`, `internal/tools/emails.go`, `internal/tools/automation_reads.go`, `cmd/automations_registry.go`), `docs/inventory/agent-actions.md` (changelog: AGENT-07 marker strengthening — `WATCHTOWER_AUTOMATION_RUN_ID`, and `automations confirm`, `save --confirm-hash` and `dry-run` of an unconfirmed recipe refused under markers (ask #271); no guard relaxed), `CLAUDE.md` (Feature Notes line for Automations, P1)

**Interfaces:**
- Consumes: guard test names from Tasks 1–12.
- Produces: `docs/inventory/automations.md` with AUTO-01..13 copied from spec §14.1 (Observable, Why locked, Test guards, Locked since 2026-10-14). Status: **Enforced** for AUTO-01, 04, 05, 06, 07, 08, 09 (scheduler/CLI half), 10, 11, 12 (P1 half); **Planned** with the owning phase for AUTO-02 (read side enforced: list `TestTool_WriteNotAvailableInP1`; P2 flips it), AUTO-03 (P2 flips it), the `draft_automation` half of AUTO-06 (CLI half enforced by `TestAutomationsCLI_DryRunUnconfirmedRefusedUnderAgentMarkers`; P3 flips it, ask #271), AUTO-13 (P5 flips it), the event half of AUTO-09 (P4 flips it) and the session/shell half of AUTO-12 (P5 flips it). The Desktop buttons of AUTO-09 (P3's Run now, P5's header buttons) add guards without a status change. Exactly one plan flips each Planned part. Each guard listed by file and test name as written in Tasks 1–12.
- Depends on: Task 12.

- [ ] **Step 1:** Write the docs. `docs/features/automations.md`: recipes and folders, manifest grammar, SDK P1, scheduler/executor/wake, token budgets and daily cap, CLI, the D1–D23 decisions in one line each (§20 and §20.1), the automation read tools of Tasks 5a/5b with their permissions (D23; `get_confluence_page` deliberately not offered — live read), v1 limits (incl. the `list_messages`/`list_upcoming_events` ruling of Task 4, ask #273: only `slack:read@*`/`calendar:read@*` or `tool:<name>` admits them; the broad knowledge tools only by `tool:<name>`), "P2–P6 pending" list.
- [ ] **Step 2:** Verify every test name in the inventory exists: `grep -rn '<name>' internal cmd WatchtowerDesktop/Tests` for each (no missing names).
- [ ] **Step 3:** `bash scripts/leak-check.sh --staged` after `git add` → clean.
- [ ] **Step 4:** Commit `docs(automations): inventory AUTO-01..13, feature note and CLAUDE.md line`.

### Phase gate (controller, once)

- [ ] `bash scripts/dev-health.sh` → not overloaded.
- [ ] `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...` (logs to files, explicit exit codes).
- [ ] Re-check migration numbering against `origin/main`.
- [ ] local-review, then one PR `feature/automations-p1 → feature/automations`.

---

## Seams for later phases

These names are the contract P2–P6 plans consume. Changing one after P1 merges is a cross-phase change that must update this section and every later plan. The seam changes the P2–P6 plans asked for (P2 S1–S4, P3 notes 1–3, P4 S5–S7, P5 notes 1–3, P6 S8–S9) are settled here and folded into Tasks 2, 4, 6, 7, 10 and 12 above; no later plan carries an "if P1 ships without it" fallback.

- **Tables (00113):** `automations`, `automation_runs`, `automation_run_steps`, `automation_state`, `automation_outputs` with the exact columns of spec §9 (tokens, not usd). P2 adds 00114 `automation_tool_grants`; P5 adds 00115 (`owner_asks.automation_run_id`, `terminal_sessions.automation_run_id`). P3, P4 and P6 add no migration.
- **`event_json` shape (S7):** `''` for non-event runs; for `trigger='event'` exactly `{"cycles": [...], "events": [... ≤ MaxEventsPerRun (100)], "count": n, "truncated": bool}` = `db.AutomationEventPayload`. P4's bus writes it, `db.MergeQueuedAutomationRunEvents` (P4, S6) extends it, the executor decodes it.
- **Queue insert API:** `db.EnqueueAutomationRun(db.EnqueueRequest{AutomationID, Trigger, ScheduledFor, EventCycle, EventJSON, RerunOf, AdvanceScheduleTo, NextRunAt, Now}) (runID int64, coalesced bool, err error)` — the only way to create a run. Check order: (1) a run already carrying `EventCycle` (in `event_cycle` or in `event_json.cycles`) → coalesced; (2) a `queued` row of (automation, trigger) → coalesced; else insert. P4's bus uses `Trigger: db.TriggerEvent` with `EventCycle`/`EventJSON` and, on a coalesce onto a run of another cycle, `db.MergeQueuedAutomationRunEvents` (P4) — it never inserts a run, never writes `event_cycle`, and only touches a row still `queued` with `trigger='event'`, so the unique `(automation_id, event_cycle)` index and the queued-coalescing index hold unchanged. Trigger constants `db.TriggerSchedule|TriggerCatchUp|TriggerButton|TriggerEvent|TriggerManual|TriggerDryRun`.
- **Run/step stores:** `db.AutomationRun`, `db.AutomationRunStep`, `db.StepFinish` (fields `Status`, `Auto`, `ActionID`, `AskID`, `SessionID`, tokens), `db.ClaimAutomationRun`, `db.FinishAutomationRun(runID, db.RunFinish, *db.RunCommit)`, `db.CancelAutomationRun`, `db.SetAutomationRunWaiting(runID, reason)` (from `running`, **or from `waiting` as a reason-only change** — P5 `app` → `session`) / `db.ResumeAutomationRun`, wait reasons `db.WaitApproval|WaitAsk|WaitSession|WaitApp`, `db.MarkAutomationRunStep(id, status, db.StepFinish)` (non-final), `db.ListAutomationRunSteps`, `db.ListAutomationOutputs(kind, limit)`, `db.AutomationTokensBetween`, `db.ErrRunNotActive`.
- **Index store:** `db.Automation` (+ `Runnable()`), `db.UpsertAutomationIndex`, `db.GetAutomation`, `db.GetAutomationBySlug`, `db.ListAutomations(db.AutomationFilter{Scope, ProjectID, TriggerKind, RunnableOnly, IncludeRemoved})`, `db.ConfirmAutomation(id, hash)` / `db.ErrHashMismatch`, `db.SetAutomationEnabled`.
- **Recipe/manifest:** `automations.ParseRecipe(slug, data, scope)`, `automations.Recipe`, `automations.Scope{Kind, WorkbenchID}` / `ScopePersonal|ScopeWorkbench`, `automations.ApprovalHash(*Recipe)`, `automations.ContentHash`, `automations.ParseManifest`, `(*Manifest).AllowTool(ctx, d *db.DB, t *tools.Tool, args) (string, error)` (S1) and `AllowLLM|AllowOutput|AllowCapability|AllowMCP|AllowShell`, all returning `*automations.PermissionDenied{Needed}`; `automations.Covers(old, new)`; `automations.ToolCapability{Capability, Verb, ScopeArg, ScopeOf func(ctx, d, args) ([]CallScope, error)}` / `automations.CallScope{Values}` / `automations.ToolCapabilities` (P2's write tools already listed with their real argument names — `project_key`, `key`, `keys`, `issue_keys`, `account_id` resolved to a label; `list_messages`/`list_upcoming_events` always unscoped, admitted only by `@*` or `tool:` (ask #273); `search_knowledge`/`get_knowledge_document`/`get_task_context` have no entry and no `knowledge` capability exists — `tool:` only (ask #273)); `automations.ClampListLimit(t, args)` (S9); `automations.EventTypes`, `automations.MaxEventsPerRun`. P2 adds `(*Manifest).AdmitsTool` / `AdmitsWrite` (P6 consumes `AdmitsTool`).
- **SDK registration seam:** `automations.Module` (`Name() string; Install(Definer)`), `automations.Definer.Define(path string, fn SDKFunc)` — **a later definition of the same path replaces the earlier one** (S3, `TestDefiner_LaterModuleReplacesPath`), `automations.SDKFunc func(env *Env, call goja.FunctionCall, rt *goja.Runtime) (any, error)`, `automations.Env{Ctx, Run, Automation, Recipe, Manifest, DryRun, Journal, Meter, Buffer, Wait}`, `(*Env).Binding() tools.Binding` (P2 adds `AutomationRunID` and `AutomationAgent` to `tools.Binding` and sets the former here), `automations.DefaultModules(Backends) []Module` — later phases append `ToolWriteModule` (P2, replaces `tool` by S3 and delegates reads to P1's read function), output kinds via `(*OutputMod).RegisterOutputKind("briefing"|"target"|"slack", fn)` on the `*OutputMod` that `OutputModule()` returns (S2, P2, closures over `Backends`), `AskModule`/`SessionModule`/`ShellModule` (P5), `MCPModule`/`AgentModule` (P6).
- **Trigger object:** `automations.TriggerInfo{Kind, RunID, ScheduledFor, CatchUp, Button, Events, Truncated, DryRun}` — the executor fills `Events`/`Truncated` from `event_json` for event runs (S5); P4 only produces the rows.
- **Errors to the script:** `automations.SDKError{Name, Message, Needed}` with names `PermissionDenied`, `ResultTooLarge`, `StateTooLarge`, `ValidationError`, `ToolError`, `BudgetExceeded`, `NotAvailable`.
- **Journal/meter/buffer:** `automations.NewJournal(d, runID, dryRun)`, `automations.NewMemoryJournal()`, `(*Journal).Begin(kind, name, args) *Step`, `(*Journal).Steps() []db.AutomationRunStep`, `(*Journal).Count()`; `(*Step).ID() int64`, `(*Step).Mark(status string, link db.StepFinish) error` (S4 — the one non-final update; only `link.ActionID|AskID|SessionID` are read: P2 `{wait:true}` → `Mark("waiting", db.StepFinish{ActionID: id})`, P5 `ask()` → `{AskID: id}`, P5 `session()` → zero link), `(*Step).OK|Fail|Denied|Finish(db.StepFinish)|Usage(in, out, estimated, reportedUSD)`; `(*Meter).BeforeCall|Debit|PauseActive|ResumeActive|Deadline|Remaining`; `(*CommitBuffer).AddOutput`.
- **Dry run in memory (P3):** `automations.DryRunInMemory(ctx, Backends, *Recipe, DryRunOptions{Budget, Modules}) (*DryRunReport, error)`, `DryRunReport{Steps, Outputs, InputTokens, OutputTokens, Estimated, Status, Error}` — writes no row of any table.
- **Waiting:** `automations.Waiter.Wait(ctx, reason, ready func(context.Context) (bool, error)) error` from `(*Executor).Waiter()` — P2 `tool(..., {wait:true})` uses reason `db.WaitApproval`; P5 `ask()` uses `db.WaitAsk`, `session()` starts with `db.WaitApp` and switches to `db.WaitSession` through `db.SetAutomationRunWaiting` while still waiting. It pauses active time, honours cancel and `pause_timeout_hours` (→ `expired`).
- **Backends:** `automations.Backends{DB, Generator, Registry, Clock, Shell, Workbench}` in `backends.go`; `automations.ToolRegistry` already includes `Propose` for P2; `automations.ShellRunner`/`ShellCommand`/`ShellResult` and `automations.WorkbenchResolver`/`WorkbenchInfo` are declared here, nil until P5 supplies `NewProcessShellRunner()` and `NewWorkbenchResolver(…)`. P6 appends `MCP MCPCaller` and `Agent AgentRunner` (declared by P6 in the same file).
- **Executor:** `automations.NewExecutor(d, Backends, ExecutorOptions{MaxConcurrent, DailyBudgetTokens, Modules, Logger})`, `(*Executor).Run|Wake|Step|ExecuteInline|Waiter|Wait`.
- **Scheduler / wake:** `automations.NewScheduler(d, ix, clock, wake func())`, `(*Scheduler).Run|Tick`; `daemon.AutomationWakeSignal` (`SIGUSR2`), `daemon.WatchAutomationWake`, `daemon.AutomationRunner`, `(*Daemon).SetAutomations(scheduler, executor)`; CLI-side `wakeAutomations(cfg)` in `cmd/automations_wake.go`. P3 adds the `automations wake` subcommand over it (the Desktop sends it after an Approve/Reject of an automation row and, from P5, after an ask answer); P5's `session-launched`/`session-ended` call it.
- **CLI (Task 12):** the pinned `--json` keys of `show`, `validate`, `run`, `dry-run` (returns `run_id`), `save` — additive only in later phases. P3 adds `wake`, `validate --against <id>`, `save --expect-content-hash <sha>`; P2 adds `auto` and the `grants`/`auto_paused` keys; P5 adds `session-launched`/`session-ended`; P6 adds `templates`/`install-template`. Atomic recipe writes go through `fsutil.WriteFileAtomic(path, data, 0o644)` everywhere.
- **Indexer:** `automations.NewIndexer(d, workspaceDir, clock)`, `RescanPersonal`, `RescanFolder(ctx, scope, dir)`, `Changed(dir)`, `PersonalDir(workspaceDir)`, `WorkbenchDir(folder)` (`<folder>/.watchtower/automations`), CLI `automations rescan --workbench N` (P5's Desktop calls it for every workbench page it opens).
- **Registry constants:** `tools.AutomationSurface = "automation"`, `tools.AutomationContextType = "automation_run"`; read tools `list_emails`/`get_email` on that surface only.
- **Automation registry and D23 reads (Task 5b, ask #277):** `buildAutomationRegistry(cfg, database)` in `cmd` = `buildToolRegistry` + `memory_map`/`memory_open`/`memory_recall` (no shadow handle) — the one registry every automation path uses (daemon executor, CLI `dry-run`, P3's `draft_automation` backends, P6's runtime B; P6's `--surface automation` MCP server gets the memory tools from `DependentReadTools` as every chat-mode server does). Automation-only reads: `list_inbox`, `list_calendar_events`, `list_meeting_recaps`, `get_meeting_recap`, `list_meeting_notes`, `list_day_plans`, `get_day_plan`, `list_reminders`, `list_jira_sprints`, `list_jira_releases`; `get_writing_style` gains the `automation` surface (`get_confluence_page` does not — live read); `memory_open` does not bump stats on it. Capabilities `meetings:read`, `dayplan:read` (read only); `tool:`-only: the D21 three, `list_inbox`, the memory tools, `get_writing_style`.
- **Test fakes:** `internal/automations/automationstest` — `FakeClock`, `FakeGenerator`, `FakeRegistry`, `SeedAutomation(t, d, recipeText, SeedOptions)`. P5 adds `FakeShell`/`FakeSessionDesk`, P6 `FakeMCP`/`FakeAgent`.
- **Env marker:** `automations.RunEnvMarker = "WATCHTOWER_AUTOMATION_RUN_ID"` — P5 sets it on every `shell()`/`session()` child, P6 on `agent()` children; already in `agentEnvMarkers` (Go and Swift).
- **Source tags:** `automations.SourceLLMLight = "automation.llm"`, `automations.SourceLLMStrong = "automation.llm.strong"` (P6 `agent()` model calls reuse them).
- **Config/feature:** `cfg.Automations.Enabled`, `cfg.Automations.DailyBudgetTokens`; feature id `automations` (P3 hides the Desktop tab when off).
- **Inventory:** `docs/inventory/automations.md` exists with AUTO-01..13; each Planned part is flipped by exactly one later plan, in the same commit as its code: AUTO-02 and AUTO-03 by P2, the `draft_automation` half of AUTO-06 by P3 (ask #271), the AUTO-09 event half by P4, the AUTO-12 session/shell half and AUTO-13 by P5. P6 adds guards only; P3 adds guards beside its one flip.
