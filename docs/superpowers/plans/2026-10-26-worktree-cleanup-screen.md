# Clean Up screen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the two cleanup sheets with one non-modal Clean Up screen that lists rows at once, fills checks and sizes in as the CLI streams them, and lets the owner pick in bulk.

**Architecture:** Go: `internal/sessioncleanup` reports progress through an optional observer and gains `origin` / `last_commit_at` / `merged` (+ `worktree` on bundle items); `cmd/workbench_cleanup.go` writes the observer's events as JSON lines under `--stream`. Desktop: `SessionCleanupCenter` runs streamed plans/applies on `CodeCLIProcess` with a run id per scope; a pure `CleanupScreenModel` in WatchtowerCore builds rows, pairing, filters and totals; `CleanupScreenView` covers the workspace area as in-memory page state.

**Tech Stack:** Go 1.26 (cobra, `internal/gitbin`), SwiftUI macOS 14 + the DesignKit, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-26-worktree-cleanup-screen-design.md` (approved, ask #633). Mockup: `docs/design/mockups/worktree-cleanup/screen.html` (+ `screen-light.png` / `screen-dark.png`), states A–G.

## Global Constraints

- No safety catch changes (PROJ-18, design 2026-10-12 §5); every apply re-plans and re-checks; the Desktop never runs git.
- Without `--stream` the CLI output is byte-for-byte as today except the three new item keys (`origin`, `last_commit_at`, `merged`) and `worktree` on bundle `lsreg` items.
- `--stream` is valid only with `--json`; otherwise usage error, exit 2.
- Nothing is pre-ticked in either scope; ⌘A / Select All That Can Go tick only rows that can be chosen among those the filters show.
- A worktree row's apply keys = its own key + its branch's key when that branch item is `remove` + its bundles' `lsreg:` keys; only known kinds (`removableItems(among:)` rule).
- The screen is in-memory page state, never a `WorkspacePane`/`WorkspaceLayout` value; it covers the workspace area and keeps its views alive.
- One cleanup apply per workbench at a time (screen, either scope, or Delete and Clean Up); the other entry shows "Another cleanup is running".
- Kit only (`.kitRow`, `SectionHeader`, `Chip`, `KitSegmentedPicker`, `.kitQuiet`/`.kitSecondary`/`.kitDestructive`, `TabEmptyState`), colours from `Tone`, tokens from `Spacing`/`Radius`; no stock `Table`, no row dividers. `make lint-swift` runs in every Swift task (lint-diff is Go-only).
- Copy (exact): "Clean up worktrees and branches"; "Nothing goes until you select it and confirm. Unsaved or unpushed work is never removed."; "Select All That Can Go"; "Clear"; "Clean Up…"; "Nothing selected"; "Another cleanup is running"; confirmation title "Remove N worktrees and M branches (~X)?" and body "Each one is checked again right before it goes: anything with unsaved or unpushed work, or that changed since the check, is kept."; buttons "Cancel" / "Remove"; empty "Nothing to clean up".
- Fixture data only in tests and shots (`acme`, `example.com`); never a repo-built CLI on the live database (use a copy).
- Inner loop only per task (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`, `make lint-swift`); the full gate once per phase by the controller.

## Review Focus

1. **A late line of a stopped run** (Refresh mid-plan, scope change) must never change the new plan's rows — Task 8 `testStaleRunLinesAreDropped`.
2. **A stream that ends without `done`** (CLI crash, exit 1 after `listed`) must end as a failed plan with the listed rows kept and the error shown — Task 8 `testStreamWithoutDoneIsAFailedPlan`.
3. **A branch kept while its worktree goes** (checked out elsewhere, unpushed) must not be sent — Task 7 `testKeptBranchIsNotSentWithItsWorktree`.
4. **Ticks hidden by a filter** still count in the total and are still applied; ticks on rows that became kept after a Refresh are dropped — Task 7 `testHiddenTicksCountAndStaleTicksDrop`.
5. **Garbage on stdout** (a non-JSON line, an unknown event) must be skipped, not fail the run — Task 6 `testUnknownEventAndBadLineAreSkipped`.

## Lanes

Go lane: Task 1 → 2 → 3 → 4 → 5. Swift lane: Task 6 (needs only the spec's JSON shape) → 7, 6 → 8; then 9 (needs 4, 7, 8) → 10 → 11; Task 12 last. The Go lane and Tasks 6–8 may run in parallel worktrees.

---

### Task 1: `workbenchgit.WorktreeOrigin`

**Depends on:** none

**Files:**
- Modify: `internal/workbenchgit/worktree.go` (next to `worktreesDir` / `worktreeBranchRoot`)
- Test: `internal/workbenchgit/worktree_origin_test.go`

**Interfaces:**
- Produces: `type Origin string`; `const OriginSubagent Origin = "subagent"`, `OriginPlaced Origin = "placed"`, `OriginManual Origin = "manual"`; `func WorktreeOrigin(topLevel, root, branch string) Origin`.

- [ ] **Step 1: Write the failing table test** `TestWorktreeOrigin`:
  - `("/r", "/r/.claude/worktrees/agent-3f9c0a17d2e4b6c1", "feature/x")` → `OriginSubagent`
  - `("/r", "/r/.claude/worktrees/search-filters", "wt/search-filters")` → `OriginPlaced`
  - `("/r", "/r/.claude/worktrees/search-filters", "feature/x")` → `OriginManual` (not on a `wt/` branch)
  - `("/r", "/r/.claude/worktrees/agent-xyz", "lane/a")` → `OriginManual` (not hex)
  - `("/r", "/other/acme-legacy", "wt/x")` → `OriginManual`
  - `("/r", "/r/.claude/worktrees/a/b", "wt/b")` → `OriginManual` (not a direct child)
- [ ] **Step 2:** `go test ./internal/workbenchgit -run TestWorktreeOrigin` → FAIL (undefined).
- [ ] **Step 3: Implement** with `filepath.Join(topLevel, worktreesDir)` as the parent, `filepath.Dir(root)` equality, subagent = base matches `^agent-[0-9a-f]+$`, placed = branch has prefix `worktreeBranchRoot`.
- [ ] **Step 4:** same command → PASS.
- [ ] **Step 5: Commit** `feat(workbenchgit): WorktreeOrigin classifier (board #1107)`.

### Task 2: Item keys `origin`, `last_commit_at`, `merged`, bundle `worktree`

**Depends on:** Task 1

**Files:**
- Modify: `internal/sessioncleanup/result.go` (`Item`), `internal/sessioncleanup/inventory.go` (repo read: tips' committer dates, merged sets), `internal/sessioncleanup/plan.go` (`evaluateWorktree`, `evaluateBranch`, `bundleItems`, `extraItems` order)
- Test: `internal/sessioncleanup/plan_test.go`, `cmd/workbench_cleanup_test.go`

**Interfaces:**
- Consumes: `workbenchgit.WorktreeOrigin`.
- Produces: `Item.Origin string` (`json:"origin"`: `"session"` when `Owner` names a session, else the `WorktreeOrigin` value for worktrees, `""` for branches/lsreg/process), `Item.LastCommitAt string` (`json:"last_commit_at"`, RFC 3339 UTC, `""` unknown), `Item.Merged bool` (`json:"merged"`), `Item.Worktree string` (`json:"worktree,omitempty"`, bundle `lsreg` items only = the owning root).

- [ ] **Step 1: Failing tests** in `plan_test.go` on the existing fake git:
  - `TestSweepItemsCarryOrigin` — a subagent worktree, a placed one, a hand-made one, one with a recorded owner session → `subagent`, `placed`, `manual`, `session`; branch items `""`.
  - `TestItemsCarryLastCommitAndMerged` — tip committed at a fixed time → `last_commit_at == "2026-09-01T10:00:00Z"`; a branch merged only into `origin/main` (local `main` behind) → `merged == true`; an unmerged pushed branch → `false`.
  - `TestBundleItemsNameTheirWorktree` — a `.app` under a removable worktree → its `lsreg:` item has `worktree == <root>`; a stale entry has `worktree == ""`.
  - `TestBundlesAreFoundBeforeSizes` — a recording `Sizer` and LS fake record call order: every `Bundles(root)` call precedes the first `Size` call.
- [ ] **Step 2:** `go test ./internal/sessioncleanup -run 'Origin|LastCommit|BundleItems|BundlesAreFound'` → FAIL.
- [ ] **Step 3: Implement.** Read committer dates once: `git for-each-ref --format=%(refname:short)%00%(committerdate:iso-strict) refs/heads`; a detached worktree HEAD gets `git log -1 --format=%cI <sha>`. `merged` = tip is an ancestor of `refs/heads/<default>` or `refs/remotes/origin/<default>` (one `for-each-ref --merged` per existing ref, unioned). In `extraItems`, collect bundles (and session-mode orphans) before `measureAll`; item order in the output is unchanged.
- [ ] **Step 4:** same command → PASS; `go test ./internal/sessioncleanup` → PASS.
- [ ] **Step 5: Pin the keys** — extend the cmd JSON test (the one decoding `--json` output; add `TestCleanupCmd_JSONItemKeys` if none pins item keys) to assert an item's key set is exactly `key kind name branch bytes bytes_known action reason detail done error owner origin last_commit_at merged` (+ `worktree` on a bundle item). `go test ./cmd -run TestCleanupCmd` → PASS.
- [ ] **Step 6: Commit** `feat(sessioncleanup): origin, last commit, merged on items (board #1107)`.

### Task 3: Progress observer in `sessioncleanup`

**Depends on:** Task 2

**Files:**
- Create: `internal/sessioncleanup/events.go`
- Modify: `internal/sessioncleanup/plan.go`, `internal/sessioncleanup/apply.go`
- Test: `internal/sessioncleanup/events_test.go`

**Interfaces:**
- Produces:
  ```go
  type Observer interface {
      Listed(items []Item)          // candidates before any catch; Action ""
      Checked(item Item)            // an item with its action/reason (bundles of a worktree right after it)
      Sized(key string, bytes int64, known bool)
      Removing(key string)          // apply only
      Removed(item Item)            // apply only: the item as it ended (done, kept or error)
  }
  ```
  `Request.Observer Observer` (nil = no events; existing behaviour).

- [ ] **Step 1: Failing tests** with a recording observer:
  - `TestObserverOrderInASweep` — events are `Listed` first; every `Checked` key appears in `Listed` or is a bundle of a listed worktree; `Sized` only for `remove` worktrees and after every worktree's `Checked`; the final `PlanResult` items equal the union of the last-seen versions.
  - `TestListedHoldsWorktreesAndBranchOnlyRows` — `Listed` has the listed worktrees and, in the sweep, only branches not checked out in any worktree; a branch of a removable worktree arrives later through `Checked`; a branch of a kept worktree never arrives (matches today's plan).
  - `TestApplyReportsEachItem` — `Apply` with two worktrees ticked: `Removing(k)` precedes `Removed(item)` for each, in removal order; a kept-at-recheck item arrives as `Removed` with its keep reason.
  - `TestNilObserverChangesNothing` — `PlanResult` with and without an observer returns equal results.
- [ ] **Step 2:** `go test ./internal/sessioncleanup -run 'Observer|Listed|ApplyReports|NilObserver'` → FAIL.
- [ ] **Step 3: Implement.** `Listed` at the start of `evaluate` (after `newBuilder`); `Checked` after each `evaluateWorktree` / `evaluateBranch` and for each bundle/orphan item; `Sized` inside `measureAll` after each walk (observer calls serialised with a mutex — `measureAll` runs 4 at a time); in apply, `Removing` before `act`, `Removed` after it. The re-check evaluations inside apply (`fresh`) pass no observer.
- [ ] **Step 4:** same → PASS; `go test ./internal/sessioncleanup` → PASS.
- [ ] **Step 5: Commit** `feat(sessioncleanup): progress observer for plans and applies (board #1107)`.

### Task 4: `--stream` JSON lines

**Depends on:** Task 3

**Files:**
- Modify: `cmd/workbench_cleanup.go` (flag, `checkCleanupFlags`, `runWorkbenchCleanup`)
- Create: `cmd/workbench_cleanup_stream.go`
- Test: `cmd/workbench_cleanup_test.go`

**Interfaces:**
- Consumes: `sessioncleanup.Observer`.
- Produces (stdout, one JSON object per line, keys pinned):
  `{"event":"listed","items":[…]}`, `{"event":"checked","item":{…}}`, `{"event":"sized","key":"…","bytes":N,"bytes_known":B}`, `{"event":"removing","key":"…"}`, `{"event":"removed","item":{…}}`, `{"event":"done","plan":<the --json Result object>}`. On a failure no `done` line; the error and exit code as today.

- [ ] **Step 1: Failing tests:**
  - `TestCleanupCmd_StreamNeedsJSON` — `--stream` without `--json` → exit 2, "--stream needs --json".
  - `TestCleanupCmd_StreamPlanLines` — sweep plan on the fake deps: first line `event=listed`, last line `event=done`, every line valid JSON with exactly its pinned keys, `done.plan` equals the non-streamed `--json` output object.
  - `TestCleanupCmd_StreamApplyLines` — apply with `--item`: `removing`/`removed` pairs between `listed…` and `done`.
  - `TestCleanupCmd_StreamFailureHasNoDone` — a deps git failure after listing → no `done` line, non-zero exit.
- [ ] **Step 2:** `go test ./cmd -run TestCleanupCmd_Stream` → FAIL.
- [ ] **Step 3: Implement** a `streamObserver{enc *json.Encoder; mu sync.Mutex}` writing each event with one `Encode` (newline-terminated) under the mutex; `done` written by `runWorkbenchCleanup` instead of `writeJSON` when streaming.
- [ ] **Step 4:** same → PASS; `go test ./cmd -run 'TestCleanupCmd|TestProj18'` → PASS.
- [ ] **Step 5: Commit** `feat(cmd): workbench cleanup --stream (board #1107)`.

### Task 5: Where the plan's time goes — measure, then the cheap speed-up

**Depends on:** Task 3

**Files:**
- Modify (only if Step 2 says so): `internal/sessioncleanup/plan.go` (`worktreeItems`)
- Test: `internal/sessioncleanup/plan_test.go`

- [ ] **Step 1: Measure** on a copy of the live database, never the live file: the data root is `$HOME/.local/share/watchtower` (`config.DataRoot`) and the config `$HOME/.config/watchtower`, so copy the active workspace's `watchtower.db*` and the config into a scratch `HOME` with the same layout and run the repo-built binary with `HOME=<scratch>`: `go run . workbench cleanup --workbench <id> --sweep --no-size --json` (the workbench folder stays the real repository — the plan only reads it), with temporary timing logs around `newBuilder` (repo read, `loadFacts`: lsof scan, owners), the per-worktree catches (W4 `git status`, W9 walk) and branch catches. Write the numbers in the task's done comment. Remove the timing code.
- [ ] **Step 2: Decide.** If the per-worktree catches take ≥ 50 % of the no-size time, do Steps 3–5; otherwise commit nothing and say so in the done comment.
- [ ] **Step 3: Failing test** `TestWorktreeChecksKeepOrderInParallel` — 8 fake worktrees whose `git status` fakes sleep in reverse order → items come out in listing order, each with the right action; `-race` clean (`go test -race ./internal/sessioncleanup -run TestWorktreeChecksKeepOrderInParallel`).
- [ ] **Step 4: Implement** `checkWorkers = 4` in `worktreeItems`: evaluate listed worktrees concurrently into an indexed slice; `markStaying`/`checkedOutIn` and `Checked` events applied in listing order after each result (keep the maps single-writer).
- [ ] **Step 5:** `go test ./internal/sessioncleanup` → PASS. Commit `perf(sessioncleanup): check worktrees four at a time (board #1107)`.

### Task 6: Core — decode the new keys and the stream events

**Depends on:** none (the JSON shape is fixed by the spec §6 and Task 4's Interfaces)

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SessionCleanup.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SessionCleanupEvent.swift`
- Test: `WatchtowerDesktop/Tests/Core/SessionCleanupPlanDecodingTests.swift`, `WatchtowerDesktop/Tests/Core/SessionCleanupEventTests.swift`

**Interfaces:**
- Produces: on `SessionCleanupItem`: `origin: SessionCleanupOrigin` (`enum SessionCleanupOrigin: String { case session, subagent, placed, manual, none = "" }`, unknown raw → `.none`), `lastCommitAt: Date?`, `merged: Bool`, `worktree: String` (`""` when absent); all `decodeIfPresent` so old JSON still decodes.
  `enum SessionCleanupEvent: Equatable, Sendable { case listed([SessionCleanupItem]); case checked(SessionCleanupItem); case sized(key: String, bytes: Int64, known: Bool); case removing(String); case removed(SessionCleanupItem); case done(SessionCleanupPlan) }` with `static func decode(line: String) -> SessionCleanupEvent?` (nil for a bad line or an unknown event).

- [ ] **Step 1: Failing tests:** `testNewItemKeysDecode` (each key and its absence), `testEachEventDecodes` (one line per event), `testUnknownEventAndBadLineAreSkipped` (`{"event":"later"}` and `not json` → nil).
- [ ] **Step 2:** `make test-swift FILTER='SessionCleanupPlanDecodingTests|SessionCleanupEventTests'` → FAIL.
- [ ] **Step 3: Implement.** `lastCommitAt` via `ISO8601DateFormatter` (internet date time).
- [ ] **Step 4:** same → PASS; `make lint-swift` clean.
- [ ] **Step 5: Commit** `feat(core): cleanup item keys and stream events (board #1107)`.

### Task 7: Core — `CleanupScreenModel`

**Depends on:** Task 6

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/CleanupScreenModel.swift`
- Test: `WatchtowerDesktop/Tests/Core/CleanupScreenModelTests.swift`

**Interfaces:**
- Consumes: `SessionCleanupItem`, `SessionCleanupPresentation` (reason words, `totalText`).
- Produces:
  ```swift
  package struct CleanupRow: Identifiable, Equatable { id: String /* worktree or branch key */; title; subtitle; ownerText; origin; sizeText; bytes: Int64?; lastCommitAt: Date?; state: CleanupRowState; branchNote: String? ; canChoose: Bool; applyKeys: [String] }
  package enum CleanupRowState: Equatable { case checking, merged, pushed, kept(String), changedSinceCheck(String), removing, failed(String) }
  package struct CleanupFilters: Equatable { var search = ""; var kind: Kind = .all /* .all .worktrees .branches */; var age: Age = .any /* .any .days7 .days30 .days90 */; var owner: Owner = .any /* .any .session .subagent .placed .manual */; var mergedOnly = false }
  package enum CleanupSort: Equatable { case size, name, lastCommit } // + ascending flag
  package struct CleanupScreenModel {
      package init(items: [SessionCleanupItem], checking: Set<String>, sizing: Set<String>, now: Date)
      package func rows(filters: CleanupFilters, sort: CleanupSort, ascending: Bool) -> (canGo: [CleanupRow], kept: [CleanupRow])
      package func keptSummary() -> String              // "5 unpushed commits · 3 recent sessions · 1 in use"
      package func selectAll(filters: CleanupFilters, into ticks: Set<String>) -> Set<String>
      package func tickRange(from: String, to: String, in rows: [CleanupRow], on: Bool, ticks: Set<String>) -> Set<String>
      package func liveTicks(_ ticks: Set<String>) -> Set<String>   // drops ids that can no longer be chosen
      package func applyKeys(for ticks: Set<String>) -> [String]   // known kinds only
      package func totalText(for ticks: Set<String>) -> String      // "3 worktrees, 3 branches · ~25 GB" / "Nothing selected"
      package func confirmationTitle(for ticks: Set<String>) -> String // "Remove 3 worktrees and 3 branches (~25 GB)?"
  }
  ```

- [ ] **Step 1: Failing tests** (fixture items, `acme` names):
  - `testWorktreeRowCarriesItsBranchAndBundles` — worktree + removable branch + 2 bundles → one row, `applyKeys` = worktree, branch, both `lsreg:` keys; the branch has no row of its own.
  - `testKeptBranchIsNotSentWithItsWorktree` — branch item `keep/checked_out` → row `branchNote == "branch kept — checked out elsewhere"`, `applyKeys` = worktree (+ bundles) only.
  - `testBranchOnlyAndStaleEntryRows` — a branch with no worktree → own row, subtitle "branch only"; a stale `lsreg` (no `worktree`) → row titled "LaunchServices entry".
  - `testCheckingRowsCannotBeChosen` — key in `checking` → `state == .checking`, `canChoose == false`, excluded by `selectAll`.
  - `testKeptGoLastWithReasons` — kept rows only in `kept`; `keptSummary()` counts by reason in words.
  - `testFiltersAndSelectAll` — older than 30 days + merged only → `selectAll` ticks exactly the matching choosable rows.
  - `testHiddenTicksCountAndStaleTicksDrop` — a tick hidden by a filter stays in `totalText` and `applyKeys`; `liveTicks` drops an id whose row is now kept.
  - `testRangeSkipsRowsThatCannotBeChosen` — `tickRange` over 5 rows with one checking row in between ticks the other 4.
  - `testDefaultSortIsSizeDescendingUnmeasuredLast`.
  - `testOwnerText` — session owner → "“Billing retry” · finished 9 days ago"; origins → "Subagent" / "Session deleted" / "Made by hand"; branch-only → "—".
  - `testTotalsAndConfirmation` — exact copy from Global Constraints; "some sizes unknown" when any ticked worktree is unmeasured.
- [ ] **Step 2:** `make test-swift FILTER=CleanupScreenModelTests` → FAIL.
- [ ] **Step 3: Implement** in `CleanupScreenModel.swift` (pairing by `item.branch` for worktrees, by `item.worktree` for bundles).
- [ ] **Step 4:** same → PASS; `make lint-swift` clean.
- [ ] **Step 5: Commit** `feat(core): CleanupScreenModel rows, pairing, filters, totals (board #1107)`.

### Task 8: `SessionCleanupCenter` — streamed runs with run ids

**Depends on:** Task 6

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/SessionCleanupCenter.swift`
- Test: `WatchtowerDesktop/Tests/SessionCleanupCenterTests.swift`

**Interfaces:**
- Consumes: `SessionCleanupEvent.decode(line:)`, `CodeCLIProcess.launch(executable:arguments:environment:)`, its stdout lines and `terminateGroup(grace:)`.
- Produces:
  - `protocol SessionCleanupStreaming { func streamCleanup(args: [String], environment: [String: String]) throws -> SessionCleanupStream }` with `struct SessionCleanupStream { let lines: AsyncStream<String>; let exit: () async -> Int32; let stop: () -> Void }`; the production conformer wraps `CodeCLIProcess`; tests use a scripted fake.
  - `struct SessionCleanupProgress: Equatable { var runID: Int; var items: [SessionCleanupItem]; var checking: Set<String>; var sizing: Set<String>; var stage: Stage /* .listing, .checking(done: Int, of: Int), .sizing(done: Int, of: Int), .ready(at: Date), .applying, .done(SessionCleanupPlan), .failed(String) */ }`
  - `func progress(for scope: SessionCleanupScope) -> SessionCleanupProgress?`
  - `func startStreamedPlan(_ scope: SessionCleanupScope) -> Task<Void, Never>` (stops a running plan of the scope first), `func startStreamedApply(_ scope: SessionCleanupScope, items: [String]) -> Task<Bool, Never>`
  - `func isApplying(workbenchID: Int64) -> Bool` (any scope of the workbench, Delete and Clean Up included).
  - Args add `--stream`; the environment rule (no `WATCHTOWER_TERMINAL_SESSION_ID`) unchanged; `cleanupHintTimeLimit` watchdog applies to plans.

- [ ] **Step 1: Failing tests** (scripted fake stream):
  - `testListedRowsShowBeforeDone` — after the `listed` line, `progress.items` has the rows and `stage == .checking(done: 0, of: n)`.
  - `testCheckedAndSizedFillIn` — `checked` replaces the item by key and leaves `checking`; `sized` sets bytes and leaves `sizing`.
  - `testDoneReplacesRows` — `done.plan` items replace the partial rows; `stage == .ready`.
  - `testStaleRunLinesAreDropped` — start plan 1, emit `listed`; start plan 2 (Refresh) → plan 1's `stop` was called; plan 1's later `checked` line changes nothing in plan 2's rows.
  - `testStreamWithoutDoneIsAFailedPlan` — lines end after `listed`, exit 1 → `stage == .failed(message)`, the listed rows stay.
  - `testOneApplyPerWorkbench` — while a session-scope apply runs, `isApplying(workbenchID:)` is true and `startStreamedApply(.workbench(id), …)` returns false without launching.
  - `testApplyEventsMoveRows` — `removing` marks the row `.removing`; `removed` with `done` drops it; a kept `removed` keeps it with its reason.
- [ ] **Step 2:** `make test-swift FILTER=SessionCleanupCenterTests` → FAIL.
- [ ] **Step 3: Implement**; the run id is the existing `runSerials` counter; a line is applied only when its run id equals the scope's current one. Coalesce view updates (apply decoded events in batches at most every 100 ms).
- [ ] **Step 4:** same → PASS; existing `SessionCleanupCenterTests` still pass; `make lint-swift` clean.
- [ ] **Step 5: Commit** `feat(desktop): streamed cleanup runs with run ids (board #1107)`.

### Task 9: View model — the screen as page state, one place, guards moved

**Depends on:** Tasks 4, 7, 8

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+CleanupSweep.swift`, `WorkbenchesViewModel+SessionCleanup.swift`, `WorkbenchesViewModel.swift`
- Modify: `docs/inventory/workbench.md` (PROJ-18 amendment, guard list)
- Test: `WatchtowerDesktop/Tests/SessionCleanupSweepTests.swift`, `WatchtowerDesktop/Tests/WorkbenchSessionDeleteTests.swift`

**Interfaces:**
- Consumes: Task 7 model, Task 8 center API.
- Produces: `struct CleanupScreenState: Equatable { var scope: SessionCleanupScope; var ticks: Set<String>; var filters: CleanupFilters; var sort: CleanupSort; var ascending: Bool; var lastClicked: String?; var resultDismissed: Bool }`; `var cleanupScreens: [Int64: CleanupScreenState]` (in memory only); `func openCleanupScreen(projectID: Int64, sessionID: Int64? = nil)`, `func closeCleanupScreen(projectID: Int64)`, `func widenCleanupScope(projectID: Int64)`, `func refreshCleanup(projectID: Int64)`, `func applyCleanupScreen(projectID: Int64) async -> Bool`, `func retryCleanup(projectID: Int64)`; `func deleteAndCleanUpBlocked(projectID: Int64) -> Bool`.

- [ ] **Step 1: Failing / rewritten tests:**
  - `testSweepAppliesOnlyTickedKeys` (PROJ-18 guard, rewritten per spec §8, owner-approved ask #633): ticking the worktree row of `…/old` sends exactly `--item=worktree:…/old --item=branch:feat/old` (its removable branch) plus its bundle keys; a kept item, a stray key and an unknown kind are never sent.
  - `testSweepTicksNothingByDefault`, `testSweepNeverAppliesUnknownKinds`, `testSweepSurvivesLeavingThePage`, `testSheetApplyMarksTheRowBusy`, `testSheetNeverAppliesUnknownKinds` — moved to the screen API, assertions unchanged (names kept).
  - `testSessionScopeTicksNothing` — opening from a session row plans `--session N --stream`, ticks are empty.
  - `testWideningTheScopePlansTheWorkbench` — `widenCleanupScope` → a `--sweep --stream` plan, the session plan stopped.
  - `testScreenStateIsNeverSaved` — after open, `WorkspaceLayout` for the workbench is unchanged and encodes no cleanup value.
  - `testDeleteAndCleanUpWaitsForTheScreensApply` — while the screen's apply runs, `deleteAndCleanUpBlocked` is true; Delete Only still works.
  - `testRetryAfterAFailedApplyReappliesTheTicks` / `testRetryAfterAFailedPlanPlansAgain`.
  - Hint tests that opened the sheet now open the screen (`testOpeningTheSweepAnswersTheHint`, `testSheetOpenedFromTheHintReusesItsPlan` renamed only where the word "Sheet" names the removed view — assertions unchanged).
- [ ] **Step 2:** `make test-swift FILTER='SessionCleanupSweepTests|WorkbenchSessionDeleteTests'` → FAIL.
- [ ] **Step 3: Implement**; remove `WorkbenchSweepSheet.swift` and `SessionCleanupSheet.swift` and their view-model entry points that only they used.
- [ ] **Step 4:** same → PASS; `make lint-swift` clean.
- [ ] **Step 5: Amend PROJ-18** in `docs/inventory/workbench.md`: *2026-10-26 amendment (board #1107, owner approved ask #633):* "On the Clean Up screen a worktree row is the worktree, its branch when that branch item is `remove`, and its bundles' LaunchServices entries; the apply sends exactly the ticked rows' keys so expanded, of known kinds only. Nothing is ticked by itself in either scope." Update the guard list (renamed/moved tests).
- [ ] **Step 6: Commit** `feat(desktop): Clean Up screen state, one place to pick, PROJ-18 amendment (board #1107)`.

### Task 10: Views — `CleanupScreenView`

**Depends on:** Task 9

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Workbench/Cleanup/CleanupScreenView.swift`, `CleanupRowView.swift`, `CleanupToolbar.swift`, `CleanupFooter.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchPageView.swift` (cover the workspace area; drop `sweeping`), `WorkbenchHeaderControls.swift` (⋯ menu opens the screen; tabs show none on and a **Clean Up ✕** crumb while open), `TerminalSessionRow.swift` (Clean Up… opens the screen in session scope), `SessionActionDialogs.swift` (no sheet), `SessionDeleteConfirmSheet.swift` (Delete and Clean Up disabled + "Another cleanup is running" when blocked)
- Test: `WatchtowerDesktop/Tests/CleanupScreenViewTests.swift`

**Interfaces:**
- Consumes: Task 9 view-model API; `CleanupScreenModel`.

- [ ] **Step 1: Failing test** `testScreenCoversTheWorkspaceWithoutRecreatingIt` — host `WorkbenchPageView` on a fixture workbench with one terminal pane, open then close the screen: the pane's terminal view object identity (the `TerminalCenter` view for the session) is the same before and after, and the session was never detached.
- [ ] **Step 2:** `make test-swift FILTER=CleanupScreenViewTests` → FAIL.
- [ ] **Step 3: Implement** to match the mockup states A–G: `ZStack` over `WorkspaceAreaView` (the area stays in the tree, hidden from hit-testing and accessibility while covered); header title + subtitle; progress line / result bar; toolbar (session chip with ✕ in session scope, search `SearchField`, `KitSegmentedPicker` kind, age and owner menus with `MenuLabel`, Merged only toggle chip); column header of `.kitQuiet` sort buttons; `LazyVStack` of `.kitRow` rows under `SectionHeader` groups (Kept folded, its summary in the header); checkbox toggles; ⇧-click range, ⌘A, Esc; footer with Select All That Can Go / Clear / total / **Clean Up…** (`.kitDestructive`); confirmation sheet (`.kitSecondary` Cancel, `.kitDestructive` Remove); empty state from `TabEmptyState`. Colours only from `Tone`.
- [ ] **Step 4:** same → PASS; `make lint-swift` clean; `make test-swift FILTER='SessionCleanup|WorkbenchSessionDelete|CleanupScreen'` → PASS.
- [ ] **Step 5: Commit** `feat(desktop): Clean Up screen (board #1107)`.

### Task 11: Design shots A–G and the side-by-side check

**Depends on:** Task 10

**Files:**
- Create: `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+Cleanup.swift`
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotCatalog.swift`

- [ ] **Step 1:** Register seven shots `workbench-cleanup-a` … `-g` on fixture data mirroring the mockup rows (`acme-app`, the mockup's names and sizes).
- [ ] **Step 2:** `make desktop-shots DESKTOP_SHOTS=<scratch dir>` → 14 PNGs (light/dark).
- [ ] **Step 3:** Put each shot beside `docs/design/mockups/worktree-cleanup/screen-<theme>.png`'s matching frame; list every difference; fix each or record why not. Repeat Step 2 after fixes.
- [ ] **Step 4: Commit** the fixtures (not the PNGs) `test(desktop): design shots of the Clean Up screen (board #1107)`.
- [ ] **Step 5 (controller):** owner check ask with the shots, the mockup frames and the difference list, before the PR merges (spec §9).

### Task 12: Guide and notes

**Depends on:** Task 10

**Files:**
- Modify: `docs/guide/features/workbench/worktrees-and-cleanup.md`, `docs/features/workbench.md` (session cleanup paragraph), `CLAUDE.md` (the Workbench feature line: "session cleanup (… `SessionCleanupCenter` — Delete and Clean Up, the Clean Up screen …)")

- [ ] **Step 1:** Rewrite the guide's cleanup "Using it" paragraphs for the screen (opening it from the ⋯ menu or a session's Clean Up…, the session chip, Select All That Can Go, filters, confirmation, leaving while it works), per `docs/guide/WRITING.md`; drop the two sheets' text.
- [ ] **Step 2:** `go test ./docs/guide` → PASS (`TestFeaturePagesUnder8KB`; the page was 5.5 KB). Over the cap → move the screen's text to `docs/guide/features/workbench/cleanup-screen.md`, link it, rerun.
- [ ] **Step 3:** Update the feature note and the CLAUDE.md line (board #1107, `--stream`, `CleanupScreenModel`, one place to pick).
- [ ] **Step 4: Commit** `docs: Clean Up screen in the guide and notes (board #1107)`.
