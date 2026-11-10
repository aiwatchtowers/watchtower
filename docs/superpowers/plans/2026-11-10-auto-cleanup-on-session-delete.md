# Automatic cleanup on session delete — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every Desktop session delete removes, in the background, what the session created and what is safe to remove. That includes subagent worktrees and branches. A session whose cleanup failed stays in the list marked **Not fully cleaned**.

**Architecture:**
- **Go side.** The schema gains `delete_requested_at` and a ledger `source`/`kind`. A pure command parser feeds the session-state hook, which records `command` rows. `internal/sessioncleanup` adopts command rows and the session's Claude scratchpad. Every list reader of `terminal_sessions` hides deleting rows.
- **Desktop side.** A per-workbench background queue runs `workbench cleanup --apply` when the Undo window ends. A pure WatchtowerCore outcome function decides between deleting the row and marking it. The UI shows the notice, the header line and the marked row.

**Tech Stack:** Go 1.26 (cgo SQLCipher, goose SQL migrations), SwiftUI/GRDB (WatchtowerCore + Desktop), XCTest.

**Spec:** `docs/superpowers/specs/2026-11-10-auto-cleanup-on-session-delete-design.md` (approved, ask #1213). Mockup: `docs/design/mockups/session-auto-cleanup/states.html`.

**Branching:** umbrella branch `feature/1716-auto-cleanup` off `main`. Each task is its own worktree, branch and PR into the umbrella. The umbrella PR into `main` stays a draft until every task is done.

## Global Constraints

- **Time limit:** a background run is stopped after **10 minutes**: SIGTERM to its process group, then SIGKILL after **5 s**. The outcome is *could not* with the text "the cleanup took longer than 10 minutes".
- **Caps:** `cwd` ledger rows keep `MaxSessionWorktrees = 64`; `command` rows have their own cap of **512** per session.
- **Notice:** shown for **6 s**. The copy is verbatim from spec §3 (`Cleaned up “T”: removed 3 worktrees and 12 branches (~2.1 GB).` etc.). The row mark reads `Not fully cleaned: <count> — <reason phrase>.`
- **No git run inside a hook.** Only string parsing and `stat` are allowed there.
- **No LLM** anywhere in the path (ask #1210).
- **Background apply:** never passes `--item`.
- **UI:** built from the design kit (`WatchtowerDesktop/Sources/DesignKit/`); colours only through `Tone`, warning tone for the mark; no stock look and no row separators. **Delete** in the dialog uses `kitDestructive`. Row actions show on hover; none of them is prominent.
- **Copy and tests:** every UI string is built in a WatchtowerCore model and tested.
- **Guard tests replaced** (ask #1210):
  - `testQuickDeleteNeverCleansUp` → `testProj17_EveryDeleteCleansUpAfterTheWindow`;
  - `testProj18_DeleteAppliesOnlyThePlannedItems` → `testProj18_BackgroundApplyHasNoItemFilter`;
  - `testProj18_FailedCleanupKeepsTheSessionRow` is kept (it now asserts the mark).
- **Public repo:** fixtures use `acme`/`example.com` and `/tmp/...` sample paths, never live paths.

## Review Focus

1. **Command parsing on real agent shapes:** `cd "$WT" && git worktree add ../x -b y`, `git -C /abs worktree add`, quoted paths with spaces, and `&&` chains with an `echo` holding the word `git`. A literal command must parse; anything with `$` or a backtick must record nothing (Task 2 table).
2. **Two sessions name the same branch** (one created it, one only ran `git checkout -b` that failed because it existed). The birth-after-start check must keep it for the second (Task 4 test `TestProj18_CommandNamedBranchOlderThanSessionIsKept`).
3. **A deleting row reappears somewhere:** a target's Start/Reopen, the phone, the workbench status rollup (Task 5 guard + tests).
4. **App quit or crash mid-queue:** rows with `delete_requested_at` re-queue once at launch and never loop (Task 7 test `testRequeueAtLaunchRunsOncePerRow`).
5. **A Clean Up screen apply while the queue runs:** it waits for the slot and is not refused; the queue's next item waits for it (Task 7 test `testScreenApplyWaitsForQueueSlot`).

---

### Task 1: Schema — `delete_requested_at`, ledger `source`/`kind`, command-row writer

Depends on: none

**Files:**
- Create: `internal/db/migrations/00186_session_auto_cleanup.sql` (renumber if `main` moved on)
- Modify: `internal/db/schema.sql` (the `terminal_sessions` and `terminal_session_worktrees` blocks)
- Modify: `internal/db/terminal_session_worktrees.go`
- Regenerate: the golden snapshot + `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`)
- Test: `internal/db/terminal_session_worktrees_test.go`

**Interfaces — Produces:**
- `SessionWorktree{Root, Branch, FirstAt, Source, Kind string}`, with `Source` ∈ `"cwd"|"command"` and `Kind` ∈ `"worktree"|"branch"`.
- `const MaxSessionCommandRows = 512`.
- `func (db *DB) RecordSessionCommandRow(ctx context.Context, sessionID int64, root, branch, kind, at string) (recorded, full bool, err error)`: one short write transaction. An existing `(session_id, root, branch)` row only moves `last_at` and never changes `source`.
- No Go writer of `delete_requested_at`: the Desktop is its only writer (spec §4). Go tests set it with a raw `UPDATE` in an unexported `_test.go` helper (`setDeleteRequestedForTest`).

Steps:
- [ ] **Write the migration.** `ALTER TABLE terminal_sessions ADD COLUMN delete_requested_at TEXT;` and `ALTER TABLE terminal_session_worktrees ADD COLUMN source TEXT NOT NULL DEFAULT 'cwd' CHECK (source IN ('cwd','command'));` plus the same for `kind` (`'worktree'`, `CHECK (kind IN ('worktree','branch'))`). `-- +goose Down` drops the columns (SQLite ≥ 3.35 `DROP COLUMN`).
- [ ] **Write the failing tests:**
  - `TestSessionCommandRows_CapIs512`: inserting 513 distinct pairs gives `recorded=false, full=true` on the 513th;
  - `TestSessionCommandRows_DoNotCountAgainstCwdCap`: 64 `cwd` rows plus 1 `command` row are recorded;
  - `TestSessionCommandRows_ExistingCwdRowKeepsSource`: a `command` insert of an existing `cwd` pair leaves `source='cwd'` and moves `last_at`.
- [ ] Run `go test ./internal/db -run 'TestSessionCommandRows'`. Expected: FAIL.
- [ ] **Implement.** `SessionWorktrees` reads `source, kind`. The existing `cwd` cap count filters on `source='cwd'`.
- [ ] **Regenerate** the schema snapshot and the Swift schema. Run `go test ./internal/db`. Expected: PASS.
- [ ] Commit `feat(db): session auto-cleanup columns (#1716)`.

### Task 2: Pure git command parser

Depends on: none

**Files:**
- Create: `internal/gitcmdparse/parse.go`, `internal/gitcmdparse/parse_test.go`

**Interfaces — Produces:**
```go
type Created struct {
    Kind   string // "worktree" | "branch"
    Path   string // worktree only: absolute, cleaned, resolved against Dir
    Branch string // may be "" for a worktree without -b/-B
    Dir    string // the effective directory the git command ran in (absolute)
}
func Parse(command, cwd string) []Created
```

Steps:
- [ ] **Write a table test `TestParse`.** Each case is `{command, cwd, want []Created}`. Cases:
  - `git worktree add /tmp/a -b feat/x`;
  - `cd /r && git worktree add ../wt -B y` → Path `/wt`, Dir `/r`;
  - `git -C /r worktree add "dir with space"`;
  - `git branch topic`; `git branch -D topic` → none; `git branch --show-current` → none;
  - `git checkout -b b1`; `git switch -c b2`;
  - `echo git branch x` → none;
  - `git worktree add $WT -b z` → none (the word holds `$`);
  - ``git branch `x` `` → none;
  - `a && git branch b ; git switch -C c | cat` → two;
  - an unterminated quote → none.
- [ ] Run `go test ./internal/gitcmdparse`. Expected: FAIL.
- [ ] **Implement** `Parse`:
  - POSIX-like word splitting (single quotes, double quotes, backslash) and segments split on `&&`, `||`, `;`, `|`;
  - a leading `cd <dir>` segment changes the directory for the following segments; `git -C <dir>` changes it for its own segment;
  - git global options before the subcommand are skipped (`-c k=v`, `--no-pager`).
  - No regex over the whole string; no `os` calls.
- [ ] **Add `FuzzParse`** (must not panic; every `Path`/`Dir` is absolute). Run it once at the end with `-fuzztime=30s`.
- [ ] Commit `feat(gitcmdparse): parse worktree and branch creation (#1716)`.

### Task 3: Hook records command rows

Depends on: Task 1, Task 2

**Files:**
- Modify: `cmd/workbench_session_ledger.go` (new `recordCommandLedger`)
- Modify: `cmd/workbench_session_state.go` (claude PostToolUse at ~:289, codex at ~:380)
- Modify: `internal/sessionagent/event.go` only if the PostToolUse success flag is not already carried
- Test: `cmd/workbench_session_ledger_test.go`

**Interfaces:**
- Consumes: `gitcmdparse.Parse`, `db.RecordSessionCommandRow`.
- Produces: `func recordCommandLedger(database *db.DB, stderr io.Writer, rowID int64, ev sessionagent.Event, cwd string, at time.Time)`.

Steps:
- [ ] **Write the failing tests:**
  - `TestCommandLedger_RecordsWorktreeOnlyWhenDotGitFileExists`: in a temp repo, create `<path>/.git` as a file for one parsed path and not for another; one row results;
  - `TestCommandLedger_BranchRowUsesRepoTopLevel`: `Dir` is a subdirectory, so `root` = the top level found via `internal/gitdir` with no git run;
  - `TestCommandLedger_SkipsFailedToolCalls`;
  - `TestCommandLedger_SubagentEventsCount`: an event with `agent_id` set is recorded;
  - `TestCommandLedger_CodexShellTool`;
  - `TestCommandLedger_FullCapPrintsOneLine`.
- [ ] Run `go test ./cmd -run TestCommandLedger`. Expected: FAIL.
- [ ] **Implement:**
  - only PostToolUse with `tool_name == "Bash"` (Codex: its shell tool name as in `internal/sessionagent/codex.go`) and a successful result;
  - parse `tool_input.command`;
  - for a worktree, `os.Lstat(path+"/.git")` must be a regular file; the root is symlink-resolved (`resolvedDir`);
  - a branch row's `root` is `sessionWorktreeAt(Dir)`'s root;
  - the call runs after the state write, in the same place as `recordSessionLedger`; a failure is logged as one stderr line and never fails the hook.
- [ ] Run `go test ./cmd -run 'TestCommandLedger|TestSessionLedger'`. Expected: PASS.
- [ ] Commit `feat(workbench): session-state hook records created worktrees and branches (#1716)`.

### Task 4: Cleanup ownership — command rows and the Claude scratchpad

Depends on: Task 1

**Files:**
- Modify: `internal/sessioncleanup/ownership.go` (`observe`), `internal/sessioncleanup/plan.go` (`loadObserved`), `internal/sessioncleanup/deps.go` (new DB reads in the interface)
- Modify: `internal/db/terminal_session_agent_sessions.go`
- Test: `internal/sessioncleanup/plan_test.go`, `internal/sessioncleanup/ownership_test.go`

**Interfaces:**
- Produces:
  - `func (db *DB) AgentSessionIDs(ctx context.Context, rowID int64) ([]string, error)`: the history plus the current `claude_session_id`;
  - `func (db *DB) AgentSessionIDOwners(ctx context.Context, uuid string) ([]int64, error)`: every row whose history or current id holds the uuid.
- `observe` gains:
  - `command` rows: `worktree` kind → `roots` and its branch → `named`; `branch` kind → `branches` and `named`;
  - `scratchRoots []string`: absolute `<tmp>/claude-<uid>/*/<uuid>/` prefixes, for uuids whose owners are exactly `[row]`.
- `sawWorktree` also matches a root inside any `scratchRoots` prefix.
- The `<tmp>` bases are a set, because the CLI the Desktop starts may have `TMPDIR=/var/folders/…/T` while Claude Code writes its lanes under `/tmp`: `EvalSymlinks` of `/tmp` (→ `/private/tmp` on macOS), of `os.TempDir()`, and of `$CLAUDE_CODE_TMPDIR` when set, deduplicated. Under each base the prefix is `claude-<os.Getuid()>/*/<uuid>/`. `func scratchBases() []string` is a package var so tests inject a temp base. `TestScratchBases_IncludeSlashTmpWhateverTMPDIR` sets `TMPDIR` to another dir and asserts the resolved `/tmp` is still in the set.

Steps:
- [ ] **Write the failing tests:**
  - `TestProj18_CommandLedgerAdoptsWorktree`: a worktree born after the session start, merged, with a command row → `remove`;
  - `TestProj18_ScratchpadWorktreeIsTheSessions`: a worktree under `<tmp>/claude-<uid>/slug/<uuid>/scratchpad/x`, born after start, pushed → `remove`;
  - `TestProj18_ScratchpadUUIDSharedAdoptsNothing`: the uuid is in another row's history → `not_this_session`;
  - `TestProj18_CommandNamedBranchOlderThanSessionIsKept`: the reflog birth predates the start → `existed_before_session`;
  - `TestProj18_CommandRowUnpushedIsKept` → `unpushed_commits`.
- [ ] Run `go test ./internal/sessioncleanup -run TestProj18_`. Expected: the new ones FAIL, the old ones PASS.
- [ ] **Implement.** Do not edit `docs/inventory/workbench.md`; Task 7 owns every inventory edit of this plan, which avoids a merge conflict between lanes.
- [ ] Run `go test ./internal/sessioncleanup ./internal/db`. Expected: PASS.
- [ ] Commit `feat(sessioncleanup): adopt agent-created and scratchpad worktrees (#1716)`.

### Task 5: Go readers hide deleting rows

Depends on: Task 1

**Files:**
- Modify (list reads add `AND delete_requested_at IS NULL`):
  - `internal/hub/slices/sources/terminal_session.go`, `timeline.go`, `workbench.go`, `target.go`;
  - `internal/hub/lane.go`;
  - `internal/db/terminal_sessions_recent.go`;
  - `internal/sessionstate/status.go`;
  - `cmd/workbench_session.go` (the brief's session lines);
  - `internal/sessionstart/start.go`: `latestTargetSession` (:933), the placement scan (:771), both existence checks (:597, :621), and `Start` by id (:345 → `db.ErrTerminalSessionNotFound`).
- Modify: `internal/hub/actions/handlers/session_input.go` and `internal/hub/actions/handlers/permission.go` (`sessionInterrupt`): a deleting row is treated as missing
- Create: `internal/db/deleting_rows_guard_test.go`
- Test: next to each package above.

**Interfaces — Produces:**
- `const db.NotDeletingSQL = "delete_requested_at IS NULL"`, the one fragment every filtered read uses.
- `TestProj17_DeletingRowsLeaveEveryList`:
  - it walks `internal/` and `cmd/` non-test `.go` files and finds every string literal containing `FROM terminal_sessions`;
  - each literal must contain `delete_requested_at` or sit in a file and function on the explicit `lookupByID` allowlist in the test, which names the spec §4 lookups (`sessionreport`, `owner_asks`, `review_agent`, `workbench_agent_analytics`, `automation_session_steps`, `session_ticket`, `terminal_agent_turns`, `terminal_watch_issue`, `terminal_session_worktrees`, `terminal_sessions.go` id reads, `sessionstart` `:345`-style reads).

Steps:
- [ ] **Write the guard** and per-site failing tests:
  - `TestLatestTargetSession_SkipsDeletingRow`;
  - `TestStart_DeletingRowIsNotFound`;
  - `TestTerminalSessionSlice_HidesDeletingRow`;
  - `TestWorkbenchStatus_IgnoresDeletingRow`;
  - `TestSessionInput_DeletingRowRefused`;
  - `TestSessionInterrupt_DeletingRowRefused`.
- [ ] Run `go test ./internal/db -run TestProj17_DeletingRowsLeaveEveryList`. Expected: FAIL, listing the unfiltered sites.
- [ ] **Add the filter** at each list site. Run `go test` on each touched package (`./internal/hub/... ./internal/sessionstart ./internal/sessionstate ./internal/db`) and `go test ./cmd -run 'TestWorkbenchSession'`. Expected: PASS.
- [ ] Commit `feat: a session being deleted leaves every list (#1716)`.

### Task 6: WatchtowerCore — outcome, notice and mark copy

Depends on: none

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionAutoCleanupOutcome.swift`
- Create: `internal/sessioncleanup/reasons.go` (`func AllReasonCodes() []string`) + `internal/sessioncleanup/testdata/reason_codes.json`, written by `TestReasonCodesFixture -update`
- Create: `WatchtowerDesktop/Tests/Core/SessionAutoCleanupOutcomeTests.swift`

**Interfaces — Produces:**
```swift
package enum CleanupItemGroup { case removed, keptOnPurpose, notOurs, couldNot }
package enum SessionAutoCleanupOutcome: Equatable {
    case clean(SessionCleanupNotice?)        // nil = nothing removed, no notice
    case notFullyCleaned(mark: String)       // the row's warning line
    static func group(_ item: SessionCleanupItem) -> CleanupItemGroup
    static func evaluate(result: SessionCleanupResult?, title: String, runError: String?) -> SessionAutoCleanupOutcome
}
package struct SessionCleanupNotice: Equatable {
    let text: String
    static func joined(_ notices: [(title: String, result: SessionCleanupResult)]) -> SessionCleanupNotice?
}
```
`SessionCleanupItem`/`SessionCleanupResult` are the existing Swift models in `Models/SessionCleanup.swift`.

Steps:
- [ ] **Write the failing tests:**
  - `testEveryGoReasonCodeIsPlaced`: reads `reason_codes.json` through the repo-relative path used by other fixture tests; every code maps to a group; the spec §3 table is asserted literally;
  - `testUnknownReasonIsCouldNot`;
  - `testCleanNoticeCopy`, with the three spec §3 strings verbatim;
  - `testJoinedNoticeCopy`: `Cleaned up 4 sessions: removed …`;
  - `testMarkCopy`: `Not fully cleaned: 1 worktree — a process is running in it.`;
  - `testRunErrorMark`: `Not fully cleaned: the cleanup could not run — watchtower exited with code 1.`;
  - `testTimeoutMark`: "the cleanup took longer than 10 minutes".
- [ ] Run `make test-swift FILTER=SessionAutoCleanupOutcomeTests`. Expected: FAIL.
- [ ] **Implement.** Reason phrases come from the existing `SessionCleanupPresentation`; sizes use its `~X GB` formatter.
- [ ] Run the same filter, then `go test ./internal/sessioncleanup -run TestReasonCodesFixture`. Expected: PASS.
- [ ] Commit `feat(core): session auto-cleanup outcome and copy (#1716)`.

### Task 7: Desktop — background queue, quit, launch, Resume, Swift list filters

Depends on: Task 1, Task 6

**Files:**
- Create: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+AutoCleanup.swift`
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+PendingDeletes.swift`: `commitPendingDeletes` hands rows to the queue instead of deleting; `commitPendingDeletesForQuit` writes `delete_requested_at`.
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+SessionCleanup.swift`: remove `startDeleteAndCleanUp`/`runDeleteAndCleanUp`/`planCleanupBeforeDelete`.
- Modify: `WatchtowerDesktop/Sources/Services/SessionCleanupCenter.swift`: an apply with no `--item`, a 10-min timeout with a process-group kill, and a slot that waits instead of refusing.
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/TerminalSessionQueries.swift`:
  - `fetchForWorkbench`, `fetchAllWorkbenchSessions`, `fetchStandalone`, `fetchForTarget`, `fetchWorkLinks`, `fetchAgentStates`, `fetchAgentCwds`, the activity ordering in `WorkbenchQueries.swift`, and the reads in `Services/HubKeepAwake.swift` filter deleting rows. A deleting row must give no notice, no "needs you" badge, and keep nothing awake;
  - the guard `testProj17_SwiftDeletingRowsLeaveEveryList` (in `Tests/Core`) scans `WatchtowerDesktop/Sources/**/*.swift` for string literals with `FROM terminal_sessions`. Each must contain `delete_requested_at` or be on its explicit by-id allowlist (`fetch(id:)`, `goStartRow`, `isFinished`, `fetchCleanupRecord`, `hasWorktree`, `fetchDeleting`, the update/delete statements);
  - new `fetchDeleting(projectID:)`, `markDeleteRequested(id:at:)` and `clearDeleteRequested(id:)`.
- Delete: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionDeleteCleanupChoice.swift` (+ its tests).
- Modify: `docs/inventory/workbench.md`, the only task that edits it. It covers the PROJ-17 amendment and the whole PROJ-18 amendment of spec §5: every delete cleans, the Delete-and-Clean-Up sentence goes, the ledger `source`/`kind` and command source, the scratchpad rule, caps 64/512. The "Only what the session observed and what was created after the session started" sentence stays verbatim. Also `docs/features/workbench.md` (session cleanup paragraph).
- Test: `WatchtowerDesktop/Tests/WorkbenchSessionDeleteTests.swift`, `WorkbenchesViewModelPendingDeleteTests.swift`, new `WorkbenchesViewModelAutoCleanupTests.swift`.

**Interfaces:**
- Consumes: `SessionAutoCleanupOutcome.evaluate`, `SessionCleanupNotice.joined` (Task 6); the CLI `workbench cleanup --session N --workbench W --live-session … --apply --json`.
- Produces on `WorkbenchesViewModel`:
  - `var autoCleanupQueue: [Int64: [Int64]]` (workbench → row ids, FIFO);
  - `var notFullyCleaned: [Int64: String]` (row → mark);
  - `var cleanupNotice: SessionCleanupNotice?`;
  - `func requeueDeletingRowsAtLaunch()`: called after `initWorkbenches` and host reattach. It queues only rows with `delete_requested_at` and **no live terminal**; a row that is live again is left alone;
  - quit while an apply runs: `QuitCoordinator` sends SIGTERM to the apply's process group and waits at most 5 s, then SIGKILL. The row keeps `delete_requested_at`, so the next launch re-queues it, and no old process outlives the app to race the new one;
  - `func cleanUpAgain(_ id: Int64)`, `func deleteAnyway(_ id: Int64)`;
  - Resume clears `delete_requested_at` in its own write first.

Steps:
- [ ] **Write the failing tests:**
  - `testProj17_EveryDeleteCleansUpAfterTheWindow`: quick delete, then the window ends → `delete_requested_at` set, apply invoked without `--item`, a clean result → row deleted;
  - `testProj18_BackgroundApplyHasNoItemFilter`;
  - `testProj18_FailedCleanupKeepsTheSessionRow`: a could-not result → row kept, `notFullyCleaned[id]` = the Task 6 mark;
  - `testKeptOnPurposeStillDeletesRow`;
  - `testQuitInsideWindowMarksInsteadOfDeleting`;
  - `testRequeueAtLaunchRunsOncePerRow`;
  - `testScreenApplyWaitsForQueueSlot`;
  - `testTimeoutIsCouldNot` (the injected clock passes 10 min; the process kill is asserted on the fake runner);
  - `testResumeClearsDeleteRequested`; `testResumeDisabledWhileCleaning`;
  - `testDeleteAnywayDeletesRow`;
  - `testDeletingRowsHiddenFromLists`;
  - `testDeletingRowGivesNoAgentStateNotice` (`fetchAgentStates`);
  - `testRequeueSkipsRowWithLiveTerminal`;
  - `testQuitStopsRunningApplyAndKeepsMark`;
  - `testCleanUpAgainSuccessDeletesRow`, `testCleanUpAgainFailureKeepsNewMark`;
  - `testShowInCleanUpOpensScreenScopedToSession`;
  - `testNotFullyCleanedReportShowsCleanupSection` (the report's Cleanup section is read from `cleanup_result`).
  
  Delete `testQuickDeleteNeverCleansUp` and `testProj18_DeleteAppliesOnlyThePlannedItems`, which ask #1210 replaces.
- [ ] Run `make test-swift FILTER='WorkbenchSessionDeleteTests|WorkbenchesViewModelPendingDeleteTests|WorkbenchesViewModelAutoCleanupTests'`. Expected: FAIL.
- [ ] **Implement.** Fake the CLI through the existing `SessionCleanupCenter` runner seam. A test that starts a real process reaps its group in teardown.
- [ ] Run the same filter plus `make test-swift FILTER='WorkbenchesViewModelPlacedCleanupTests|CleanupScreen'`. Expected: PASS. Then run `make lint-swift`.
- [ ] Commit `feat(desktop): clean up every deleted session in the background (#1716)`.

### Task 8: Desktop — screens, design shots, guide

Depends on: Task 7

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/SessionDeleteConfirmSheet.swift` (plain confirmation; **Delete** is `kitDestructive`)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/SessionsPanelFinishedGroup.swift` (the marked row: warning line, hover actions **Clean Up Again** / **Delete Anyway** / **Show in Clean Up**, the ⋯ menu when narrow; no ⌘1…⌘9 number)
- Modify: the sessions panel header (`Cleaning up N sessions…`) and `SessionDeleteToast.swift` (the notice, 6 s)
- Modify: the `DesignShotCatalog` registrations: the nine states of spec §7, on fixture data
- Modify: `docs/guide/` workbench sessions page (delete cleans up; what is kept; Not fully cleaned and its actions); run `go test ./docs/guide` (8 KB cap)
- Test: `WatchtowerDesktop/Tests/Core/SessionsPanelHeaderCopyTests.swift` (the header copy in the model)

Steps:
- [ ] Write the failing test `testCleaningHeaderCopy`: 1 → `Cleaning up 1 session…`, 2 → `Cleaning up 2 sessions…`, 0 → nil.
- [ ] Implement the views. Register the nine shots.
- [ ] Run `make desktop-shots DESKTOP_SHOTS=<scratch>` and compare each shot with `states.html` in light and dark. Fix any mismatch.
- [ ] Run `make test-swift FILTER=SessionsPanelHeaderCopyTests`, `make lint-swift` and `go test ./docs/guide`. Expected: PASS.
- [ ] Commit `feat(desktop): auto-cleanup screens and guide (#1716)`.

### Gate (controller, once, before the umbrella PR leaves draft)

- [ ] `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`. All green; paste the tails into the PR.
- [ ] Final review of the umbrella diff with `debate-review`.
