# Automations P5 (workbench) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Workbench automations: recipes in `<folder>/.watchtower/automations/` with hash trust, `trigger: button` automations as buttons in the workbench header, a visible `session()` (the Desktop opens a normal workbench session; with the app closed the run waits — `WaitApp` → `WaitSession`), `ask()` for workbench automations only (D7) on migration 00117, `shell(cmd)` with exact commands and refused in privacy-protected folders (D9), the run marker on every child, and the PR-review (comments through `session()`, D13) and Release / Deploy recipes working end to end.

**Architecture:** The daemon's scheduler also indexes unprotected workbench folders (P1's `Indexer.RescanFolder` with `ScopeWorkbench`); the Desktop runs `automations rescan --workbench N` for every workbench page it opens and on folder-watcher changes under `.watchtower/automations/`, so protected folders are indexed without the daemon touching them. Three new SDK modules join `DefaultModules`: `ShellModule` (a `/bin/sh -c` child in its own process group, exact-match only), `SessionModule` (writes a `waiting` session step; the Desktop's `AutomationSessionCenter` launches a normal session and attaches it through the CLI; the executor's `Waiter` resumes the run on Finished / Error / Stopped / deleted) and `AskModule` (an `owner_asks` row with `automation_run_id`, delivered back to the run, never into a terminal). The header buttons read the P3 `AutomationsViewModel` and only queue runs through `automations run`.

**Tech Stack:** Go 1.26 (goose migration 00117, `os/exec` with `Setpgid`, the P1 `internal/automations` seams), SwiftUI + GRDB (`TerminalCenter`, `WorkbenchesViewModel`, `OwnerAsksViewModel`, `FolderWatcher`, `TerminalLaunch`).

**Spec:** `docs/superpowers/specs/2026-10-14-automations-design.md` §2.1, §2.4–2.5, §3.1, §5 (`ask`, `session`, `shell`), §7.6, §9.5, §12.4, §13, §14.1 (AUTO-09, AUTO-12, AUTO-13), §15 (templates 2 and 5), §17 (P5 row), §18 (P5 tests), §20 (D7, D9, D13, D15), §14.6 (PROJ-03 amendment), §20.1 (D16, D17, D19 — asks #271, #272). P1 seams: `docs/superpowers/plans/2026-10-14-automations-p1.md` § "Seams for later phases". P3 plan: `docs/superpowers/plans/2026-10-14-automations-p3.md`.

**Branch:** `feature/automations-p5` → one PR into `feature/automations`. Never `main`.

**Depends on:** P1, P2, P3 merged (spec §17).

## Header notes — seams

1. **Wait reason change (settled in P1).** `db.SetAutomationRunWaiting(runID, reason)` accepts a run already `waiting` as a reason-only change (status and `active_ms` untouched; P1 `TestRunWaiting_ReasonChangeWhileWaiting`). `session()` moves `app` → `session` with it inside one wait (§13.1 step 2), no running blip. Consumed in Task 5.
2. **A step that stays open while the run waits (settled in P1).** `(*Step).ID() int64` and `(*Step).Mark(status string, link db.StepFinish) error` — the one non-final update shared with P2 (`finished_at` stays NULL; only `link.ActionID|AskID|SessionID` are read). `session()` calls `Mark("waiting", db.StepFinish{})`; `ask()` calls `Mark("waiting", db.StepFinish{AskID: id})` so the step names its ask before the run pauses. Consumed in Tasks 5–6.
3. **Backends fields (settled in P1).** `automations.Backends` already has `Shell ShellRunner` and `Workbench WorkbenchResolver`, and P1 declares the interfaces and their value types (`ShellCommand`, `ShellResult`, `WorkbenchInfo`); both are nil until this plan wires them. P5 supplies the implementations: `NewWorkbenchResolver` (Task 3) and `NewProcessShellRunner` (Task 4), wired in `cmd/sync.go` and the CLI's `dry-run`.
4. **P3 ruling R-P3-5 lifted.** P3 refuses workbench saves (`save_automation` with `workbench_id`, the form on a workbench row); Task 8 lifts both together with the PROJ-03 amendment, **owner-approved in ask #272** (spec §14.6, §20.1 D17) — no merge gate remains.
5. **P6 templates.** `pr-review-rounds`, `release`, `deploy-test`, `deploy-stage` are written here as test fixtures (`internal/automations/testdata/workbench/`) and pinned end to end; P6 embeds them byte-for-byte as templates (move, do not rewrite) and its `TestTemplates_DryRunE2E` reuses `automationstest.FakeShell` / `FakeSessionDesk` from Task 7.

## Global Constraints

- All repo text English; UI strings English; public repo: fixtures use `acme`, `example.com`, `t.TempDir()` folders — never a real path.
- Inner loop only: `go test ./internal/<pkg>`, `go test ./cmd -run '<Name>'`, `make test-swift FILTER=<Class>`, `make lint-diff`. Full gate once per phase.
- **Swift tasks run one at a time** (Tasks 9–12 are **Heavy Swift — serial**); Go tasks may run as parallel lanes per `Depends on`.
- Tests that start a process (`shell()` tests, fake `sh` scripts) kill the whole process group and wait for it in `t.Cleanup`, also on the timeout/cancel path they test.
- Async state (pending session requests, launches, header-button runs) lives in AppState-owned centers (`AutomationSessionCenter`, P3's `AutomationsViewModel`), each with a "started → navigated away → came back" test.
- The daemon never stats, lists or reads a folder that `fsutil.PrivacyProtected` reports (Documents, Desktop, Downloads, Library/CloudStorage, Library/Mobile Documents under the home — symlink-resolved too — and `/Volumes`, case-insensitive; an unknown home counts as protected).
- Recipe folders keep P1's symlink policy (controller decision, P1 Task 8): the indexer lists entries with lstat semantics and never follows one — only a regular `*.md` file is a recipe; a symlink or special file is skipped with "symlinks and special files are not read; put the recipe file itself in the folder" and never opened; a recipe replaced by a symlink is marked removed; the folder path is canonicalised (`automations.CanonicalDir`). P1's CLI `save --path`, `dry-run --file` and `delete` already accept a workbench's `.watchtower/automations/` folder (the owner's own CLI writes; the PROJ-03 amendment text lands here with the Desktop path). Wake through P1's `automations wake` / `wakeAutomations`.
- Exact values (do not change without the spec):
  - Folder `<workbench folder>/.watchtower/automations/*.md`; binding by location only (D15).
  - `shell(cmd)`: `/bin/sh -c <cmd>`, `cwd` = the workbench folder, own process group (killed as a group on interrupt), timeout = the run's remaining active budget, stdout and stderr each capped at 256 KiB keeping the tail with `truncated: true`, then cut further so the serialised result fits §4's 256 KiB limit — output over the limit is truncated, never a failure, `shell()` never throws `ResultTooLarge` (D19, ask #272) —, environment exactly `PATH`, `HOME`, `LANG`, `USER` from the daemon plus `WATCHTOWER_AUTOMATION_RUN_ID=<run>` — nothing else (no tokens, no `WATCHTOWER_TERMINAL_SESSION_ID`); only a command byte-equal to a `shell:` entry; workbench automations only; in a protected folder `NotAvailable` with exactly "this workbench is in a protected folder; use session() or move the folder" (D9).
  - `session({prompt, agent?, title?, wait?})`: permission `session:start[@kind]`; step `kind='session'`, `status='waiting'`, `args_json={prompt, agent, title}`; run `waiting_reason='app'` → `'session'`; session `kind` = `agent` or the workbench's `default_agent`; title `⚙ <title or automation name> · run #N`; `automation_run_id` set; resumes on Finished (`{status:"finished", summary: finish_summary}`), Error (`agent_failed_at`), Stopped (process gone while not finished) or deleted (`{status:"deleted"}`); `wait:"none"` returns `{session_id}` right after the launch.
  - `ask({kind, title, summary?, questions?, checklist?})`: permission `ask:owner`; workbench only (D7; personal declaring `ask:owner` fails validation); `owner_asks` row with `session_id` NULL, `automation_run_id` set, `origin='agent'`, level by `asks.Level`; waits `ask`; `answered` → `delivered` and the answer JSON returned; Cancel/expiry → withdrawn with `withdrawn_reason='agent'`; `owner_asks.project_id` stays NOT NULL.
  - Header: one button per workbench automation with `trigger.button`, slug order, max 4 visible + overflow menu; `confirm: true` → confirmation dialog; active run → spinner, click opens the run; not runnable → disabled with "Needs your confirmation" (click opens the confirm sheet).
  - Env marker `WATCHTOWER_AUTOMATION_RUN_ID` on every `shell()` and `session()` child (AGENT-07 already refuses approvals under it).
  - Migration **00117** exactly as §9.5 (two `ALTER TABLE … ADD COLUMN automation_run_id INTEGER REFERENCES automation_runs(id) ON DELETE SET NULL`); renumber if `main` took it, verify by column presence.

## Review Focus

1. **One session per request**, whether the Desktop's poll sees a request twice, the app quits between creating the session row and attaching it, or two attaches race. Pinned: Task 5 `TestSessionAttach_IsConditional`, Task 10 `testOneLaunchPerRequestUnderRepeatedPolls`, `testCrashBetweenCreateAndAttachAdoptsTheRow`.
2. **`shell()` leaves nothing behind and sees nothing secret**: process group killed on cancel/timeout/budget, env byte-exact. Pinned: Task 4 `TestShell_KillsProcessGroupOnInterrupt`, `TestShell_EnvHasRunMarkerAndNoSecrets`.
3. **Automation asks never reach a session**: not in any session's brief, `list_asks`, `get_ask`, `withdraw_ask`, the ask guard, or the Desktop's terminal delivery. Pinned: Task 6 `TestAutomationAsks_InvisibleToSessionReaders`, Task 12 `testAutomationAskIsNeverDeliveredToATerminal`.
4. **The daemon never touches a protected folder**, and `shell()` there is refused before any process starts. Pinned: Task 3 `TestScheduler_NeverStatsProtectedWorkbench`, Task 4 `TestShell_RefusedInProtectedFolder`.
5. **A workbench deleted mid-run** (cascade removes the automation and its runs) ends cleanly: the executor drops the run without a panic or a stuck goroutine; its open asks go with the workbench. Pinned: Task 3 `TestWorkbenchDelete_MidRunExecutorDropsRun`.
6. **Dry runs start nothing** (no session request, no process, no ask row). Pinned: Task 7 `TestAuto12_DryRunStartsNoSessionOrShell`.

---

## File structure

| Path | Responsibility |
|---|---|
| `internal/db/migrations/00117_automation_workbench.sql`, `internal/db/schema.sql`, golden + Swift test schema | 00117 |
| `internal/db/owner_asks.go`, `internal/db/terminal_sessions.go`, `internal/db/automation_runs.go` | new columns, session-step helpers, ask exclusions |
| `internal/fsutil/privacy.go` (+ `internal/kb/source_workbench.go`) | `PrivacyProtected`, moved from `kb` |
| `internal/automations/workbench.go` | `NewWorkbenchResolver` (the interface is P1's), scheduler workbench rescan |
| `internal/automations/sdk_shell.go`, `sdk_session.go`, `sdk_ask.go` | the three modules |
| `internal/automations/automationstest/{shell.go,sessiondesk.go}` | `FakeShell`, `FakeSessionDesk` |
| `internal/automations/testdata/workbench/*.md`, `internal/automations/workbench_e2e_test.go` | the four recipes, end to end |
| `internal/automations/authoring/save.go` | workbench saves (lifts R-P3-5) |
| `internal/tools/workbench_asks.go`, `cmd/workbench_askguard_stop.go` | automation asks excluded |
| `cmd/automations_session.go`, `cmd/sync.go` (wiring) | `session-launched`, `session-ended` |
| `WatchtowerDesktop/Sources/WatchtowerCore/…` | `AutomationQueries` additions, `OwnerAsk`/`TerminalSession` fields, `TerminalLaunch` marker, `AutomationSessionCenter` |
| `WatchtowerDesktop/Sources/Views/Workbench/{WorkbenchHeaderControls,WorkbenchAutomationButtons}.swift` | header buttons |
| `WatchtowerDesktop/Sources/ViewModels/{WorkbenchesViewModel+Sessions,OwnerAsksViewModel}.swift`, `Sources/Views/Workbench/Asks/*` | session start, ask labels and delivery |
| `docs/…` | inventory, feature notes, app guide |

---

### Task 1: Migration 00117 and the Go/Swift row fields

**Files:**
- Create: `internal/db/migrations/00117_automation_workbench.sql`, `internal/db/automation_workbench_migration_test.go`
- Modify: `internal/db/schema.sql`, `internal/db/owner_asks.go` (`OwnerAsk.AutomationRunID sql.NullInt64`, insert + scans), `internal/db/terminal_sessions.go` (the Go struct + scans), golden snapshot, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerated), `WatchtowerDesktop/Sources/WatchtowerCore/Models/OwnerAsk.swift` (`automationRunID: Int64?`), the Swift `TerminalSession` model (`automationRunID: Int64?`), `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/TerminalSessionQueries.swift` (`NewSession.automationRunID: Int64? = nil`, inserted by `create`)

**Interfaces:**
- Consumes: `automation_runs` (00113).
- Produces: columns `owner_asks.automation_run_id`, `terminal_sessions.automation_run_id` (`INTEGER REFERENCES automation_runs(id) ON DELETE SET NULL`); `db.OwnerAsk.AutomationRunID`; `InsertOwnerAsk` writes it; Swift `TerminalSessionQueries.create` writes it (a dual path: Swift already owns `terminal_sessions` inserts).
- Depends on: none.

- [ ] **Step 1: Failing tests:** `TestMigration00117_AutomationRunColumns` (columns exist, nullable, deleting the run sets both NULL, Down drops them); `TestInsertOwnerAsk_StoresAutomationRunID`; Swift `TerminalSessionQueriesTests.testCreateStoresAutomationRunID` and `testCreateWithoutRunLeavesNull`; Swift `OwnerAskQueriesTests.testDecodesAutomationRunID`.
- [ ] **Step 2:** `go test ./internal/db -run 'TestMigration00117|TestInsertOwnerAsk_Stores'`, `make test-swift FILTER='TerminalSessionQueriesTests|OwnerAskQueriesTests'` → FAIL.
- [ ] **Step 3:** Migration (Up + Down), mirror, fields; `go test ./internal/db -run 'TestSchemaGolden|TestDesktopTestSchema' -update`.
- [ ] **Step 4:** Step 2 commands and `go test ./internal/db` → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): migration 00117 links asks and sessions to runs`.

### Task 2: `fsutil.PrivacyProtected`

**Files:**
- Create: `internal/fsutil/privacy.go`, `internal/fsutil/privacy_test.go`
- Modify: `internal/kb/source_workbench.go` (calls `fsutil.PrivacyProtected`; `privacyProtected` removed), its tests unchanged

**Interfaces:**
- Produces: `func PrivacyProtected(folder string) bool` — byte-for-byte the current `kb.privacyProtected` rule (the `/Volumes` prefix; home `Documents`, `Desktop`, `Downloads`, `Library/CloudStorage`, `Library/Mobile Documents`, also under the symlink-resolved home; case-insensitive; `UserHomeDir` error → true); `func HasPathPrefix(path, root string) bool` exported with it.
- Depends on: none.

- [ ] **Step 1: Failing tests:** `TestPrivacyProtected_Table` (each location, a sibling like `~/Documentsx` → false, case variants, `/Volumes/x` → true, `/tmp/x` → false); the existing `internal/kb` tests stay green unmodified.
- [ ] **Step 2:** `go test ./internal/fsutil -run TestPrivacyProtected` → FAIL.
- [ ] **Step 3:** Move the function; no behaviour change.
- [ ] **Step 4:** `go test ./internal/fsutil ./internal/kb` → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `refactor(fsutil): share the privacy-protected folder rule`.

### Task 3: Workbench scope — scheduler rescan, resolver, deletion

**Files:**
- Create: `internal/automations/workbench.go`, `internal/automations/workbench_test.go`
- Modify: `internal/automations/scheduler.go` (`Tick` also rescans workbench folders), `internal/automations/executor.go` (a run whose rows vanished ends quietly), `cmd/sync.go` (resolver wiring), `internal/db` workbench-delete test (PROJ-02 strengthening)

**Interfaces:**
- Consumes: `automations.NewIndexer`, `(*Indexer).RescanFolder(ctx, Scope{Kind: ScopeWorkbench, WorkbenchID: id}, WorkbenchDir(folder))`, `(*Indexer).Changed(dir)`, `WorkbenchDir`, `fsutil.PrivacyProtected`, the projects list (`db` workbench list query — reuse the one `workbench list` uses), config `workbench.default_agent`.
- Produces:
  - `func NewWorkbenchResolver(d *db.DB, defaultAgent func() string, protected func(string) bool) WorkbenchResolver` — implements P1's `WorkbenchResolver` / `WorkbenchInfo{ID, Folder, Protected, DefaultAgent}`; set as `Backends.Workbench` (header note 3).
  - Scheduler: each tick, for every workbench whose folder is not protected, `Changed(WorkbenchDir(folder))` → `RescanFolder`; a protected folder is skipped before any filesystem call (its rows stay as the Desktop indexed them); a missing folder is skipped quietly.
  - Executor: `FinishAutomationRunStep`/`FinishAutomationRun` returning not-found / `ErrRunNotActive` for a run deleted by a cascade ends that run's goroutine without logging an error per poll.
- Depends on: Task 2.

- [ ] **Step 1: Failing tests:**
  - `TestRescan_WorkbenchRecipeNeedsConfirmation` — workbench folder with `release.md` → indexed `scope='workbench'`, `project_id` set, not runnable, in `NeedConfirmation`; confirm + enable; a "git pull" rewrites the script → not runnable again; a description-only change stays runnable (D5).
  - `TestApprovalHash_WorkbenchScopeDiffersPerWorkbench` — the same file in workbench 1 and 2 → different `approval_hash`.
  - `TestRecipe_RejectsWorkbenchKey` (D15, P1) stays green — referenced, not rewritten.
  - `TestScheduler_RescansUnprotectedWorkbenches` — fake clock, recipe added → indexed on the next tick.
  - `TestScheduler_NeverStatsProtectedWorkbench` — protected predicate true for workbench 2; a counting filesystem seam on the indexer (`Changed`/`RescanFolder` recorder) shows zero calls for its folder across ticks.
  - `TestWorkbenchDelete_MidRunExecutorDropsRun` — a run blocked in a FakeGenerator call; delete the workbench (cascade); release the call → the goroutine ends, no panic, `Executor.Wait()` returns.
  - `TestProj02_DeleteRemovesAutomationRows` — after a workbench delete no `automations`/`automation_runs`/`owner_asks` row of it remains; the recipe files in the folder are untouched (they are the owner's repo files).
- [ ] **Step 2:** `go test ./internal/automations -run 'TestRescan_Workbench|TestApprovalHash_Workbench|TestScheduler_(Rescans|NeverStats)|TestWorkbenchDelete'`, `go test ./internal/db -run TestProj02_DeleteRemovesAutomationRows` → FAIL.
- [ ] **Step 3:** Implement and wire.
- [ ] **Step 4:** Step 2 commands → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): index workbench recipes and resolve workbenches`.

### Task 4: `shell(cmd)` (AUTO-13)

**Files:**
- Create: `internal/automations/sdk_shell.go`, `internal/automations/shell_runner.go`, `internal/automations/sdk_shell_test.go`, `internal/automations/automationstest/shell.go`
- Modify: `internal/automations/modules.go` (`DefaultModules` appends `ShellModule`), `docs/inventory/automations.md` (AUTO-13 → **Enforced** with this task's guards; AUTO-12 gains the shell half guard)

**Interfaces:**
- Consumes: `(*Manifest).AllowShell(cmd)`, `Env{Ctx, Run, Automation, DryRun, Journal, Meter}`, `(*Meter).Deadline()`, `SDKError{Name: ErrNameNotAvailable|ErrNamePermissionDenied|ErrNameValidation}`, `Backends.Workbench`, `RunEnvMarker`, `MaxSDKResultBytes` (P1 `limits.go`).
- Produces:
  - `func NewProcessShellRunner() ShellRunner` — implements P1's `ShellRunner` over P1's `ShellCommand`/`ShellResult` (`/bin/sh -c`, `Setpgid`, on ctx done or deadline `kill(-pgid, SIGKILL)` then `Wait`; tails kept at `MaxShellStreamBytes = 256 << 10` each, `StdoutTruncated`/`StderrTruncated` set); set as `Backends.Shell`. A nil `Backends.Shell` (P1–P4 wiring) → `shell()` throws `NotAvailable`.
  - `func ShellModule(b Backends) Module` — JS `shell(cmd)` → `{exit_code, stdout, stderr, truncated?}`. Order of checks: non-string or empty `cmd` → `ValidationError`; personal recipe → `PermissionDenied` (the manifest of a personal recipe cannot hold `shell:`); `AllowShell` miss → `PermissionDenied` with `needed: "shell:\"<cmd>\""`; dry run → `{status:"dry_run"}`, step `dry_run`, no process; workbench folder protected → `NotAvailable` with the exact D9 message, no process; folder missing → `NotAvailable` "the workbench folder is missing"; then run with `Env = [PATH, HOME, LANG, USER from the daemon's environment (absent ones omitted), WATCHTOWER_AUTOMATION_RUN_ID=<run id>]`.
  - A non-zero exit is a result, not an error (`exit_code` set).
  - **Oversized output is truncated, never a failure (owner decision, ask #272 — spec §13.2, §20.1 D19; replaces the former R-P5-1, which threw `ResultTooLarge`).** After the runner's per-stream 256 KiB tails, `ShellModule` measures the serialised result; when it exceeds the SDK result limit (P1's `MaxSDKResultBytes`, 256 KiB, §4) it cuts both tails further — each stream keeps at most half of the room left after the envelope, a shorter stream's unused share goes to the other, cuts keep the tail on a UTF-8 boundary — and re-measures until it fits (JSON escaping counted). The result carries `truncated: true` whenever either stream was cut (by the runner or here); the step row's `result_summary` names `exit_code` and which stream was cut. `shell()` never throws `ResultTooLarge`, so the generic SDK-boundary size check of P1 never trips on it; no P1 seam changes.
- Depends on: Task 3.

- [ ] **Step 1: Failing tests** (real `/bin/sh` in `t.TempDir()` folders; every test reaps its group in `t.Cleanup`):
  - `TestAuto13_ShellExactCommandInWorkbenchFolder` — manifest `shell:"pwd"`, `shell("pwd")` → stdout = the folder; `shell("pwd ")`, `shell(" pwd")`, `shell("pwd && id")` → `PermissionDenied`, no process (FakeShell records 0 calls).
  - `TestAuto13_ShellRefusedInPersonalRecipe` — a personal recipe with `shell:"x"` fails `ParseRecipe` (D7 rule, P1); a personal recipe calling `shell("x")` → `PermissionDenied`, no process.
  - `TestShell_RefusedInProtectedFolder` — resolver `Protected: true` → `NotAvailable`, message exactly "this workbench is in a protected folder; use session() or move the folder", FakeShell 0 calls, the folder never stat'ed (counting resolver).
  - `TestShell_EnvHasRunMarkerAndNoSecrets` — daemon env seeded with `SLACK_TOKEN=x`, `WATCHTOWER_TERMINAL_SESSION_ID=5`, `CLAUDECODE=1` → child `env` output has exactly `PATH`, `HOME`, `LANG`, `USER`, `WATCHTOWER_AUTOMATION_RUN_ID=<run>` (plus what `/bin/sh` itself sets: `PWD`, `SHLVL`, `_` — listed explicitly in the test).
  - `TestShell_KillsProcessGroupOnInterrupt` — `shell("sleep 30 & sleep 30; wait")`, cancel the run → both sleeps gone (`kill(-pgid, 0)` → ESRCH) within 2 s; run `cancelled`.
  - `TestShell_TimeoutIsRemainingActiveBudget` — budget 1 minute with 59 s already active (fake meter) → deadline ≈ 1 s; `sleep 5` killed, run `timed_out`.
  - `TestShell_OutputTailCappedAt256KiB` — 300 KiB stdout → last 256 KiB kept, `truncated: true`; stderr independent.
  - `TestShell_OversizedOutputTruncatedNeverFails` (ask #272, D19) — 300 KiB on each stream with `exit 4` → no throw; `exit_code: 4`, `truncated: true`; serialised result ≤ 256 KiB; both `stdout` and `stderr` are tails (end with the last line written); 10 KiB stderr + 400 KiB stdout → stderr kept whole, stdout cut to the remaining room; output of control characters (heavy JSON escaping) still fits; the step `ok` with `result_summary` naming the exit code and the cut streams.
  - `TestShell_NonZeroExitIsAResult` — `exit 3` → `{exit_code: 3}`, no throw.
  - `TestShell_DryRunStartsNoProcess`.
- [ ] **Step 2:** `go test ./internal/automations -run 'TestAuto13|TestShell_'` → FAIL.
- [ ] **Step 3:** Implement; update the inventory (AUTO-13 Enforced, guards listed).
- [ ] **Step 4:** Step 2 command → PASS; `go test -race ./internal/automations -run TestShell_KillsProcessGroupOnInterrupt` once.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): shell() with exact commands (AUTO-13)`.

### Task 5: `session()` and the attach/end CLI

**Files:**
- Create: `internal/automations/sdk_session.go`, `internal/automations/sdk_session_test.go`, `cmd/automations_session.go`, `cmd/automations_session_test.go`, `internal/db/automation_session_steps.go`, `internal/db/automation_session_steps_test.go`
- Modify: `internal/automations/modules.go` (append `SessionModule`)

**Interfaces:**
- Consumes: `(*Manifest).AllowCapability("session", "start", kind)`, `Env`, `(*Journal).Begin` + header note 2 (`(*Step).ID()`, `(*Step).Mark("waiting", db.StepFinish{})`), `Waiter.Wait(ctx, reason, ready)` with `db.WaitApp` / `db.WaitSession` and header note 1, `db.SetAutomationRunWaiting`, `Backends.Workbench` (`DefaultAgent`), `wakeAutomations(cfg)`, `RunEnvMarker`.
- Produces:
  - `func SessionModule(b Backends) Module` — JS `session({prompt, agent?, title?, wait?})`. Validation (`ValidationError`): `prompt` 1–16384 bytes, `title` ≤ 80 runes, `agent` ∈ `claude|codex`, `wait` ∈ `finish|none` (default `finish`) — my ruling R-P5-2 (the spec gives no bounds). `agent` absent → the workbench's `default_agent`, resolved before the permission check so `session:start@codex` admits only codex. Personal → `PermissionDenied`. Dry run → `{status:"dry_run"}`, no step in `waiting`, nothing for the Desktop. Otherwise: step `kind='session'`, args `{prompt, agent, title}` (title already formatted `⚙ <title or automation name> · run #<run id>`), `Mark("waiting", db.StepFinish{})`, `Wait(ctx, db.WaitApp, readyLaunched)`; when the step has a `session_id`, `SetAutomationRunWaiting(run, db.WaitSession)`; `wait:"none"` → finish the step `ok`, return `{session_id}`; else keep waiting with `readyEnded` and return `{session_id, status, summary, error?}`.
  - `readyEnded` order: row gone → `deleted`; `finished_at` set → `finished` + `finish_summary`; `agent_failed_at` set → `error` + `agent_error`; step closed by the Desktop with `stopped` → `stopped`. **My ruling R-P5-3:** "Stopped (process gone while not finished)" is the Desktop's call — only it owns the process — reported through `session-ended`; it is not PROJ-11's idle "Stopped" (a turn that ended without `finish_session` keeps the run waiting). A launch the Desktop could not make (folder gone, codex not found) is reported the same way with `--status launch_failed` and throws `NotAvailable` with the Desktop's reason into the script (R-P5-4).
  - `package db`: `func AttachAutomationSessionStep(stepID, sessionID int64) (attached bool, err error)` — conditional: step `kind='session'`, `status='waiting'`, `session_id IS NULL`, its run `waiting` with `waiting_reason='app'`, and the session row's `automation_run_id` = the step's run; `func EndAutomationSessionStep(stepID int64, status, errText string, now time.Time) (bool, error)` — conditional on `status='waiting'` (`status` ∈ `stopped|launch_failed`); `func PendingAutomationSessionSteps() ([]PendingSessionStep, error)` (for tests and the CLI's own checks).
  - CLI (open under agent markers: they only report what the Desktop did; the run's own permissions were confirmed by the owner): `automations session-launched --step S --session R [--json]` → `{"attached": bool}` then `SIGUSR2`; `automations session-ended --step S --status stopped|launch_failed [--error TEXT] [--json]` → `{"ended": bool}` then `SIGUSR2`.
- Depends on: Tasks 1, 3.

- [ ] **Step 1: Failing tests:**
  - `TestSession_WaitsForAppThenSessionThenFinish` — step `waiting`, run `waiting`/`app`; `session-launched` → `attached`, run `waiting`/`session` (no `running` blip: active time unchanged); set `finished_at` + `finish_summary` → script gets `{status:"finished", summary}`, step `ok` with `session_id`.
  - `TestSession_ErrorDeletedStopped` — table: `agent_failed_at` → `error` with `agent_error`; row deleted → `deleted`; `session-ended --status stopped` → `stopped`.
  - `TestSession_LaunchFailedThrowsNotAvailable` — `session-ended --status launch_failed --error "Codex was not found"` → JS `NotAvailable` with that message.
  - `TestSession_WaitNoneReturnsAfterLaunch` — `{session_id}` returned right after attach; the run continues.
  - `TestSession_AgentDefaultAndPermission` — default agent codex + manifest `session:start@claude` → `PermissionDenied` needed `session:start@codex`; `session:start` admits both.
  - `TestSession_PersonalRecipeDenied`; `TestSession_Validation` (empty prompt, 16385-byte prompt, 81-rune title, `agent:"x"`, `wait:"later"`).
  - `TestSession_PauseExcludedFromActiveTime` — 2 h waiting does not consume the 5-minute budget.
  - `TestSession_PauseTimeoutExpires` — fake clock past `pause_timeout_hours` while waiting `app` → run `expired`, step closed `error`.
  - `TestSessionAttach_IsConditional` — two attaches of the same step (different rows) → exactly one `true`; attach to a run that is `cancelled` → `false`; a session row whose `automation_run_id` is another run → `false`.
  - `TestSessionEnded_OnlyFromWaiting` — ending an `ok` step → `false`.
  - CLI: `TestAutomationsCLI_SessionLaunchedWakesDaemon` (wake seam called once), `TestAutomationsCLI_SessionCommandsJSON`.
- [ ] **Step 2:** `go test ./internal/automations -run TestSession_`, `go test ./internal/db -run 'TestSessionAttach|TestSessionEnded'`, `go test ./cmd -run 'TestAutomationsCLI_Session'` → FAIL.
- [ ] **Step 3:** Implement (after the header-note-1/2 seams are in P1's package).
- [ ] **Step 4:** Step 2 commands → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): visible session() with Desktop attach`.

### Task 6: `ask()` and keeping automation asks out of sessions

**Files:**
- Create: `internal/automations/sdk_ask.go`, `internal/automations/sdk_ask_test.go`, `internal/db/owner_asks_automation_test.go`
- Modify: `internal/automations/modules.go` (append `AskModule`), `internal/automations/executor.go` (sweep), `internal/db/owner_asks.go` (exclusions), `internal/tools/workbench_asks.go` (`list_asks`, `get_ask`, `withdraw_ask`), `cmd/workbench_askguard_stop.go` (or the reader it uses), `cmd/automations.go` (`delete` withdraws open asks first), `docs/inventory/workbench.md` (PROJ-12/PROJ-13 strengthening changelog lines)

**Interfaces:**
- Consumes: `asks.Payload`, `asks.Level(kind, payload, origin)`, `asks.OriginAgent`, `asks.MaxOpenPerWorkbench`, `db.InsertOwnerAsk` (+ `AutomationRunID`), `db.GetOwnerAsk`, `db.MarkOwnerAskDelivered`, `db.WithdrawOwnerAsk(workbenchID, id, "agent")`, `db.ErrTooManyOpenAsks`, `Waiter.Wait(ctx, db.WaitAsk, ready)`.
- Produces:
  - `func AskModule(b Backends) Module` — JS `ask({kind, title, summary?, questions?, checklist?})`. `kind` ∈ `check|question` — **my ruling R-P5-5:** `review` is refused (`ValidationError`) because a review ask needs a document path and a session to re-round it. Payload validated by the `ask_owner` rules (`asks.Payload`). Personal → `PermissionDenied` (manifest). Dry run → `{status:"dry_run"}`, no row. Insert in one tx (`project_id` = the automation's workbench, `session_id` NULL, `automation_run_id`, `origin='agent'`, `level = asks.Level(...)`); cap reached → `ToolError` "this workbench has 30 open asks; answer some first". Step `kind='ask'`, `Mark("waiting", db.StepFinish{AskID: <ask id>})`; on `answered` → `MarkOwnerAskDelivered`, return the parsed answer JSON; Wait ends by cancel or expiry → `WithdrawOwnerAsk(…, "agent")`, then the Waiter's error.
  - Executor sweep (every poll and at start, after `MarkInterruptedAutomationRuns`): an `open` ask whose `automation_run_id` names a run in a terminal status is withdrawn (`agent`) — covers a daemon restart (D6) and a cancel racing the insert.
  - Session-side readers exclude `automation_run_id IS NOT NULL`: `AnsweredAsksForBrief` (both the list and the "others" count via `answeredForSessionPredicate`), `RecentOpenQuestionAsk`, `LastWithdrawnByTitle`, `list_asks`, `get_ask` (an automation ask reads as "no ask #N"), `withdraw_ask` (refused as not found), the Stop ask guard's open-ask reader. Owner-facing readers keep them: the Waiting-for-you stack, `CountOpenOwnerAsks` (the cap is per workbench), badges, the mobile asks slice.
  - `automations delete <id>` withdraws its runs' open asks before the row goes (the FK would otherwise leave an orphan open ask with no run and no session — my ruling R-P5-6).
- Depends on: Task 1.

- [ ] **Step 1: Failing tests:**
  - `TestAsk_WaitsAndDelivers` — row created with `automation_run_id`, `session_id` NULL, `origin='agent'`, level from `asks.Level`; run `waiting`/`ask`; Desktop-style answer write (`status='answered'`, `answer`) → script gets the answer object, ask `delivered`, step `ok` with `ask_id`.
  - `TestAsk_CancelWithdraws` / `TestAsk_ExpiryWithdraws` — `withdrawn`, `withdrawn_reason='agent'`.
  - `TestAsk_ReviewKindRefused`; `TestAsk_PersonalDenied`; `TestAsk_CapReachedIsToolError` (30 open → `ToolError`, no row).
  - `TestAsk_DryRunCreatesNoRow`.
  - `TestAutomationAsks_InvisibleToSessionReaders` — one answered automation ask + one answered external-terminal ask (`session_id` NULL, no run): `AnsweredAsksForBrief` returns only the external one; `list_asks`/`get_ask`/`withdraw_ask` on a workbench binding do not see / refuse the automation ask; the ask-guard reader counts 0 for it.
  - `TestExecutorSweep_WithdrawsAsksOfTerminalRuns` — restart with an open automation ask of a `running` run → run `failed`/`interrupted`, ask `withdrawn`.
  - `TestAutomationsCLI_DeleteWithdrawsOpenAsks`.
- [ ] **Step 2:** `go test ./internal/automations -run 'TestAsk_|TestExecutorSweep'`, `go test ./internal/db -run TestAutomationAsks`, `go test ./internal/tools -run TestAutomationAsks`, `go test ./cmd -run 'TestAutomationsCLI_DeleteWithdraws|TestAskGuard'` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 commands and `go test ./internal/db ./internal/tools` → PASS (every existing PROJ-12/PROJ-13 guard green unmodified).
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): ask() for workbench automations`.

### Task 7: Workbench recipes end to end — PR review rounds, Release / Deploy (AUTO-12 P5 half)

**Files:**
- Create: `internal/automations/testdata/workbench/{pr-review-rounds.md,release.md,deploy-test.md,deploy-stage.md}`, `internal/automations/automationstest/sessiondesk.go`, `internal/automations/workbench_e2e_test.go`
- Modify: `docs/inventory/automations.md` (AUTO-12 → **Enforced** in full, P5 half guard listed)

**Interfaces:**
- Consumes: Tasks 4–6; `automationstest.FakeGenerator`, `FakeClock`, `SeedAutomation`.
- Produces:
  - `type FakeShell struct { Results map[string]ShellResult; Calls []ShellCommand }` (implements `ShellRunner`); `type FakeSessionDesk struct{…}` — plays the Desktop: polls `PendingAutomationSessionSteps`, attaches a fake `terminal_sessions` row, then sets `finished_at`/`finish_summary` (or `agent_failed_at`, or ends `stopped`) per test script.
  - `pr-review-rounds.md` (spec §15 #2): `trigger.schedule "0 10,16 * * 1-5"`; permissions `shell:"gh pr list --state open --json number,title,url,author,updatedAt"`, `session:start`, `llm:light`; `outputs: [report]`; script: run the exact `gh` command, keep PRs whose `updatedAt` is after `state.get("last_round")`, for each one `session({prompt, title: "PR #<n> review"})` whose prompt tells the agent to review the PR, file every finding as an `ask_owner` ask, post on the PR only the comments the owner approves in those answers and only after the answers (`gh pr review` / `gh pr comment` in its own terminal — D13, no registry PR tool), then call `finish_session`; then `state.set("last_round", <now>)` and `output.report` listing the PRs and each session's status.
  - `release.md`, `deploy-test.md`, `deploy-stage.md` (spec §15 #5): `trigger.button {label: "Release"|"Deploy to test"|"Deploy to stage", confirm: true}`; `shell:"make release"` / `shell:"make deploy-test"` / `shell:"make deploy-stage"` (placeholders the owner edits), `session:start`; `outputs: [report]`; script: run the command; non-zero exit → `output.report` with the tail and `throw` (run `failed`); success → one `session({prompt: "Check that <target> is healthy …", wait: "finish"})` follow-up check → `output.report` with the command tail and the session summary.
- Depends on: Tasks 4, 5, 6.

- [ ] **Step 1: Failing tests:**
  - `TestWorkbenchRecipes_AllParseAndConfirm` — the four parse as `ScopeWorkbench`; none parses as personal (each declares `shell:`/`session:`).
  - `TestPRReviewRounds_E2E` — FakeShell returns 3 PRs, 2 updated after `last_round` → exactly 2 session steps in order, FakeSessionDesk finishes both → run `succeeded`, `last_round` advanced, one `report` output naming PR numbers and "finished"; the session prompt contains "ask_owner" and "after".
  - `TestPRReviewRounds_NoUpdatedPRsStartsNoSession`.
  - `TestRelease_E2E` — exit 0 → follow-up session → `succeeded` with report; exit 2 → no session, run `failed`, report holds the stderr tail.
  - `TestRelease_ButtonTriggerConfirmTrue` — parsed trigger `button{label:"Release", confirm:true}`.
  - `TestAuto12_DryRunStartsNoSessionOrShell` — dry run of each recipe: FakeShell 0 calls, no `waiting` session step, no `owner_asks` row, steps `dry_run`.
- [ ] **Step 2:** `go test ./internal/automations -run 'TestWorkbenchRecipes|TestPRReviewRounds|TestRelease_|TestAuto12_DryRunStartsNoSessionOrShell'` → FAIL.
- [ ] **Step 3:** Write the recipes and the fake desk.
- [ ] **Step 4:** Step 2 command → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `test(automations): workbench recipes end to end (AUTO-12)`.

### Task 8: Workbench saves — lift R-P3-5, PROJ-03 amendment (owner-approved, ask #272)

**Files:**
- Modify: `internal/automations/authoring/save.go` (+ tests), `cmd/automations.go` (`save --path` for a workbench folder checks the path is `WorkbenchDir(folder)/<slug>.md` of a known workbench), `docs/inventory/workbench.md` (PROJ-03 amendment text of spec §14.6, Status line "amended <merge date> — Watchtower writes automation recipes in `.watchtower/automations/` only on the owner's Save or Approve, owner approved in ask #272", changelog entry, new guards listed)

**Interfaces:**
- Consumes: `authoring.Deps.Backends().Workbench` (P1's `WorkbenchResolver`, implemented in Task 3 and now wired into `buildToolRegistry`'s `Deps`), `WorkbenchDir`, `(*Indexer).RescanFolder`, `fsutil.WriteFileAtomic`.
- Produces: `save_automation` with `workbench_id` → `path = WorkbenchDir(folder)/<slug>.md`, scope `workbench:<id>`, `Execute` writes there (creating `.watchtower/automations/` 0755 when absent), rescans that folder, confirms. A protected folder is fine here: `Execute` runs in the owner's `actions apply` process (the Desktop's CLI child), never the daemon. PROJ-03 amendment (spec §14.6, owner-approved in ask #272): "Watchtower writes one more kind of file in the workbench folder: automation recipes, only at `<folder>/.watchtower/automations/<slug>.md`, only on the owner's Save (the Automations form/Monaco save through `automations save --confirm-hash`) or on the owner's Approve of a `save_automation` card, each refusing to overwrite a file whose content changed since the owner saw it (`--expect-content-hash`, the pinned `existing_content_hash`); `automations delete` removes only such a file; the write is atomic (`fsutil.WriteFileAtomic`); no other path of the folder is written, no workbench MCP tool writes a recipe, and the daemon never writes the folder."
- **Approval recorded:** the amendment widens a locked contract and the owner approved it in ask #272; this task writes the amendment into `docs/inventory/workbench.md` in the same commit as the code, and Task 12's form is editable for workbench rows.
- Depends on: Task 3; P3 Task 2.

- [ ] **Step 1: Failing tests:** `TestSaveAutomation_WorkbenchWritesIntoItsFolder`; `TestSaveAutomation_WorkbenchUnknownRefused`; `TestAutomationsCLI_SavePathOutsideWorkbenchAutomationsRefused` (`--path <folder>/src/x.md` → refused); every existing PROJ-03 guard (`TestProj03_AskOwnerNeverWritesTheFolder` and the code-viewer guards) stays green unmodified.
- [ ] **Step 2:** `go test ./internal/automations/authoring -run TestSaveAutomation_Workbench`, `go test ./cmd -run TestAutomationsCLI_SavePath` → FAIL.
- [ ] **Step 3:** Implement; write the amendment text.
- [ ] **Step 4:** Step 2 commands → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): save workbench recipes (PROJ-03 amended, ask #272)`.

### Task 9: Swift Core — queries, run marker on sessions, session start with a run — **Heavy Swift — serial**

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/AutomationQueries.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/TerminalLaunch.swift`, `WatchtowerDesktop/Sources/Services/TerminalCenter.swift` (marker from the row on every launch, resume included), `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+Sessions.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationsCLI.swift`
- Create: `WatchtowerDesktop/Tests/Core/{AutomationWorkbenchQueriesTests,TerminalLaunchAutomationMarkerTests}.swift`

**Interfaces:**
- Consumes: Task 1 columns, Task 5 CLI.
- Produces:
  - `struct PendingSessionRequest: Equatable, Sendable { stepID, runID, automationID, projectID: Int64; automationName, prompt, title: String; agent: AgentKind }`; `AutomationQueries.fetchPendingSessionRequests(_ db: Database) throws -> [PendingSessionRequest]` (step `kind='session'`, `status='waiting'`, `session_id IS NULL`; run `waiting`/`app`; automation `scope='workbench'`); `AutomationQueries.unattachedSession(_ db: Database, runID: Int64) throws -> TerminalSession?` (a row with that `automation_run_id` no step names — the crash-adoption case); `AutomationQueries.waitingSessionSteps(_ db: Database) throws -> [(stepID: Int64, sessionID: Int64)]`; `AutomationQueries.headerButtons(_ db: Database, projectID: Int64) throws -> [AutomationHeaderButton]` (`AutomationHeaderButton { automationID; slug; label; confirm: Bool; state: .runnable | .needsConfirmation | .disabled | .parseError; activeRunID: Int64? }`, every non-removed `trigger_kind='button'` row of the workbench, slug order); `AutomationQueries.askLabels(_ db: Database, askIDs: [Int64]) throws -> [Int64: String]` (`"⚙ <name> · run #<n>"`).
  - `TerminalLaunch.make(..., automationRunID: Int64? = nil)` appends `WATCHTOWER_AUTOMATION_RUN_ID=<id>` for an agent launch (new and resume) when set; `TerminalCenter` passes `row.automationRunID`.
  - `WorkbenchesViewModel.startAutomationSession(_ r: PendingSessionRequest) async throws -> TerminalSession` — `TerminalSessionQueries.create` with `automationRunID: r.runID`, title `r.title`, agent `r.agent`; `prompt: r.prompt` (the existing first-message path, `WATCHTOWER_FIRST_PROMPT`); placement `.background` (my ruling R-P5-7: the session appears in SESSIONS without taking the page from the owner); throws on a refused launch (`launchCheck`).
  - `AutomationsCLI.sessionLaunched(step:session:) async throws -> Bool`, `sessionEnded(step:status:error:) async throws -> Bool`, `rescan(workbenchID:) async throws`.
- Depends on: Tasks 1, 5.

- [ ] **Step 1: Failing tests:** `testPendingRequestsOnlyWaitingAppWorkbenchSteps` (attached, `ok`, run `session`, personal → excluded); `testUnattachedSessionForRun`; `testHeaderButtonsStatesAndSlugOrder` (runnable / unconfirmed / disabled / parse error / removed excluded / active run id); `testAskLabels`; `TerminalLaunchAutomationMarkerTests.testNewAgentLaunchCarriesRunMarker`, `testResumeCarriesRunMarker`, `testNoMarkerWithoutRun`, `testShellLaunchNeverCarriesMarker`; `AutomationsCLITests.testSessionLaunchedArgs` → `["automations","session-launched","--step","9","--session","4","--json"]`, `testSessionEndedArgs`, `testRescanWorkbenchArgs`.
- [ ] **Step 2:** `make test-swift FILTER='AutomationWorkbenchQueriesTests|TerminalLaunchAutomationMarkerTests|AutomationsCLITests'` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 command → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): Desktop queries and the run marker on sessions`.

### Task 10: `AutomationSessionCenter` — **Heavy Swift — serial**

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/AutomationSessionCenter.swift`, `WatchtowerDesktop/Tests/AutomationSessionCenterTests.swift`
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (construct after `initWorkbenches`, start/stop with the feature, stop in quit), `WatchtowerDesktop/Sources/Services/TerminalCenter.swift` (exit callback exposes the row id)

**Interfaces:**
- Consumes: Task 9; `TerminalCenter` (live rows, exit events); the `automations` feature state.
- Produces: `@MainActor @Observable final class AutomationSessionCenter { private(set) var launching: Set<Int64>; private(set) var lastError: String?; init(dbPool: DatabasePool, cli: AutomationsCLI, start: @escaping (PendingSessionRequest) async throws -> TerminalSession, isLive: @escaping (Int64) -> Bool, sleep: @escaping (Duration) async -> Void); func start(); func stop(); func tick() async /* test seam */; func sessionExited(rowID: Int64) async }`.
  - Each tick (every 3 s while the app runs and the feature is on — my ruling R-P5-8): for each pending request not in `launching`: if `unattachedSession(runID)` exists → attach it (crash adoption), else `start(request)` → `sessionLaunched(step, session)`; a thrown launch → `sessionEnded(step, launch_failed, error: <message>)`. `attached == false` (run cancelled/expired meanwhile) → the session is left as is (§7.6).
  - Stopped: `sessionExited(rowID)` for a row whose step is still waiting, not finished and not failed → `sessionEnded(step, stopped)`. On `start()` (app launch) every waiting session step whose session is not live → `stopped` (reconcile; R-P5-3).
  - Feature off → no ticks; requests stay pending until it is on again (the run waits, bounded by `pause_timeout_hours`).
- Depends on: Task 9.

- [ ] **Step 1: Failing tests** (fake `start`, fake runner, file `TestDatabase`):
  - `testLaunchOnRequestWritesSessionIDAndWakes` — one request → `start` once, `session-launched` once with the new row id (the CLI wakes the daemon).
  - `testOneLaunchPerRequestUnderRepeatedPolls` — `start` suspended; three ticks → one `start`.
  - `testCrashBetweenCreateAndAttachAdoptsTheRow` — a row with `automation_run_id` and no attach → tick attaches it, `start` never called.
  - `testAppLaunchedLaterPicksPendingRequest` — request inserted before `start()` → handled on the first tick.
  - `testLaunchFailureReportsLaunchFailed` — `start` throws "Codex was not found" → `session-ended --status launch_failed --error "Codex was not found"`.
  - `testExitWhileWaitingReportsStopped`; `testExitAfterFinishReportsNothing`.
  - `testReconcileOnStartReportsStoppedForDeadSessions`.
  - `testAttachRefusedLeavesSessionAlone` (`attached:false` → no delete, no second launch).
  - `testFeatureOffDoesNothing`.
  - `testRequestSurvivesNavigation` — the workbench page closed/reopened mid-launch → the center (AppState) finishes the attach.
- [ ] **Step 2:** `make test-swift FILTER=AutomationSessionCenterTests` → FAIL.
- [ ] **Step 3:** Implement and wire.
- [ ] **Step 4:** Step 2 command → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): AutomationSessionCenter launches requested sessions`.

### Task 11: Header buttons (AUTO-09 Desktop guard) — **Heavy Swift — serial**

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchAutomationButtons.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/WorkbenchAutomationButtonsModel.swift`, `WatchtowerDesktop/Tests/Core/WorkbenchHeaderAutomationButtonsTests.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchHeaderControls.swift` (buttons before the view segment), `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationsViewModel.swift` (`headerButtons(projectID:)`, reloaded on its poll), `docs/inventory/automations.md` (AUTO-09 guard list gains `testAuto09_HeaderButtonOnlyQueues`)

**Interfaces:**
- Consumes: Task 9 `headerButtons`; P3 `AutomationsViewModel.runNow(_:)`, `AutomationConfirmSheet`, `AppState.openAutomationRun(automationID:runID:)`.
- Produces: `struct WorkbenchAutomationButtonsModel { static func layout(_ buttons: [AutomationHeaderButton], maxVisible: Int = 4) -> (visible: [AutomationHeaderButton], overflow: [AutomationHeaderButton]); static func action(for b: AutomationHeaderButton) -> Action }`, `enum Action: Equatable { case confirmThenRun(label: String), run, openRun(Int64), openConfirmSheet, openCard }` — runnable + `confirm` → dialog "Run <label>?" (buttons "Run" / "Cancel"); runnable → run; active run → spinner + `openRun`; needs confirmation → disabled look, help "Needs your confirmation", click `openConfirmSheet` (P3 sheet, "Confirm and enable" for a disabled recipe); disabled or parse error → disabled look, help "Disabled" / "Parse error", click `openCard`. Overflow menu titled "More" lists the rest with the same actions. Hidden when the `automations` feature is off.
- Depends on: Task 9; P3 Tasks 7, 10.

- [ ] **Step 1: Failing tests:** `testRunnableStatesAndActions` (table over the five states); `testConfirmTrueAsksFirst`; `testMaxFourVisibleRestInOverflowSlugOrder` (six buttons → four + two, slug order); `testActiveRunShowsSpinnerAndOpensRun`; `testAuto09_HeaderButtonOnlyQueues` (a click on a runnable button issues exactly `["automations","run","<id>","--json"]` and nothing else — no generator, no shell, no DB write from Swift); `testHiddenWhenFeatureOff`; `testRunSurvivesNavigation` (click, leave the workbench, come back → spinner from the active run).
- [ ] **Step 2:** `make test-swift FILTER=WorkbenchHeaderAutomationButtonsTests` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 command → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): automation buttons in the workbench header`.

### Task 12: Asks, rescans and the card links in the Desktop — **Heavy Swift — serial**

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/OwnerAsksViewModel.swift` (automation asks: label, wake after a saved answer, never delivered to a terminal), `WatchtowerDesktop/Sources/Views/Workbench/Asks/*` (the label in place of the session name), `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel.swift` (`automations rescan --workbench N` on page open; on `FolderWatcher` batches touching `.watchtower/automations/`, debounced 1 s), `WatchtowerDesktop/Sources/ViewModels/CodeFilesCenter.swift` (forward those paths), P3 `AutomationCardView`/`AutomationStepRow` (`session_id` → opens the session, `ask_id` → opens the ask), P3 `AutomationFormModel.isEditable` (true for workbench rows — Task 8's PROJ-03 amendment, approved in ask #272)
- Create: `WatchtowerDesktop/Tests/{OwnerAsksAutomationTests,WorkbenchAutomationRescanTests}.swift`

**Interfaces:**
- Consumes: Tasks 1, 8, 9; `AutomationsCLI.wake()`, `rescan(workbenchID:)`.
- Produces: an automation ask in the Waiting-for-you stack reads "⚙ <automation> · run #N" where a session ask names its session; answering writes `open → answered` exactly as today, then `wake()` (best effort, logged); `deliverHeldAnswers` and the immediate delivery skip asks with `automationRunID != nil`. **My ruling R-P5-9:** the Desktop runs `rescan --workbench N` for every workbench page it opens, not only protected ones — it is harmless for an unprotected folder and avoids a second Swift copy of the protected-folder list (`WorkbenchFolderPolicy.tccSensitiveLocations` differs from Go's).
- Depends on: Tasks 8 (for the form flag), 9.

- [ ] **Step 1: Failing tests:** `OwnerAsksAutomationTests`: `testAutomationAskShowsAutomationLabel`; `testAnswerWakesAutomations` (answer saved → `wake` once; a failed answer write → no wake); `testAutomationAskIsNeverDeliveredToATerminal` (a live session in the workbench, the automation ask answered → no line typed, no `deliverHeldAnswers` entry); `testSessionAskDeliveryUnchanged`. `WorkbenchAutomationRescanTests`: `testRescanOnPageOpen`; `testRescanOnRecipeFolderChangeDebounced` (three batches in 300 ms → one rescan); `testNoRescanForOtherPaths`; `testRescanSurvivesNavigation`.
- [ ] **Step 2:** `make test-swift FILTER='OwnerAsksAutomationTests|WorkbenchAutomationRescanTests'` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Step 2 command, plus `make test-swift FILTER='OwnerAsksViewModelTests'` (existing PROJ-12 guards) → PASS.
- [ ] **Step 5:** `make lint-diff`; commit `feat(automations): automation asks, workbench rescans and run links`.

### Task 13: Docs and contracts

**Files:**
- Modify: `docs/inventory/automations.md` (AUTO-12 and AUTO-13 **Enforced** — confirm Tasks 4/7 did it; AUTO-09 Desktop guard; changelog), `docs/inventory/workbench.md` (PROJ-02 strengthening: automation rows go with the workbench, guard `TestProj02_DeleteRemovesAutomationRows`; PROJ-03 amendment — confirm Task 8 wrote it with "owner approved in ask #272" and its guards; PROJ-12/PROJ-13 changelog: automation asks never reach a session — guards `TestAutomationAsks_InvisibleToSessionReaders`, `testAutomationAskIsNeverDeliveredToATerminal`; PROJ-11 note: a session started by an automation is an ordinary session; its "stopped" for the run is the process ending — R-P5-3), `docs/features/workbench.md` (an Automations paragraph: recipes folder, header buttons, automation sessions and asks), `docs/features/automations.md` (P5 section), `docs/app-guide.md` (Workbench section: header buttons, sessions an automation opens, automation asks; Automations section: workbench recipes and "Needs your confirmation" after a git pull), `CLAUDE.md` (the Automations Feature Notes line gains "P5: workbench recipes, header buttons, session/shell/ask")
- Depends on: Tasks 1–12.

- [ ] **Step 1:** Write the docs.
- [ ] **Step 2:** Every inventory test name greps to a real test.
- [ ] **Step 3:** `git add` then `bash scripts/leak-check.sh --staged` → clean.
- [ ] **Step 4:** Commit `docs(automations): P5 workbench docs and contract updates`.

### Phase gate (controller, once)

- [ ] `bash scripts/dev-health.sh` → not overloaded.
- [ ] `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...` (logs to files, explicit exit codes).
- [ ] PROJ-03 amendment (Task 8) present in `docs/inventory/workbench.md` citing ask #272 (approval already recorded).
- [ ] Manual, in a scratch workbench under `/tmp`-like unprotected path and one under `~/Documents`: add `release.md` by hand → "Needs your confirmation" in the header; confirm and enable; click **Release** → confirm dialog → run; the follow-up session opens in SESSIONS; Finish it → the run succeeds; quit the app while a session is requested → the run waits, relaunch → the session starts; in the protected workbench `shell()` reports the D9 message.
- [ ] local-review, then one PR `feature/automations-p5 → feature/automations`.

---

## Self-review against the spec

- §2.1 workbench folder and slug; §2.5/AUTO-06 git-pulled recipe needs confirmation → Task 3. §13.4 daemon rescans unprotected folders, the Desktop rescans the rest → Tasks 3, 12. D15 location binding → Task 3 (P1 parser guard referenced).
- §12.4 header buttons (slug order, 4 + overflow, confirm dialog, spinner/open run, disabled "Needs your confirmation" → confirm sheet) → Task 11.
- §13.1 `session()` steps 1–4, `WaitApp` → `WaitSession`, resume on Finished/Error/Stopped/deleted, `wait:"none"` → Tasks 5, 9, 10.
- §13.2 `shell()` (exact, cwd, process group, timeout, 256 KiB tails, oversized output truncated never failing — D19, env, D9) → Task 4. §14.6 PROJ-03 amendment (D17, ask #272) → Tasks 8, 13. §13.3 `ask()` (D7, 00117, delivered, withdrawn on cancel/expiry) → Tasks 1, 6.
- §9.5 migration 00117 → Task 1. Env marker on `shell()`/`session()` children → Tasks 4, 9.
- §15 templates 2 (D13: comments through the session) and 5 → Task 7 (fixtures; P6 embeds them, header note 5).
- §18 P5 tests: `TestAuto13_ShellExactCommandInWorkbenchFolder`, `TestAuto13_ShellRefusedInPersonalRecipe`, `TestShell_KillsProcessGroupOnInterrupt`, `TestShell_EnvHasRunMarkerAndNoSecrets`, `TestShell_OutputTailCappedAt256KiB`, `TestShell_OversizedOutputTruncatedNeverFails` (T4); `TestSaveAutomation_WorkbenchWritesIntoItsFolder` (T8); `TestSession_WaitsForAppThenSessionThenFinish` (T5); `TestAsk_WaitsAndDelivers` (T6); `TestAuto12_DryRunStartsNoSessionOrShell` (T7); `TestRescan_WorkbenchRecipeNeedsConfirmation` (T3); migration test for 00117 (T1); `WorkbenchHeaderAutomationButtonsTests` (T11); `AutomationSessionCenterTests` (T10) — all present by those names.
- Inventory: AUTO-13 → Enforced (Task 4); AUTO-12 → Enforced in full (Task 7); AUTO-09 gains the Desktop guard (Task 11; its P4 half stays with P4); PROJ-02/12/13 strengthened, PROJ-03 amended — owner-approved in ask #272 (Tasks 6, 8, 13).

## Rulings made in this plan (mine, not the owner's)

R-P5-1 retired — the owner decided shell output is truncated, never a failure (ask #272, D19); only the fitting rule (half each, unused share to the other stream) is mine; R-P5-2 `session()` argument bounds; R-P5-3 "stopped" = the process ended, reported by the Desktop, reconciled at app launch; R-P5-4 a launch the Desktop could not make throws `NotAvailable`; R-P5-5 `ask()` kinds `check|question` only; R-P5-6 `automations delete` withdraws its open asks first; R-P5-7 automation sessions start in the background placement; R-P5-8 the session center polls every 3 s; R-P5-9 the Desktop rescans every workbench it opens.
