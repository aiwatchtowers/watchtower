# Workbench Header Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the workbench page's two top rows with one workbench row merged into the window's title row, and move every session-level control into a strip on top of the session's own pane.

**Architecture:** Pure layout rules (which tab is lit, what Session-off closes) go into `WorkspaceLayout` in WatchtowerCore and are tested there. A new `WorkbenchSessionStrip` view is drawn by `WorkspacePaneView` on every session-family pane. `WorkbenchTitleRow` gets a generic controls slot. `WorkbenchPageView` draws the title row itself with the slimmed `WorkbenchHeaderControls`, so the page-owned state (delete confirm, sweep sheet, New Automation) stays where it is. The automation buttons collapse into one ⚡ menu.

**Tech Stack:** SwiftUI (macOS 14), GRDB, ViewInspector tests, the DesignKit (`.kitIcon`, `SegmentedToggleStyle`, tokens).

**Spec:** `docs/superpowers/specs/2026-10-20-workbench-header-design.md`. Read it first. Its "Calls made without the owner" items 1–14 are binding.

## Global Constraints

- No new panes, no `WorkspacePane` / `WorkspaceView` case added or removed, and no change to the persisted `WorkspaceLayout` coding.
- Every control keeps today's action. Only its place and look change (spec anti-goal).
- Keyboard shortcuts unchanged: ⌃` Terminal ⇄ Workchat, ⌥⌘S panel, ⌘K Go to….
- The standalone terminal page is unchanged.
- AUTO-09 guard `testAuto09_HeaderButtonOnlyQueues` stays as strong as today: not relaxed, not renamed (inventory rule).
- PROJ-10 (branch switching) is unchanged. The branch crumb only moves.
- DesignKit tokens only, with no numeric spacing or radius literals in new code (`docs/design/desktop-style-guide.md`, lint-enforced). Strip text is `.caption`, controls `.controlSize(.small)`.
- Swift checks per task: `make test-swift FILTER=…` plus `make lint-swift` (lint-diff does not check Swift).

## Review Focus

1. **No session in the workbench yet.** The Session tab must behave as today's Terminal toggle does with none: it opens the most recent session or the empty state and never crashes. The strip must not render with a nil session. Test in Task 4.
2. **Split of two session-family panes** (terminal + its report). Session-off must not empty the page, and each strip must act on its own slot. Tests in Tasks 1 and 3.
3. **A running automation** must stay visible on the collapsed ⚡ icon. A second click must open the run, not start another. Test in Task 2.
4. **Panel hidden.** The workbench switcher still works in the title row, and with the `SessionSwitcher` gone from the title row the page still reaches other sessions through the strip. Test in Task 4.
5. **Narrow window.** The tabs never truncate, and the name and branch truncate first. Manual check in Task 5 (`make desktop-shots` at a narrow width).

---

### Task 1: Layout rules for the Session tab

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkspaceLayout.swift`
- Test: `WatchtowerDesktop/Tests/Core/WorkspaceLayoutTests.swift`

**Interfaces:**
- Produces:
  - `WorkspaceView.isSessionView: Bool`, true for `.terminal`, `.chat`, `.report`, `.changes`.
  - `WorkspaceLayout.sessionID(ofAny pane: WorkspacePane) -> Int64?` (static), the session of `.session`, `.sessionChat`, `.sessionReport` or `.changes`, else nil.
  - `WorkspaceLayout.isShowingSessionView: Bool`, true when any visible pane is session-family.
  - `mutating WorkspaceLayout.hideSessionViews()`: in a split with exactly one non-session pane visible, keeps that pane alone. Otherwise it is a no-op (a single pane, or two session-family panes, so the page never empties). An expansion is dropped the way `hide(_:)` drops it.

- [ ] **Step 1: Write the failing tests** in `WorkspaceLayoutTests`:
  - `testSessionTabLitForEverySessionFamilyPane`: a single `.session(1)`, `.sessionChat(1)`, `.sessionReport(1)` or `.changes(1)` makes `isShowingSessionView` true. `.board`, `.files` and `.analytics` alone make it false. A split of `.board` + `.session(1)` makes it true.
  - `testHideSessionViewsLeavesTheOtherPaneAlone`: a split of `.session(1)` + `.board` gives `visiblePanes == [.board]` and `isSplit == false`.
  - `testHideSessionViewsNeverEmptiesThePage`: a single `.session(1)` stays unchanged, and a split of `.session(1)` + `.sessionReport(1)` stays unchanged.
  - `testSessionIDOfAnySessionPane`: returns 7 for each of the four cases with id 7, and nil for `.board`.
- [ ] **Step 2: Run** `make test-swift FILTER=WorkspaceLayoutTests`. Expected: the new tests fail to compile.
- [ ] **Step 3: Implement** the four members above next to `isShowing(_:)` and `hide(_:)`, reusing `hide` for the removal.
- [ ] **Step 4: Run** `make test-swift FILTER=WorkspaceLayoutTests`. Expected: all pass.
- [ ] **Step 5: Commit** `feat(workbench): layout rules for the header's Session tab`.

### Task 2: One ⚡ automations menu

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/WorkbenchAutomationButtonsModel.swift`
- Modify (rename the type, keep the file): `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchAutomationButtons.swift` → `struct WorkbenchAutomationsMenu`
- Test: `WatchtowerDesktop/Tests/Core/WorkbenchHeaderAutomationButtonsTests.swift`

**Interfaces:**
- Produces:
  - `WorkbenchAutomationButtonsModel.isAnyActive(_ buttons: [AutomationHeaderButton], busy: Set<Int64>) -> Bool`.
  - `WorkbenchAutomationButtonsModel.menuTitle(for button: AutomationHeaderButton) -> String`, the label, plus " — <help>" when `help(for:)` is non-nil. This is today's overflow item text.
  - `struct WorkbenchAutomationsMenu: View { project: Workbench; vm: AutomationsViewModel; openRun: (Int64, Int64?) -> Void; onNewAutomation: (() -> Void)? }`.
  - `layout(_:maxVisible:)` is removed.

- [ ] **Step 1: Tests.**
  - Replace `testMaxFourVisibleRestInOverflowSlugOrder` with `testIsAnyActive`: false for idle buttons, true when one has `activeRunID`, true when one id is in `busy`.
  - Add `testMenuTitleCarriesTheHelp`: "Release" for a runnable button, "Release — Running — show the run" with an active run.
  - Keep every other test, AUTO-09 included, unchanged.
- [ ] **Step 2: Run** `make test-swift FILTER=WorkbenchHeaderAutomationButtonsTests`. Expected: the new tests fail to compile.
- [ ] **Step 3: Implement** the model functions. Then rewrite the view body as one `Menu`.
  - Label: `Image(systemName: "bolt")`, replaced by `ProgressView().controlSize(.mini)` while `isAnyActive`, in `.buttonStyle(.kitIcon(isOn: false))`.
  - Items: every `vm.headerButtons(projectID:)` in slug order, each `Button(menuTitle)` calling the existing `click(_:on:vm:)`, disabled while busy.
  - Then a `Divider()` and **New Automation…** when `onNewAutomation` is non-nil.
  - With no buttons and no New Automation, render nothing.
  - Help: "Automations of this workbench". Keep `.onAppear { vm.refresh() }`, the confirm alert and the failure alert exactly as today.
- [ ] **Step 4: Run** `make test-swift FILTER=WorkbenchHeaderAutomationButtonsTests` and `make lint-swift`. Expected: pass.
- [ ] **Step 5: Commit** `feat(workbench): collapse the automation header buttons into one menu`.

### Task 3: The session strip

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchSessionStrip.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkspacePaneView.swift` (body, header)
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+Places.swift` (add `ownsCodeRoot`)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchHeaderControls.swift` (extract `sessionMenu` into a shared view)
- Test: `WatchtowerDesktop/Tests/WorkbenchSessionStripTests.swift`

**Interfaces:**
- Consumes: `WorkspaceLayout.sessionID(ofAny:)` (Task 1).
- Produces:
  - `WorkbenchesViewModel.ownsCodeRoot(sessionID: Int64, projectID: Int64) -> Bool`, which is `pageSessionID(projectID:) == sessionID`.
  - `struct WorkbenchSessionsMenu: View { vm; project; slot: WorkspacePane; title: String }`, today's `sessionMenu(slot:)` items (other sessions, `NewSessionMenuItems`) under a `.caption` label "<title> ▾", accessibility label "Sessions".
  - `struct WorkbenchSessionStrip: View { vm: WorkbenchesViewModel; project: Workbench; pane: WorkspacePane; sessionID: Int64; isSplit: Bool; isExpanded: Bool }`.

- [ ] **Step 1: Write failing ViewInspector tests.** Seed as `WorkbenchHeaderControlsTests.seed()` does: two sessions, "one" and "two".
  - `testStripShowsOnEverySessionPaneOnly`: `WorkspacePaneView` for `.session`, `.sessionChat`, `.sessionReport` and `.changes` contains a `WorkbenchSessionStrip`, single and split. For `.board` it does not when single and does in a split, through the old header picker.
  - `testStripTogglesReadTerminalWorkchatReportChanges`: the toggle titles are exactly `["Terminal", "Workchat", "Report", "Changes"]`.
  - `testStripSessionsMenuActsOnItsOwnSlot`: in a split of `.session(one)` + `.board`, tapping **two** in the strip's Sessions menu gives `visiblePanes == [.session(two), .board]`.
  - `testStripTerminalWorkchatSwapsThisPaneOnly`: a single `.session(one)`. Tapping Workchat gives `[.sessionChat(one)]`.
  - `testCrumbsOnlyOnTheStripThatOwnsTheCodeRoot`: in a split of `.session(one)` + `.session(two)` with one focused, only one's strip contains `WorkbenchBranchCrumb`.
  - `testExpandAndCloseOnlyInASplit`: no "Close this pane" button when single, present in a split.
- [ ] **Step 2: Run** `make test-swift FILTER=WorkbenchSessionStripTests`. Expected: fails to compile.
- [ ] **Step 3: Implement the strip.**
  - One `HStack` row: `WorkbenchSessionsMenu`, then `WorkbenchPlaceCrumb` and `WorkbenchBranchCrumb` if `ownsCodeRoot`.
  - Then `Spacer`, a `[Terminal | Workchat]` capsule of `SegmentedToggleStyle` toggles, and Report and Changes toggles in the same capsule style but separate.
  - In a split, end with today's expand and close buttons in `.kitIcon`.
  - Spacing comes from `Spacing.*`, with a hairline divider under the strip.
  - Toggle actions are today's: `vm.showView` / `vm.hideView` for Report and Changes. Terminal and Workchat call `vm.showView(.terminal | .chat, project:)`, which already swaps in place on a single pane.
  - Changes keeps today's disabled rule.
- [ ] **Step 4: Wire `WorkspacePaneView`.** When `WorkspaceLayout.sessionID(ofAny: pane)` is non-nil, draw `WorkbenchSessionStrip` and a divider. Otherwise keep today's `if isSplit { header }`. Remove Changes and Workchat from the non-session picker's items only if they become unreachable; they stay reachable from the strip, so drop them.
- [ ] **Step 5: Run** `make test-swift FILTER='WorkbenchSessionStripTests|WorkbenchHeaderControlsTests'` and `make lint-swift`. Expected: pass. The header still has its old controls at this point, so the page is never left without a control.
- [ ] **Step 6: Commit** `feat(workbench): session strip on top of every session pane`.

### Task 4: One workbench row in the title row

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchesView.swift` (`WorkbenchTitleRow`, its call site)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchPageView.swift` (drop `header`, draw the title row)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchHeaderControls.swift`
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+Panel.swift` (add `showSession`)
- Test: `WatchtowerDesktop/Tests/WorkbenchHeaderControlsTests.swift`, `WatchtowerDesktop/Tests/WorkbenchHeaderSwitcherTests.swift`

**Interfaces:**
- Consumes:
  - `isShowingSessionView` and `hideSessionViews()` (Task 1).
  - `WorkbenchAutomationsMenu` (Task 2).
  - `WorkbenchSessionStrip` (Task 3), which now carries the sessions menu, crumbs and twin.
- Produces:
  - `struct WorkbenchTitleRow<Controls: View>` with a new trailing init parameter `@ViewBuilder controls: () -> Controls`, drawn between the name and the spacer. An extension `init` without `controls` defaults to `EmptyView`. `pressOnPage` moves to `enum WorkbenchTitleRowKeys { static func pressOnPage(_:vm:paletteOpen:) -> Bool }` (a static on a generic type needs its parameter spelled), and the three call sites in `OwnerAskKeyNavigationTests` change to it.
  - `WorkbenchesViewModel.showSession(project: Workbench) async`: shows `vm.sessionViewTarget`'s remembered mode (`layout.pane(forSession:)`), `.chat` when it is a Workchat, else `.terminal`, through `showView`.
  - `WorkbenchesViewModel.hideSessionViews(projectID: Int64)`: `beginSwitch`, then `layout.hideSessionViews()`, then persist, the same shape as `hideView`.
  - `WorkbenchPageView` gains `switcherActions: WorkbenchSwitcherActions`, `paletteOpen: Bool` and `openGoTo: () -> Void`, passed from `WorkbenchesView`, which stops drawing its own title row when a workbench page is shown.

- [ ] **Step 1: Rewrite the header tests to the new row.**
  - `testTheViewTabsReadSessionBoardFiles`: the toggles in the tab capsule are exactly `["Session", "Board", "Files"]`.
  - `testAnalyticsIsAnIconToggle`: a button with accessibility label "Analytics" toggles `.analytics` on and off in a split.
  - `testSessionTabFollowsTheLitRule`: a split of `.session` + `.board` shows Session on. Tapping it leaves `[.board]`. With a single `.board`, tapping Session shows a session pane. With a single `.session`, tapping Session again changes nothing.
  - `testSessionTabWithNoSessionDoesWhatTerminalDid`: the empty workbench from today's `testTheChangesButtonIsDisabledWithoutASession`. Tapping Session runs the same path as today's Terminal toggle (no crash, layout unchanged or the most-recent-session open).
  - `testTheMoreMenuItemsKeepTheirActions`: as today, plus **Show in Finder** first.
  - Keep `testTheSplitButtonSplitsAndThenOffersOnePane`, the clean-up, new-automation and archive tests.
  - Move `testASplitKeepsTheTerminalAndItsReportPairedWhenTheSessionChanges` to `WorkbenchSessionStripTests`, finding the strip's Sessions menu.
  - In `WorkbenchHeaderSwitcherTests`, add `testHiddenPanelTitleRowHasTheWorkbenchSwitcherAndNoSessionSwitcher`.
- [ ] **Step 2: Run** `make test-swift FILTER='WorkbenchHeaderControlsTests|WorkbenchHeaderSwitcherTests|OwnerAskKeyNavigationTests'`. Expected: the new tests fail.
- [ ] **Step 3: Implement.**
  - `WorkbenchHeaderControls` body: the tab capsule (Session, Board, Files).
    - Session is on when `isShowingSessionView`.
    - In a split, its off calls `vm.hideSessionViews(projectID:)` (a thin VM wrapper over Task 1 that persists like `hideView`).
    - Its on calls `showSession`.
    - Board and Files keep today's toggle code.
  - Then a `Spacer`, `WorkbenchAutomationsMenu`, the Analytics `.kitIcon(isOn:)`, `splitToggle` and `moreMenu` with **Show in Finder** (`NSWorkspace.shared.activateFileViewerSelecting([project.folderURL])`) as its first item.
  - The view takes `automations: WorkbenchAutomationsMenu?` in place of `automationButtons`, and `onNewAutomation` moves into the menu.
  - `WorkbenchPageView`: delete `header`. Draw `WorkbenchTitleRow(…) { WorkbenchInstallStatusIcons(…); install spinner; WorkbenchHeaderControls(…) }` and a divider, with the install-error and archive-error captions under it, unchanged.
  - The name's help text is the folder path.
  - `WorkbenchTitleRow`: drop the chevron and `SessionSwitcher` after `WorkbenchSwitcher`.
- [ ] **Step 4: Run** the Step 2 filter, then `make test-swift FILTER='WorkbenchSessionStripTests|WorkspaceLayoutTests|WorkbenchHeaderAutomationButtonsTests'` and `make lint-swift`. Expected: pass.
- [ ] **Step 5: Commit** `feat(workbench): one workbench row in the title row`.

### Task 5: Dead code, docs, screenshots

**Files:**
- Modify: the file defining `SegmentedToggleStyle` (find it with `grep -rn "struct SegmentedToggleStyle" WatchtowerDesktop/Sources`)
- Modify: `docs/features/workbench.md`, `docs/features/automations.md` (the "Header buttons" bullet), `docs/guide/features/workbench/README.md`, `docs/guide/features/workbench/workchat.md`, `docs/guide/features/workbench/session-report.md`, `docs/guide/features/agent-analytics.md` (where they name header buttons), `docs/inventory/workbench.md` and `docs/inventory/automations.md` (changelog note only)

- [ ] **Step 1:** Remove `joinsChevron`, the chevron hover plumbing and any `joinsLeft`/`joinsRight` use nothing calls any more, using `grep` to confirm no callers. Delete `WorkspaceView.help` cases that no button uses. Run `make test-swift FILTER='WorkbenchHeaderControlsTests|WorkbenchSessionStripTests'` and `make lint-swift`.
- [ ] **Step 2:** Docs. The guide pages follow `docs/guide/WRITING.md` and describe the new places: Session, Board and Files tabs, the ⚡ menu, Analytics icon, and the session strip with Terminal | Workchat, Report and Changes.
  - In `docs/features/automations.md`, change the header buttons bullet to "one ⚡ menu, every `trigger.button` recipe in slug order, running state on the icon". Drop the four-visible rule and keep the test names.
  - Inventory changelog lines, dated 2026-10-20, board #788: "controls moved (header → title row / session strip, header buttons → ⚡ menu); no contract, guard test or status changed".
- [ ] **Step 3:** Run `make desktop-shots DESKTOP_SHOTS=<scratch dir>`. Check the workbench screen at its default width and at a narrow window: the tabs never truncate, and the name and branch truncate first. Fix truncation priority with `.layoutPriority` if needed.
- [ ] **Step 4:** Gate: run `make test-swift` and `make lint-all`.
- [ ] **Step 5: Commit** `docs(workbench): header redesign — guide, feature notes, inventory notes`.
