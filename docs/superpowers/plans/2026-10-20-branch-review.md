# Branch Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the workbench's Changes pane into **Branch review**: it names the session, its branch and worktree; it shows up in the header only when there is something to review; it has one honest empty state and no model call on an empty diff; it is built from the design kit.

**Architecture:** Desktop only. A pure `ReviewIdentityPresentation` in WatchtowerCore turns the session, its place, its git status and the round into the identity bar's lines and the header button's visibility. `ReviewChangesModel` gains an empty-diff overview guard, one retry on a busy write, quiet state writes and next/previous unviewed file. The pane's views are rebuilt on the kit; the header capsule loses Changes and gains a contextual **Review** button.

**Tech Stack:** SwiftUI (macOS 14), GRDB, WatchtowerCore, DesignKit, ViewInspector tests, `DesignShotCatalog`.

**Spec:** `docs/superpowers/specs/2026-10-20-branch-review-design.md` (approved: asks #446, #447, #449). Visual design: claude.ai canvas "Branch Review Design", https://claude.ai/artifact/8F8DfmZ5PgJU5UrvJ1nnGR (artboards A–D).

## Global Constraints

- No Go change, no migration, no new CLI. `WorkspacePane.changes`, `WorkspaceView.changes`, `ReviewChangesModel` and the stored layout keys keep their names.
- Names: pane and pane picker **Branch review**; header button **Review**; row menu **Review Branch**.
- Comparison is unchanged: the work tree vs the merge-base with the default branch.
- New view code follows `docs/design/desktop-style-guide.md` and passes `make lint-swift` (`kit_*` rules): `Spacing`/`Radius`/`Fill` tokens, `.kitPrimary` only on Send review, `KitSegmentedPicker` for segmented choices, `.kitIcon` for icon buttons, no `Divider()` between rows, no `.pickerStyle(.segmented)`.
- Inventory REVIEW-01..05 and PROJ-12 stay as they are; no guard test is relaxed.
- Fixture data only (`acme`, `example.com`) in tests and shots.

## Review Focus

1. A session whose place is **unknown or stale** (not read yet) — the identity bar still shows its title and state and reads the place as "main folder" (`SessionPlacePresentation`'s rule), never a blank line; the header button falls back to the main folder's status. → Task 1 test `testUnknownPlaceReadsAsMainFolder`.
2. A **detached HEAD** or **unborn** branch — the branch line says `detached at <sha>` / the unborn name and never shows `→ main` for an empty base. → Task 1 test `testDetachedHeadAndEmptyBase`.
3. A refresh that **empties a diff** while an overview is on screen or loading — the overview goes `.idle`, no model call starts, and a running model call's result is dropped. → Task 2 test `testRefreshToAnEmptyDiffDropsTheOverview`.
4. A **busy database twice in a row** on a Viewed toggle — the owner sees the error banner once, the Viewed mark is not shown as saved. → Task 2 test `testViewedBusyTwiceShowsTheError`.
5. **Two review panes** of two sessions side by side — the pane picker titles differ (`Branch review · <session title>`). → Task 4 test `testPanePickerTitleNamesTheSession`.

---

### Task 1: `ReviewIdentityPresentation` — the identity bar's lines and the Review button rule

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Review/ReviewIdentityPresentation.swift`
- Test: `WatchtowerDesktop/Tests/Core/ReviewIdentityPresentationTests.swift`

**Interfaces:**
- Consumes: `SessionPlace`, `WorkbenchGitStatus`, `SessionPlacePresentation.placeLabel`, `ReviewRoundInfo` (`baseLabel`, `baseSha`), `ReviewDiffFile` (`additions`, `deletions`), `ReviewContextItem`.
- Produces:
  - `package enum ReviewIdentityPresentation`
  - `package struct BranchLine: Equatable { branch: String; base: String?; baseHelp: String; size: String?; uncommitted: String?; place: String; onDefaultBranch: Bool }`
  - `package struct ForLine: Equatable { first: ReviewContextItem; more: Int }`
  - `package static func status(place: SessionPlace, mainStatus: WorkbenchGitStatus?) -> WorkbenchGitStatus?` — the worktree's own status for `.worktree`, `mainStatus` otherwise.
  - `package static func branchLine(place: SessionPlace, status: WorkbenchGitStatus?, round: ReviewRoundInfo?, files: [ReviewDiffFile], stale: Bool) -> BranchLine`
  - `package static func forLine(_ items: [ReviewContextItem]) -> ForLine?`
  - `package static func showsReviewButton(isAgent: Bool, status: WorkbenchGitStatus?, paneOnScreen: Bool) -> Bool`
  - `package static func defaultBranchNames: Set<String>` = `["main", "master"]`

Rules (from spec §4.2, §5):
- `branch`: `WorkbenchBranchPresentation.label(status).text`; detached → `detached at <head>`.
- `base`: `round.baseLabel` with a leading `origin/` removed; nil when `baseLabel` is empty (empty tree) or there is no round. `baseHelp` = `baseSha` or `"empty tree"`.
- `onDefaultBranch` = the branch equals the base, or (no round) the branch is in `defaultBranchNames`. When true the size slot reads `On <branch> — only uncommitted edits are reviewed` and `base` is nil.
- `size`: `"N file(s) · +a −d"` over `files` (collapsed files included); nil when `files` is empty.
- `uncommitted`: `"M uncommitted"` when `status.dirty` and `status.changes > 0`; nil otherwise.
- `place`: `"worktree <name>"` for `.worktree`, `"worktree removed"` for `.removed`, `"main folder"` for `.main`/`.unknown`.
- `showsReviewButton`: `paneOnScreen` → true; not an agent → false; `status == nil` → false; `status.dirty` → true; detached → true; branch not in `defaultBranchNames` → true; else false.

- [ ] **Step 1: Write the failing tests** — `testWorktreeBranchAgainstMain` (`feature/x`, base `origin/main` → base `main`, place `worktree x`, size `8 files · +212 −40`, uncommitted `2 uncommitted`); `testOnTheDefaultBranch` (branch `main`, base `origin/main` → `onDefaultBranch`, base nil, size slot text above); `testUnknownPlaceReadsAsMainFolder`; `testDetachedHeadAndEmptyBase` (`detached at abc1234`, empty `baseLabel` → base nil, help `empty tree`); `testForLine` (0 items → nil; 3 items → first + `more: 2`); `testReviewButtonRule` (one assertion per bullet above).
- [ ] **Step 2: Run** `make test-swift FILTER=ReviewIdentityPresentationTests` — expect FAIL (type missing).
- [ ] **Step 3: Implement** the type in the file above, pure, no SwiftUI.
- [ ] **Step 4: Run** the same filter — expect PASS. `make lint-swift`.
- [ ] **Step 5: Commit** `feat(review): identity presentation for Branch review (#712)`.

### Task 2: `ReviewChangesModel` — no overview on an empty diff, busy retry, quiet state writes, next unviewed

**Depends on:** none.

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/ReviewChangesModel.swift` (`startOverview` ~890, `loadOverview` ~614, `write` ~800, `writeState` ~810, `flushState` ~770)
- Test: `WatchtowerDesktop/Tests/ReviewChangesModelTests.swift`

**Interfaces:**
- Produces: `var hasChanges: Bool { !files.isEmpty }`; `func nextUnviewed(after path: String?) -> String?`; `func previousUnviewed(before path: String?) -> String?` (over `files` in list order, collapsed files skipped, wrapping; nil when every shown file is viewed); `static let busyRetryDelay: Duration = .milliseconds(300)`.

Behaviour:
- `startOverview`: when `files.isEmpty`, set `overview = .idle`, cancel a cached read, clear `generationID`'s pending follow-up so a model call landing later is ignored (its tree no longer matches — reuse the existing "tree moved" drop), and return without calling the CLI. Covers open, refresh, `setMode(.deep)`, Make overview and Retry.
- `write` and `writeState`: on `DatabaseError` with `resultCode == .SQLITE_BUSY` retry once after `busyRetryDelay`; a second busy throws as today.
- `flushState` (pace, mode/phase position): a failure is logged (`Logger(subsystem: "watchtower", category: "review")`) and never sets `lastError`; the next flush writes it again. `setMode`/`setPhase` errors the owner pressed for still surface through `run`.

- [ ] **Step 1: Write the failing tests** — `testEmptyDiffStartsNoOverview` (stub CLI with an empty diff: no `reviewOverview` call recorded after `open()` in Quick and Deep, `overview == .idle`); `testRefreshToAnEmptyDiffDropsTheOverview` (ready overview, refresh to an empty diff → `.idle`, no new CLI call); `testMakeOverviewOnAnEmptyDiffDoesNothing`; `testViewedRetriesOnceOnBusy` (first write busy, second ok → mark saved, `lastError == nil`); `testViewedBusyTwiceShowsTheError`; `testFlushStateFailureSetsNoError`; `testNextAndPreviousUnviewed` (files A,B,C with B viewed and a collapsed D: next after A → C, after C → A, previous before A → C; all viewed → nil). Use the file's existing stub CLI and test DB helpers; inject busy through a GRDB `DatabaseError(resultCode: .SQLITE_BUSY)` thrown from a test hook on the write chain if one exists, else add `@ObservationIgnored var writeHook: ((Int) throws -> Void)?` (call index) used only by tests.
- [ ] **Step 2: Run** `make test-swift FILTER=ReviewChangesModelTests` — new tests FAIL.
- [ ] **Step 3: Implement** the behaviour above.
- [ ] **Step 4: Run** the filter — all `ReviewChangesModelTests` PASS (the overview tests at ~1032–1175 unchanged and green). `make lint-swift`.
- [ ] **Step 5: Commit** `fix(review): no overview on an empty diff, retry a busy write (#712)`.

### Task 3: The Branch review pane — identity bar, toolbar, states, file column, file header

**Depends on:** Task 1, Task 2.

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Workbench/Review/ReviewIdentityBar.swift`
- Create: `WatchtowerDesktop/Sources/Views/Workbench/Review/ReviewToolbar.swift` (replaces `ReviewChangesHeader.swift`, which is deleted; `ReviewBanner` moves here unchanged)
- Create: `WatchtowerDesktop/Sources/Views/Workbench/Review/ReviewFileHeader.swift`
- Modify: `ReviewChangesPaneView.swift`, `ReviewFileListView.swift`, `ReviewPhaseStrip.swift`, `ReviewOverviewView.swift` (compact style becomes the Summary card), `ReviewMeaningView.swift` (intent card = the For list unfolded, no second copy)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkspacePaneView.swift:163` (pass the identity inputs)
- Test: `WatchtowerDesktop/Tests/ReviewPresentationTests.swift` (view-level checks with ViewInspector), `Tests/DesignShots/DesignShotCatalog.swift` + new `Tests/DesignShots/DesignShotFixtures+Review.swift`

**Interfaces:**
- Consumes: Task 1's `ReviewIdentityPresentation`; Task 2's `hasChanges`, `nextUnviewed`, `previousUnviewed`; `SessionLiveDot`, `SessionStateLabel`, `SessionSwitcherPresentation.Row`.
- Produces: `struct ReviewSessionIdentity { row: SessionSwitcherPresentation.Row?; place: SessionPlace; stale: Bool; mainStatus: WorkbenchGitStatus?; agentName: String; openSession: () -> Void }` passed as a new `identity:` parameter of `ReviewChangesPaneView`; `ReviewIdentityBar(identity:model:)` — standalone, so the shots render it without a CLI.

Layout (artboards A, B, C; spec §4):
- Pane root: `ReviewIdentityBar`, then — only when `model.hasChanges` or a round is sent — `ReviewToolbar`, then the banners, then the body.
- Identity bar on `Surface.detail` at `Spacing.medium`: caption `BRANCH REVIEW` + `Round N · open|sent`; session line (dot, agent `OutlineTag`, title as a `.kitQuiet` button → `openSession`, state label, age); branch line; For line with **+N more** unfolding `ReviewIntentCard`s in place (moved here from `ReviewFileListView`).
- Toolbar: `KitSegmentedPicker` **All changes | Since round N−1** (from round 2), `KitSegmentedPicker` **Quick | Deep** (disabled unless open), Deep: the phase picker and the progress line; right: `.kitIcon` Inline (toggled), Refresh, ⋯ menu (Find Repeats…, Show in Finder), `.kitPrimary` **Send review (N)**; a sent round shows **Start next round** in its place (calls the existing refresh-or-next-round path).
- States: loading = identity bar + `ProgressView`; empty (`load == .ready && !model.hasChanges`) = identity bar + `ContentUnavailableView` "Nothing to review" (the feature-keyed `ContentAwareEmptyState`/`TabEmptyState` take a `SidebarDestination` and do not fit a pane state) with the subtitle from §4.6 (default branch: "No uncommitted edits in the main folder.", else "No commits past \(base) and no uncommitted edits.") and **Refresh**; failed = identity bar + reason + **Retry**; files but none picked = "Pick a file".
- File column: `panelSurface()` + `panelListStyle()`; Summary card (`.card()`) only with changes; `SectionHeader("Files", count:)` with `N · M viewed`; Folded, Undone, Resolved by the agent as today.
- File header above the diff: glyph, path (directory `.secondary`, name semibold, middle truncation), `+a −d`, `ReviewRiskBadge`, **Viewed** checkbox (`model.toggleViewed`), `.kitIcon` ‹ › (`previousUnviewed`/`nextUnviewed`, ⌥⌘↑ / ⌥⌘↓ via `.keyboardShortcut(.upArrow/.downArrow, modifiers: [.option, .command])`, disabled when nil).
- `WorkspacePaneView` builds `ReviewSessionIdentity` from `vm.session(id:)`, `vm.sessionRows([session]).first`, `vm.sessionPlaces.currentPlace(sessionID:)`, `isPlaceStale`, `vm.gitStatus[project.id]` and `vm.showTerminal(sessionID:projectID:)`.

- [ ] **Step 1: Write the failing tests** — in `ReviewPresentationTests`: `testEmptyRoundShowsOneEmptyStateAndNoToolbar` (inspect: one "Nothing to review", no "Send review", no "Files" header); `testIdentityBarNamesSessionBranchAndPlace` (text contains title, `feature/x`, `main`, `worktree x`); `testForLineFoldsExtraTargets` (`+2 more`, cards hidden until tapped); `testSentRoundOffersStartNextRound`; `testFileHeaderViewedTogglesTheMark`. Register shots `branch-review-changes` (1180×760), `branch-review-empty` (1180×520), `branch-review-deep-meaning` (1180×760) in `DesignShotCatalog` from fixtures in `DesignShotFixtures+Review.swift` (model built on the test DB and the stub CLI the model tests use; `acme` data).
- [ ] **Step 2: Run** `make test-swift FILTER='ReviewPresentationTests'` — FAIL.
- [ ] **Step 3: Implement** the views above; delete `ReviewChangesHeader.swift`.
- [ ] **Step 4: Run** `make test-swift FILTER='ReviewPresentationTests|ReviewChangesModelTests'` — PASS; `make lint-swift` clean; `make desktop-shots DESKTOP_SHOTS=<scratch dir>` and look at the three shots light and dark against artboards A, B, C (soft fills, no hard borders, nothing clipped).
- [ ] **Step 5: Commit** `feat(review): Branch review pane on the design kit (#712)`.

### Task 4: Header, pane picker and the session's entry points

**Depends on:** Task 1.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchHeaderControls.swift` (view buttons ~57, `.disabled` ~93, `help` ~330)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkspacePaneView.swift` (`picker` ~95, `title` ~135, `WorkspaceView.title` ~282)
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+Places.swift` (new `showsReviewButton(projectID:)`)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/TerminalSessionRow.swift` (menu item ~78, hover button), `WorkbenchSessionReportView.swift` (`SessionReportActions` + a **Review Branch** button), the call sites that build `SessionRowActions` / `SessionReportActions`
- Test: `WatchtowerDesktop/Tests/WorkbenchHeaderControlsTests.swift`, `Tests/SessionPlaceViewModelTests.swift`

**Interfaces:**
- Consumes: `ReviewIdentityPresentation.showsReviewButton`, `.status(place:mainStatus:)`.
- Produces: `func showsReviewButton(projectID: Int64) -> Bool` on `WorkbenchesViewModel` — target `sessionViewTarget(projectID:)`, `isAgent` from its kind, status from its place, `paneOnScreen` = `layout.isShowing(.changes)`.

Behaviour:
- Capsule: `WorkspaceView.allCases.filter { $0 != .chat && $0 != .changes }`. Right of it, only while `showsReviewButton`, a `Toggle` labelled **Review** (`plus.forwardslash.minus`), `.kitSecondary` look, on = `isShowing(.changes)`, toggling calls `showView(.changes)` / `hideView(.changes)`. Help: "Review this session's branch".
- `WorkspaceView.changes.title` = "Branch review"; the pane picker item "Branch review"; a `.changes(id)` pane's picker title = `"Branch review · \(session title)"`.
- Row menu **Review Branch**; on hover (`showsDelete`) a row in `.readyToCheck` shows a `.kitQuiet` **Review** button calling `actions.reviewChanges`.
- Session report: a **Review Branch** button beside its links, shown for agent sessions; calls `vm.showChanges(sessionID:projectID:)`.

- [ ] **Step 1: Write the failing tests** — update `testTheViewButtonsReadTerminalSessionBoardFilesAnalyticsChanges` → `…Analytics` (titles without "Changes", chevron loop bound adjusted); replace `testTheChangesButtonIsDisabledWithoutASession` with `testTheReviewButtonShowsOnlyWithSomethingToReview` (no session → absent; clean `main` → absent; dirty → present; `feature/x` → present; pane on screen → present and on); `testPanePickerTitleNamesTheSession`; in `SessionPlaceViewModelTests` `testShowsReviewButtonUsesTheWorktreeStatus`.
- [ ] **Step 2: Run** `make test-swift FILTER='WorkbenchHeaderControlsTests|SessionPlaceViewModelTests'` — FAIL.
- [ ] **Step 3: Implement** the behaviour above.
- [ ] **Step 4: Run** the filter — PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `feat(workbench): contextual Review button, Branch review names (#712)`.

### Task 5: Docs

**Depends on:** Task 3, Task 4.

**Files:**
- Modify: `docs/guide/features/workbench/diff-review.md` (title "Branch review", How it works names the pane and the identity bar, Using it step 1 = **Review** in the header / **Review Branch** in the row menu, empty section: "Nothing to review" and "The Review button is not there" replacing "The changes button is off"), `docs/guide/reference/keyboard-shortcuts.md` (pane name; ⌥⌘↑ / ⌥⌘↓ previous / next unviewed file), `docs/features/diff-reviewer.md` (a "Branch review UI (board #712)" section: names, identity bar sources, header button rule, empty-diff guard, busy retry), `CLAUDE.md` feature-notes line for the diff reviewer (mention Branch review).
- Test: `go test ./docs/guide/` (the guide's own tests: links and map).

- [ ] **Step 1:** Edit the pages per `docs/guide/WRITING.md`.
- [ ] **Step 2: Run** `go test ./docs/guide/` — PASS.
- [ ] **Step 3: Commit** `docs(review): Branch review in the guide and feature notes (#712)`.

---

**Gate (controller, once before the PR):** `make test-swift`, `make lint-all`, `make lint-diff`; the three shots attached to the PR.
