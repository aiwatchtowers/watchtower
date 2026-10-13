# Session cleanup (board #535) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A workbench session removes, before it finishes, the worktrees and local branches it created once they are merged or pushed, its orphan processes and the LaunchServices entries of builds inside those worktrees — never uncommitted, unpushed, in-use or someone else's work — and reports what it removed, the space freed and what it kept and why. The Desktop offers the same on Delete Session, per session, and as a one-time sweep.

**Architecture:** The session-state hook records, per session, each new (worktree root, branch) any of its agents worked in (`terminal_session_worktrees`, reusing #565's `cwd` parse and resolver). `watchtower workbench cleanup` (`internal/sessioncleanup`) plans from that ledger plus linked targets' branches, applies ownership (observed + born after the session) and the PROJ-16 catches, and on `--apply` re-checks and removes with `git worktree remove` (no force) and compare-and-delete `git update-ref -d`. The result is saved in `terminal_sessions.cleanup_result`. Go is the only writer; the Desktop drives the CLI through `SessionCleanupCenter`.

**Tech Stack:** Go 1.25 (`cmd/`, `internal/db`, `internal/sessioncleanup`, `internal/devpack`), SQLite + goose, SwiftUI / GRDB (WatchtowerCore + app target).

**Spec:** `docs/superpowers/specs/2026-10-12-session-cleanup-design.md` (source of truth) and `…-business.md`. Executors read both before their task, and `docs/superpowers/specs/2026-10-12-session-worktree-design.md` (#565) for the `cwd` field and resolver.

**Plan style:** no code bodies — files, interfaces, test cases, verification commands. Task-scope checks only; the full gate runs once, in the final task.

## Global Constraints

- **Depends on #565.** Task 3 needs #565's `sessionStateInput.Cwd` parse and its process-free worktree resolver. If #565 has not merged when Task 3 starts, Task 3 lands the parse and resolver exactly as #565's spec names them (same package, same signature) and #565 rebases onto it — never two resolvers.
- Migration number: next free at implementation time (00109 today; #565 and `feat/399-codex-agent` may take numbers first).
- Never `--force`, never `git branch -D`, never `rm -rf` of a path; worktrees go through `git worktree remove`, branches through `git update-ref -d refs/heads/<b> <sha>`. Never fetch. git only via `internal/gitbin`, never in a folder outside a repository.
- Signals: SIGTERM only, only to orphans as defined in spec §7; the process key carries the start time.
- No TCC prompt (memory rule): Task 0 decides whether `lsof` is used.
- Tests that create repos use `t.TempDir()` with `git init` through `gitbin`; tests that start processes (orphan stubs) kill their process group and wait in `t.Cleanup`, the timeout path included.
- Guard tests named `TestProj16_*` / `testProj16_*` (`TestProj11_*`, `TestProj04_*`, `TestProj02_*` where those are amended); existing guards are never weakened, renamed or split.
- Public repo: no real paths, ids or names in fixtures and docs (`/tmp/...` under `t.TempDir()`, `example`).
- Inner loop only (`go test ./internal/<pkg>`, `go test ./cmd -run '<regex>'`, `make test-swift FILTER=…`, `make lint-diff`); no `-count=1`; logs to a file with `echo "exit=$?"`. Swift tasks (10, 11, 12) one at a time.
- Commits in English, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Every catch re-checked right before its removal**, not only at plan time (spec §7) — `TestProj16_ApplyRechecksAndActsOnlyOnNamedItems`, `TestProj16_BranchThatMovedAfterThePlanIsKept`.
2. **Ownership needs both "observed" and "born after the session"** — `TestProj16_WorktreeOlderThanTheSessionIsKept`, `TestProj16_BranchOlderThanTheSessionIsKept`.
3. **Ledger failure never costs the state write** — `TestProj11_LedgerFailureNeverCostsTheStateWrite`.
4. **The Desktop never deletes the row after a failed cleanup** and applies only the planned keys — `testProj16_FailedCleanupKeepsTheSessionRow`, `testProj16_DeleteAppliesOnlyThePlannedItems`.
5. **Empty-state wire shape** (`items: []`, never `null`) — `TestCleanupJSON_EmptyPlanHasEmptyItems` + the Swift decode test.

## Task list

| # | Title | Depends on |
|---|---|---|
| 0 | Spikes: subagent `cwd`, lsof/TCC, allow rule in auto mode, lsregister, worktree birth time | none |
| 1 | Migration: `terminal_session_worktrees`, `cleanup_result`, `cleanup_at` | none |
| 2 | DB layer: ledger read/insert, cleanup result write | Task 1 |
| 3 | State hook records the ledger (PROJ-11) | Task 2, #565 cwd parse |
| 4 | `internal/sessioncleanup`: inventory, ownership, worktree/branch catches (plan) | Task 2 |
| 5 | Process scan, orphans, sizes, LaunchServices | Task 0 |
| 6 | Apply: re-check, removal order, result | Task 4, Task 5 |
| 7 | CLI `workbench cleanup` (+ sweep) | Task 6 |
| 8 | Install: cleanup permission entry, brief line | Task 0, Task 7 |
| 9 | Skill pack v7 | Task 8 |
| 10 | Swift Core: plan/result models, presentation | Task 7 |
| 11 | Desktop: `SessionCleanupCenter`, Delete dialog, Clean Up… sheet, report line | Task 10 |
| 12 | Desktop: sweep sheet in the header menu (+ hint if approved) | Task 11 |
| 13 | Inventory, feature notes, app guide | Task 9, Task 12 |
| 14 | Final gate | Task 13 |

Parallel lanes: Task 0 ‖ Task 1; after Task 2 the Go lanes 3 ‖ 4; Task 5 ‖ 4; the Swift lane (10 → 11 → 12) starts after Task 7 (it depends on the JSON shape) and runs ‖ Tasks 8–9. Each lane in its own worktree/branch merged by the controller.

---

### Task 0: Spikes (no product code)

Answers spec §14. Output: a short appendix "Observed (Claude Code <version>, 2026-10-xx)" in the design spec, plus redacted fixtures.

- [ ] Capture a `PostToolUse` input from a subagent started with `isolation: "worktree"`; record whether `cwd` is the subagent's worktree. Save redacted as `cmd/testdata/posttooluse_subagent_worktree_cwd.json`.
- [ ] From a Desktop-spawned CLI, run `lsof -a -d cwd -n -P -w -F pn -u <uid>` with a test process whose cwd is under `~/Documents`; record whether any TCC prompt appears (and in whose name). Decide: lsof stays, or the §7 fallback.
- [ ] In an auto-mode session with `Bash('<bin>' workbench cleanup:*)` in `permissions.allow`, run the command; record whether it passes without a prompt or block.
- [ ] Build a throwaway `.app` in a temp worktree, register it, `lsregister -u` it, delete it; check `lsregister -dump` no longer lists it. Repeat with `-u` after deletion.
- [ ] Record the worktree admin dir's birth time after `git worktree add`, and that `git worktree list`/`status` do not change it.

**Verification:** none (documents and fixtures only).

### Task 1: Migration

**Files:** create `internal/db/migrations/<next>_session_cleanup.sql`; modify `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), golden snapshot, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerated).

**Schema:** spec §3.1 verbatim (table + two columns, comments).

**Tests:**
- `TestMigrationSessionCleanup_UpCreatesTableAndColumns` — table PK `(session_id, root, branch)`, both columns NULL on existing rows.
- `TestMigrationSessionCleanup_DownDropsAndReUpRestores`.
- `TestMigrationSessionCleanup_LedgerCascadesWithTheSession`.

**Verify:** `go test ./internal/db -run 'Migration|TestAllTablesExist|TestSchemaGolden|TestDesktopTestSchema'` (regenerate with `-update` first).

### Task 2: DB layer

**Files:** create `internal/db/terminal_session_worktrees.go` (+ `_test.go`); modify `internal/db/terminal_sessions.go`.

**Interfaces:**
```go
type SessionWorktree struct{ Root, Branch, FirstAt string }
func (db *DB) HasSessionWorktree(ctx context.Context, sessionID int64, root, branch string) (has, full bool, err error) // one read in a read-only tx; full = already at 64 rows
func (db *DB) RecordSessionWorktree(ctx context.Context, tx *sql.Tx, sessionID int64, root, branch, at string) (recorded bool, err error) // INSERT OR IGNORE; refuses past 64 rows (recorded=false, nil)
func (db *DB) SessionWorktrees(ctx context.Context, sessionID int64) ([]SessionWorktree, error) // never nil
func (db *DB) WorkbenchSessionWorktrees(ctx context.Context, workbenchID int64) (map[string][]int64, error) // root -> session ids (sweep owner hint)
func (db *DB) SaveCleanupResult(ctx context.Context, sessionID int64, resultJSON, at string) error
```

**Tests:** `TestRecordSessionWorktree_InsertsOnceAndIgnoresRepeats`, `TestRecordSessionWorktree_StopsAt64`, `TestSessionWorktrees_EmptyIsNotNil`, `TestSaveCleanupResult_WritesOnlyItsRow`, `TestHasSessionWorktree_UsesAReadOnlyTx` (works on a `SetReadOnly` handle).

**Verify:** `go test ./internal/db -run 'SessionWorktree|CleanupResult'`.

### Task 3: State hook records the ledger (PROJ-11)

**Files:** modify `cmd/workbench_session_state.go` (+ `_test.go`).

**Behaviour:** spec §3.2. Every event of a resolved session (main and subagent): resolve `cwd` with #565's resolver → `(root, branch)`; `HasSessionWorktree` (one read-only read: known pair or full session → no write lock) → if new, `RecordSessionWorktree` in its **own** transaction after the state write has committed — deliberately not inside the state-write tx: a ledger failure (missing table, lock timeout, cap) must never roll back or fail the state write, and a separate tx gives that across all state-write paths without savepoints. Ledger errors: one stderr line, exit 0, state write unaffected; the "session full" line at most once per run.

**Tests:**
- `TestProj11_LedgerRecordsANewWorktreeOnce` — two events in the same worktree → one row; a third on a new branch → second row.
- `TestProj11_LedgerFailureNeverCostsTheStateWrite` — ledger table dropped → state written, exit 0, one stderr line.
- `TestProj11_SubagentCwdIsRecordedButNeverMovesTheSessionPlace` — subagent event in a worktree: ledger row, #565's column unchanged.
- `TestSessionStateLedger_OutsideARepositoryRecordsNothing`, `TestSessionStateLedger_NoCwdRecordsNothing`, `TestSessionStateLedger_UsesTheFixture` (Task 0 fixture).
- Existing `TestProj11_*` stay green unchanged.

**Verify:** `go test ./cmd -run 'TestProj11_|SessionStateLedger|SessionState'`.

### Task 4: `internal/sessioncleanup` — plan

**Files:** create `internal/sessioncleanup/{plan.go,inventory.go,ownership.go,catches.go,result.go}` + tests, `testmain_test.go`.

**Interfaces:**
```go
type Kind string // "worktree" | "branch" | "process" | "lsreg"
type Item struct {
    Key, Kind, Name, Branch, Reason, Detail, Error string
    Bytes int64; BytesKnown bool; Action string /* "remove"|"keep" */; Done bool
    Owner *OwnerHint `json:"owner,omitempty"` // sweep only
}
type Request struct {
    WorkbenchID, SessionID int64; Sweep bool
    CallerSessionID int64 // from $WATCHTOWER_TERMINAL_SESSION_ID; 0 = not an agent call
    LiveSessions []int64; DeclaredWorktrees, DeclaredBranches []string; NoSize bool
    Now time.Time
}
type Plan struct{ Items []Item; DefaultBranch string }
type Deps struct { Git GitRunner; DB Store; Procs ProcessScanner; Sizer Sizer; LS LaunchServices; Clock func() time.Time }
func Build(ctx context.Context, d Deps, r Request) (Plan, error)
```
`inventory.go`: `git worktree list --porcelain`, default branch (`origin/HEAD` → `main` → `master`), `for-each-ref refs/heads`, `--contains`/`merge-base --is-ancestor` checks, worktree admin-dir birth time, branch reflog first entry. `ownership.go`: spec §2. `catches.go`: W1–W8, B1–B4 in order (spec §5), reason codes as constants.

**Tests (real temp repos, a bare "remote" repo for pushed refs):**
- `TestProj16_UncommittedWorktreeIsKept`, `TestProj16_UntrackedFileKeepsTheWorktree` (an ignored `.build/` file alone does **not** keep it — `TestPlan_IgnoredFilesDoNotKeepTheWorktree`).
- `TestProj16_UnpushedCommitKeepsWorktreeAndBranch`, `TestProj16_LockedWorktreeIsKept`, `TestPlan_OperationInProgressKeepsTheWorktree`.
- `TestProj16_WorktreeOlderThanTheSessionIsKept`, `TestProj16_BranchOlderThanTheSessionIsKept`, `TestPlan_BranchWithoutReflogIsKept`.
- `TestProj16_BranchCheckedOutElsewhereIsKept`, `TestProj16_DefaultBranchIsNeverDeleted`.
- `TestProj16_MainFolderAndWorkbenchFoldersAreNeverCandidates` (a second workbench bound to a linked worktree).
- `TestProj16_SessionInTheWorktreeKeepsIt` (another session's `agent_cwd` inside + live; reported 25 h ago and not live → not kept; caller's own `agent_cwd` → `you_are_in_it`).
- `TestPlan_TargetBranchOfALinkedTargetIsACandidate`, `TestPlan_DeclaredPathThatIsNotAWorktreeIsKept`, `TestPlan_PrunableWorktreeIsListed`.
- `TestPlan_SweepIgnoresOwnershipAndMarksRecentSessions` (7-day rule, `owner` hint, `unknown` for no ledger).
- `TestProj16_PlanWritesNothing` (refs, worktrees, DB and process signals unchanged; a fake scanner records no signal).
- `TestPlan_NoGitIsAnError` (no process spawned).

**Verify:** `go test ./internal/sessioncleanup`.

### Task 5: Processes, sizes, LaunchServices

**Files:** create `internal/sessioncleanup/{procs.go,size.go,lsreg.go}` + tests.

**Interfaces:**
```go
type Proc struct{ PID, PPID, UID int; Start, Exe, Cwd string /* "" = unknown */ }
type ProcessScanner interface{ Scan(ctx context.Context) ([]Proc, error); Terminate(p Proc) error /* SIGTERM, re-verifies start time */ }
type Sizer interface{ Size(ctx context.Context, root string, budget time.Duration) (bytes int64, known bool) }
type LaunchServices interface{ Bundles(root string) []string; Unregister(ctx context.Context, bundle string) error; Stale(ctx context.Context, under string) ([]string, error) }
func OrphansIn(procs []Proc, roots []string, self int) (orphans, blockers []Proc)
```
`ps -axo pid=,ppid=,uid=,lstart=,comm=` parse; `lsof` per Task 0's decision (or the fallback: cwd unknown → blocker `process_unknown`). `lsregister` at its fixed system path, never PATH.

**Tests:** `TestPsParse_FixtureLines`, `TestLsofParse_FixtureLines`, `TestProj16_OnlyOrphansAreSignalled` (ppid ≠ 1, another uid, a Watchtower or `claude` executable, outside the roots → never orphans; a stub process started by the test in a temp worktree and reparented → orphan; reaped in `t.Cleanup`), `TestTerminate_ReusedPidIsNotSignalled` (start time mismatch), `TestSize_CountsAllocatedBlocksAndStopsAtBudget`, `TestSize_DoesNotFollowSymlinks`, `TestBundles_SkipsNodeModulesAndGitAndDepth`, `TestLsregDumpParse_Fixture`.

**Verify:** `go test ./internal/sessioncleanup -run 'Ps|Lsof|Orphan|Terminate|Size|Bundles|Lsreg'`.

### Task 6: Apply

**Files:** create `internal/sessioncleanup/apply.go` (+ test); modify `result.go`.

**Interfaces:**
```go
type Result struct{ Plan; Mode string; RemovedBytes int64; Summary string }
func Apply(ctx context.Context, d Deps, r Request, only []string /* item keys; empty = all eligible (session mode only) */) (Result, error)
func Summarize(items []Item) string // "2 worktrees, 4 branches removed (~14 GB); kept 1 worktree — uncommitted changes" / "nothing to clean up"
```
Order per spec §7: re-plan → per worktree re-check, orphans (session mode only), `lsregister -u`, `git worktree remove` (no force) → prune gone dirs → branches re-check and `update-ref -d <ref> <sha>` + `config --remove-section`. Sweep requires non-empty `only`.

**Tests:** `TestProj16_ApplyRechecksAndActsOnlyOnNamedItems` (a file written into the worktree between plan and apply → kept), `TestProj16_BranchThatMovedAfterThePlanIsKept`, `TestProj16_MergedAndPushedWorkIsRemoved` (done-criterion 1: two worktrees with a merged PR branch and a pushed branch → both worktrees and branches gone, `~/.claude`-like dir and the main folder's `WatchtowerDesktop/.build` fixture untouched — `TestProj16_ClaudeHistoryAndMainBuildUntouched`), `TestApply_GitRefusalIsKeptWithDetail`, `TestApply_LsregisterFailureDoesNotBlockRemoval`, `TestApply_SweepWithoutItemsIsRefused`, `TestApply_OrphanSurvivingSIGTERMKeepsTheWorktree`, `TestSummarize_Wording` (table: nothing, removed only, kept only, mixed, unknown size).

**Verify:** `go test ./internal/sessioncleanup`.

### Task 7: CLI `watchtower workbench cleanup`

**Files:** create `cmd/workbench_cleanup.go` (+ `_test.go`); modify `cmd/workbench.go` (register).

**Flags:** spec §4 (`--session`, `--workbench`, `--sweep`, `--apply`, `--item`, `--worktree`, `--branch`, `--live-session`, `--no-size`, `--json`). `--session` defaults from `$WATCHTOWER_TERMINAL_SESSION_ID`; the session must belong to `--workbench` when both are given. After `--apply` in session mode, `SaveCleanupResult` (best effort → `result_saved`/`result_error`).

**Tests:** `TestCleanupCmd_PlanIsDefaultAndJSONShape`, `TestCleanupJSON_EmptyPlanHasEmptyItems`, `TestCleanupCmd_SessionFromEnv`, `TestCleanupCmd_NoSessionIsUsageError` (exit 2), `TestCleanupCmd_SessionOfAnotherWorkbenchRefused`, `TestCleanupCmd_ApplySavesTheResult`, `TestCleanupCmd_ResultSaveFailureIsReportedNotFatal`, `TestCleanupCmd_TextModePrintsSummaryAndReasons`.

**Verify:** `go test ./cmd -run 'CleanupCmd|CleanupJSON'`.

### Task 8: Install — permission entry and brief line

**Files:** modify `internal/devpack/workbench_settings.go` (+ tests), the install/resync/remove call sites (`cmd/integrate_workbench.go`, `cmd/workbench_resync.go`, `devpack.RemoveWorkbench`), `cmd/workbench_brief.go` (+ test); Desktop Repair/health check if it lists our entries (`HasCleanupPermission`).

**Interfaces:**
```go
func InstallCleanupPermission(dir, bin string, workbenchID int64) (changed bool, err error)
func RemoveCleanupPermission(dir string, workbenchID int64) (changed bool, err error)
func HasCleanupPermission(dir string, workbenchID int64) (bool, error)
func cleanupAllowRule(bin string) string // Bash('<bin>' workbench cleanup:*)
```

**Tests:** `TestProj04_CleanupPermissionKeepsOwnerPermissions` (owner allow/deny entries and other keys byte-identical, order kept), `TestCleanupPermission_IdempotentAndReplacesStaleBin`, `TestProj02_RemoveProjectLeavesNothingInstalled` (extended with the entry), `TestCleanupPermission_MalformedSettingsIsAnErrorNotAnOverwrite`, `TestBrief_CleanupLineWhenSessionKnown`, `TestBrief_NoCleanupLineWithoutSession`.

**Verify:** `go test ./internal/devpack -run 'CleanupPermission|TestProj04_|TestProj02_'` and `go test ./cmd -run 'Brief|TestProj02_'`.

### Task 9: Skill pack v7

**Files:** modify `internal/devpack/workbenchskill/*/SKILL.md` (marker → next free version, "Finishing a session" per spec §11, the `finish_session` tool line's summary limit); create `internal/devpack/testdata/watchtower-workbench-v6.md` (the shipped v6 text); extend the fixture list in `internal/devpack/workbench_test.go`.

**Tests:** `TestWorkbenchSkill_UpgradesAnUneditedPreviousVersionAndKeepsAnEditedOne` (now v1–v6), `TestWorkbenchSkill_FinishingSectionNamesTheCleanupStep` (mentions the `Cleanup:` brief line, `--apply`, "Never remove a worktree or branch by hand").

**Verify:** `go test ./internal/devpack`.

### Task 10: Swift Core — models and presentation

**Files:** create `WatchtowerDesktop/Sources/WatchtowerCore/Models/SessionCleanup.swift`, `…/Services/SessionCleanupPresentation.swift`; tests in `WatchtowerDesktop/Tests/Core/`.

**Interfaces:** `struct SessionCleanupPlan: Decodable` (mirrors spec §4.1, `items` defaults to `[]`), `SessionCleanupItem`, `enum SessionCleanupReason` (unknown codes → `.other(String)`), `SessionCleanupPresentation.reasonText(_:)`, `.offerLine(plan) -> String?` ("Also clean up: 2 worktrees, 3 branches (~12 GB). Kept: 1 worktree — uncommitted changes."; nil when nothing to remove), `.sizeText(bytes, known)` ("~12 GB", "size unknown"); `TerminalSession` gains `cleanupResult`, `cleanupAt` (read-only).

**Tests:** `SessionCleanupPlanDecodingTests` (empty items, unknown reason, missing `owner`), `SessionCleanupPresentationTests` (every reason code has English text; offer line variants; sizes).

**Verify:** `make test-swift FILTER='SessionCleanupPlanDecodingTests|SessionCleanupPresentationTests'`.

### Task 11: Desktop — center, Delete dialog, Clean Up… sheet, report line

**Files:** create `WatchtowerDesktop/Sources/Services/SessionCleanupCenter.swift`, `…/Views/Workbench/SessionCleanupSheet.swift`; modify `AppState` (owns the center), `WorkbenchSessionsPanel.swift` (`SessionActionDialogs`, row menu), `WorkbenchesViewModel+Sessions.swift` (`delete` gains the cleanup path), the session report view; tests.

**Interfaces:**
```swift
@Observable @MainActor final class SessionCleanupCenter {
    enum Phase { case idle, planning, ready(SessionCleanupPlan), applying, done(SessionCleanupPlan), failed(String) }
    func plan(sessionID: Int64, workbenchID: Int64) async
    func apply(sessionID: Int64, workbenchID: Int64, items: [String]) async -> Bool
    func phase(for key: CleanupScope) -> Phase
}
```
Delete flow per spec §12: close terminal → apply planned `remove` keys → delete row only on success; a failure shows the message and leaves the row. Live session ids passed from `TerminalCenter.liveIDs`.

**Tests:** `testProj16_DeleteAppliesOnlyThePlannedItems` (fake runner records argv: `--apply` + exactly the planned keys), `testProj16_FailedCleanupKeepsTheSessionRow`, `testDeleteOnlySkipsTheCleanup`, `testCleanupSurvivesNavigation` (start → leave the page → return → phase kept), `testPlanPassesLiveSessions`, `testReportShowsTheCleanupLine`.

**Verify:** `make test-swift FILTER='SessionCleanupCenterTests|WorkbenchSessionDeleteTests'`.

### Task 12: Desktop — sweep

**Files:** modify the workbench header menu view, `SessionCleanupSheet` (sweep mode: nothing pre-ticked, owner hint column), `SessionCleanupCenter` (`sweep(workbenchID:)`); if the owner approves open question 2, a one-time hint (`projects.cleanupHintShown.<id>` UserDefaults key) when the sweep total exceeds 1 GB.

**Tests:** `testSweepTicksNothingByDefault`, `testSweepAppliesOnlyTickedKeys`, `testSweepHintShownOnceAboveOneGigabyte` (only if approved).

**Verify:** `make test-swift FILTER='SessionCleanupSweepTests'`.

### Task 13: Inventory, feature notes, app guide

**Files:** `docs/inventory/workbench.md` (new PROJ-16 with the approved wording and guard list; PROJ-11/04/02 amendments; v1 limits: the deferred list of spec §1; changelog), `docs/inventory/dev-surface.md` (DEV-04 changelog: pack v7, v6 fixture), `docs/features/workbench.md` (a "Session cleanup" bullet), `CLAUDE.md` feature index line for workbench (mention cleanup), `docs/app-guide.md` (Delete and Clean Up, Clean Up…, Clean Up Old Worktrees…, Re-run Setup once).

**Verify:** `grep -n 'PROJ-16' docs/inventory/workbench.md` lists every guard name that exists in the code (`grep -rn 'TestProj16_\|testProj16_' cmd internal WatchtowerDesktop/Tests`).

### Task 14: Final gate

`bash scripts/dev-health.sh` first; then `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...` — each to a log with `echo "exit=$?"`. Then a manual check filed as an owner ask: a real session with two subagent worktrees and a merged PR → finish → worktrees and branches gone, `~/.claude/projects/...` intact, the summary line and the report line present; an uncommitted file in a third worktree → kept with the reason. The same ask covers the TCC check of design §14.2
for the shipped scan `lsof -a -d cwd,txt -n -P -w -F pfn -u <uid>` (Desktop-spawned, a process with its cwd under
`~/Documents`, `~/Desktop` and `~/Downloads`): no privacy dialog with `txt` included.
