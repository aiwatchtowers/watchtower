# Sessions panel — finished group, one-gesture delete with Undo (board #480), "Ready to check" (board #534) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finished sessions without open asks fold into "▸ N finished" at the bottom of SESSIONS; a session whose agent is not working is deleted with one ✕ or ⌘⌫ and a 5 s Undo (deferred DELETE); a session whose open asks are all checks/reviews shows a purple "Ready to check / Ready for review · ask #N".

**Architecture:** Desktop only, no Go, no migration. #534 adds `Kind.readyToCheck` to `SessionAgentStatus.effective` (between agents working and finished), fed by two new ask counts in `fetchAgentStates`. #480 adds three pure WatchtowerCore types — `SessionPanelSections` (main / group / pinned / shortcut order / neighbour), `SessionDeletePolicy` (who gets the quick path), `PendingSessionDeletes` (the Undo batch) — and wires them into `WorkbenchesViewModel` (on `AppState`, survives navigation) and the panel views. The DELETE runs unchanged, only later.

**Tech Stack:** SwiftUI / GRDB (WatchtowerCore + app target), WatchtowerKit (two known wire values).

**Spec:** `docs/superpowers/specs/2026-10-12-sessions-panel-design.md` (source of truth; §8 = contract changes, §9 = open question) and `docs/superpowers/specs/2026-10-12-sessions-panel-business.md`. Executors read both, plus `docs/inventory/workbench.md` PROJ-02/11/12/14 and `docs/review/review-rules.md` "Swift / Desktop conventions", before their task.

**Plan style (owner preference):** no code bodies. Each task gives files, interfaces, test cases (name + what it asserts) and verification commands. Task-scope checks only; the full gate runs once, in the final task.

## Global Constraints

- Work in the worktree/branch the controller names; verify `git branch --show-current` before every git command.
- **Owner gate:** Tasks 1, 2 (PROJ-11) and 7 (PROJ-16) may be implemented, but merge into the feature branch only after the owner approved spec §8.1 / §8.2 through an ask. Guards are rewritten or extended, never relaxed, renamed out of `testProj11_*` / `testProj16_*`, or split.
- State order (first match wins): approval > error > working > agents working > **ready to check** > finished > open ask > stopped > running > not started.
- Ready to check: `openAsks > 0 && openQuestionAsks == 0`; caption "Ready to check · ask #N" / "Ready for review · ask #N" (all reviews), "· M asks" when M > 1; tone `.purple`; glyph `checklist`; ring when not live; no state notice.
- Group membership: `kind == .finished && openAsks == 0`, live or not; group order `finishedAt` desc, id desc; fold key `projects.finishedSessionsExpanded.<workbenchID>`, default folded.
- Quick delete: not live → yes; live → only `.finished`, `.stopped`, `.failed`; standalone terminals → never.
- Undo: one batch, 5 s from the last delete, Undo restores the whole batch; commit on expiry, on quit (synchronous, bounded), dropped on workbench delete.
- UI strings English only; every new control has an accessibility label; ✕ tooltip and label "Delete session".
- Inner loop only: `make test-swift FILTER=<Class>` (prefer WatchtowerCore tests), `make kit-test FILTER=<Class>`, `make lint-diff`. Logs to a file with `echo "exit=$?"`, never piped through `tail`. Swift tasks run one at a time (one ML-stack link).
- Commit messages in English, ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Public repo: test fixtures use neutral titles ("Session A"), no real ids or paths.

## Review Focus

1. **Undo is complete** (PROJ-16): after delete + Undo the `terminal_sessions` row, its `terminal_session_targets` rows and its asks' `session_id` are byte-identical. Pinned in Task 7.
2. **A hidden row is used nowhere**: Work on It / the phone's `open_existing` never resumes a pending-delete row. Pinned in Task 7.
3. **No silent keep-hidden**: a failed commit brings the row back with an error. Pinned in Task 7.
4. **⌘⌫ / ⌘Z never steal from the terminal or Monaco**: only while `SessionsPanelKeyView` is first responder. Pinned in Task 9.
5. **Existing PROJ-11 order rows keep their expectation**: the test helper's `openQuestionAsks` defaults to `openAsks`, stated in the test. Pinned in Task 1.

---

## Task list

| # | Target | Title | Depends on |
|---|---|---|---|
| 1 | #534 | Core: ask counts in the state row, `.readyToCheck` in `effective` | none |
| 2 | #534 | Core: presentation, notices, `isAtPrompt` | Task 1 |
| 3 | #534 | Ask notices say "Ready to check" | none |
| 4 | #534 | MobileHub wire + Kit known values | Task 2 |
| 5 | #480 | Core: `SessionPanelSections` + `TerminalSessionOrder.move(within:)` | none |
| 6 | #480 | Core: `SessionDeletePolicy` + `PendingSessionDeletes` | none |
| 7 | #480 | VM: deferred delete, Undo, quit commit, hidden-row filters | Task 6 |
| 8 | #480 | VM + views: grouped panel, sticky/pinned row, ⌘N, switcher, ⌘K | Task 5, Task 7 |
| 9 | #480 | Views: ✕, panel keyboard, toast | Task 8 |
| 10 | #480 + #534 | Inventory, feature notes, app guide | Task 2, Task 3, Task 4, Task 9 |
| 11 | #480 + #534 | Final gate | Task 10 |

Lanes: Core tasks 1, 3, 5, 6 have no shared files and may run in parallel worktrees (Core-only builds); 2 → 4 and 7 → 8 → 9 are serial; Swift app-target tasks (4, 7, 8, 9) one at a time. Tasks 8 and 9 edit `WorkbenchSessionsPanel.swift` — see §"#561" below.

---

### Task 1 (#534): Core — ask counts in the state row, `.readyToCheck` in `effective`

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/TerminalSessionQueries.swift` (`fetchAgentStates`: `open_question_asks`, `open_review_asks` subselects)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SessionAgentStatus.swift` (`SessionAgentStateRow` fields + CodingKeys; `effective` branch; `isAtPrompt`)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionSwitcherPresentation.swift` (`Kind.readyToCheck`, `State.openQuestionAsks`, `State.openReviewAsks`, `asksAreOnlyChecks`, `asksAreOnlyReviews`; `live(...)` factory params)
- Modify (compile only, exhaustive switches; real behaviour in Tasks 2 and 4): `SessionStatePresentation.swift`, `SessionAgentNoticePolicy.swift`, `Sources/Services/MobileHub/Slices/{TerminalSessionSlice,SessionTimelineSlice}.swift` — map `.readyToCheck` to the `.waitingOnAsk` branch for now
- Test: `WatchtowerDesktop/Tests/Core/SessionAgentStatusTests.swift`, `Tests/Core/TerminalSessionQueriesTests.swift`

**Interfaces:**
- `SessionAgentStateRow.openQuestionAsks: Int` (`open_question_asks`), `.openReviewAsks: Int` (`open_review_asks`)
- `SessionSwitcherPresentation.State.init(kind:live:openAsks:error:oldestAskID:backgroundAgents:openQuestionAsks: = 0, openReviewAsks: = 0)`
- `effective`: after the `agents != nil` branch, `row.openAsks > 0 && row.openQuestionAsks == 0 → .readyToCheck`

**Tests:**
- `testProj11_StateOrder` (extended, ten kinds): ready beats finished (finished + one check → ready); working and agents working beat ready; finished + a question → finished; check + question → waitingOnAsk; not live + checks only → `State(kind: .readyToCheck, live: false, …)`. The `row(...)` helper gains `questions:`/`reviews:` defaulting `questions` to `openAsks` — a comment states why the old rows keep their expectation.
- `testProj11_ReadyToCheckNeedsOnlyCheckOrReviewAsks` (checks only, reviews only, mixed → ready; zero asks → not ready).
- `testProj11_OneQuestionKeepsWaitingForYou` (two checks + one question → waitingOnAsk, `openQuestionAsks == 1`).
- `testProj11_ReadyToCheckIsAtPrompt` (live, trusted `waiting`, checks only → `isAtPrompt`; not live → false).
- `testProj11_StateFromAnEarlierRunIsIgnored` unchanged and green.
- `TerminalSessionQueriesTests.testAgentStatesCountQuestionAndReviewAsks` (open check/review/question + an answered question → counts 1/1/1, `open_asks` 3).

**Verify:** `make test-swift FILTER='SessionAgentStatusTests|TerminalSessionQueriesTests'`, `make lint-diff`.

### Task 2 (#534): Core — presentation, notices, `isAtPrompt`

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionStatePresentation.swift` (`Tone.purple`; `color`, `glyph`, `caption` for `.readyToCheck`; `checklist` glyph for working/background when `asksAreOnlyChecks`)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionAgentNoticePolicy.swift` (`.readyToCheck` in the not-announced set)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchSessionsPanel.swift` (`Tone.color` `.purple`; `SessionStateLabel` count rule unchanged, glyph comes from the presentation)
- Test: `Tests/Core/SessionStatePresentationTests.swift`, `Tests/Core/SessionAgentNoticePolicyTests.swift`, `Tests/` OwnerAsks VM tests file holding the PROJ-12 Return guards

**Tests:**
- `testReadyToCheckIsPurpleWithChecklist` (tone, glyph, ring when not live, no pulse; captions "Ready to check · ask #7", "Ready for review · ask #7", mixed → "Ready to check", "· 3 asks").
- `testWorkingWithOnlyChecksShowsChecklistGlyph` (working and background: `checklist` with only checks, `questionmark` with a question; captions unchanged).
- `testProj11_OneNoticePerTransition` (extended): stopped → ready withdraws the stopped banner and posts nothing; check filed then `finish_session` → no finished notice; ready → stopped (asks answered, turn over) posts once.
- Supporting: `testProj12_AnAnswerIntoAReadyToCheckSessionGetsTheReturn` (mirrors the waiting-on-ask guard).

**Verify:** `make test-swift FILTER='SessionStatePresentationTests|SessionAgentNoticePolicyTests|OwnerAsksViewModelTests'`, `make lint-diff`.

### Task 3 (#534): Ask notices say "Ready to check"

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkbenchNotificationPolicy.swift` (`OpenAsk.kind: String?` with `decodeIfPresent`; `openedAsks` title; `summaryTitle` for all-check/review batches)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/WorkbenchQueries+Activity.swift` (select `kind`)
- Test: `Tests/Core/WorkbenchNotificationPolicyTests.swift`

**Tests:**
- `testCheckAskNoticeSaysReadyToCheck` (check → "Ready to check: T", review → "Ready for review: T", question and nil → "Agent asks: T").
- `testCoalescedChecksSayReadyToCheck` (three checks → "Ready to check (3)"; two checks + a question → "Waiting for you (3)").
- `testSnapshotWithoutAskKindDecodes` (a persisted snapshot JSON without `kind` decodes; next poll does not re-announce).

**Verify:** `make test-swift FILTER=WorkbenchNotificationPolicyTests`, `make lint-diff`.

### Task 4 (#534): MobileHub wire + Kit known values

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/MobileHub/Slices/TerminalSessionSlice.swift` (`wire(kind)` `"ready_to_check"`, `wire(tone)` `"purple"`, `sessionCounts` → `waiting`)
- Modify: `WatchtowerDesktop/Sources/Services/MobileHub/Slices/SessionTimelineSlice.swift` (`stateText`)
- Modify: `WatchtowerKit/Sources/WatchtowerKit/Models/TerminalSessionState.swift` (`Kind.readyToCheck`, `Tone.purple`, appended to `knownValues` — wire order frozen, append only)
- Test: the existing `TerminalSessionSlice` / `SessionTimelineSlice` test files under `WatchtowerDesktop/Tests/`; `WatchtowerKit/Tests/…/TerminalSessionStateTests.swift`

**Tests:**
- `testReadyToCheckWiresKindAndPurpleTone`, `testReadyToCheckCountsAsWaiting`, `testTimelineTextForReadyToCheck`.
- Kit: `testReadyToCheckAndPurpleAreKnown` (decode, `isKnown`, existing known values unchanged in order).

**Verify:** `make test-swift FILTER='TerminalSessionSliceTests|SessionTimelineSliceTests'`, `make kit-test FILTER=TerminalSessionStateTests`, `make lint-diff`. The phone's drawing of `purple` is out of scope (follow-up).

### Task 5 (#480): Core — `SessionPanelSections` + `TerminalSessionOrder.move(within:)`

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionPanelSections.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/TerminalSessionOrder.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionSwitcherPresentation.swift` (a `rows` overload taking an explicit shortcut order)
- Test: `Tests/Core/SessionPanelSectionsTests.swift` (new), `Tests/Core/TerminalSessionOrderTests.swift`

**Interfaces:** as spec §3.5, plus
- `SessionPanelSections.section(of:) -> Section`
- `SessionPanelSections.neighbour(of id: Int64, in visible: [Int64]) -> Int64?`
- `var visibleOrder: [Int64]` (main, open group or pinned)
- `TerminalSessionOrder.move(_ displayed: [TerminalSession], within full: [Int64], from: IndexSet, to: Int) -> [Int64]`
- `SessionSwitcherPresentation.rows(_:liveIDs:statuses:now:shortcutOrder:)`

**Tests (`SessionPanelSectionsTests`):** `testFinishedWithoutAsksGoesToTheGroup`; `testFinishedWithAnAskReadyAndStoppedStayInMain`; `testGroupOrderedByFinishTimeNewestFirst`; `testFoldedGroupHasACountButNoRows`; `testStickyKeepsAJustFinishedOnScreenRowInMain`; `testStickyGroupRowIsPinnedUnderAFoldedHeader`; `testShortcutsNumberMainFirstGroupOnlyWhenOpen`; `testNeighbourIsNextThenPreviousThenNil`; `testMainKeepsTheSavedDragOrder`.
`TerminalSessionOrderTests.testMoveWithinKeepsHiddenSlots` (a hidden id between two displayed ids keeps its index after a drag; existing `move` tests unchanged).

**Verify:** `make test-swift FILTER='SessionPanelSectionsTests|TerminalSessionOrderTests|SessionSwitcherPresentationTests'`, `make lint-diff`.

### Task 6 (#480): Core — `SessionDeletePolicy` + `PendingSessionDeletes`

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionDeletePolicy.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/PendingSessionDeletes.swift`
- Test: `Tests/Core/SessionDeletePolicyTests.swift`, `Tests/Core/PendingSessionDeletesTests.swift` (new)

**Interfaces:** spec §4.1 and §4.2 verbatim (`isQuick(_:isWorkbenchSession:)`; `PendingSessionDeletes` with `add`, `undo`, `expire(now:)`, `takeAll`, `drop(workbenchID:)`, `ids`, `deadline`, `toastText`, `window = 5`).

**Tests:**
- `testProj16_QuickDeleteTable` (every `Kind` × live/not live × workbench/standalone; working, background, needs approval, running, waiting on ask, ready live → false; finished/stopped/failed live → true; any not live workbench row → true; standalone → false).
- `testAddRestartsTheDeadline`, `testToastTextCountsTheBatch` ("Session deleted", "3 sessions deleted"), `testUndoReturnsTheWholeBatchAndClears`, `testExpireOnlyAfterTheDeadline`, `testTakeAllEmptiesTheBatch`, `testDropRemovesOnlyThatWorkbench`.

**Verify:** `make test-swift FILTER='SessionDeletePolicyTests|PendingSessionDeletesTests'`, `make lint-diff`.

### Task 7 (#480): VM — deferred delete, Undo, quit commit, hidden-row filters

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel.swift` (stored `pendingDeletes`, `deleteCommitTask`, injectable `deleteSleep`; workbench delete calls `drop`)
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+Sessions.swift` (`delete` deferred; `commitPendingDeletes`, `undoPendingDeletes`, `commitPendingDeletesForQuit`; filters in the workbench/standalone session reads and `readTargetSessions`)
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+GoTo.swift` (filter `goToSessions`)
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+Panel.swift` (`sessionStatuses` drops pending ids)
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (`willTerminate` → `commitPendingDeletesForQuit()`, before `mobileHub?.stop()`)
- Test: `WatchtowerDesktop/Tests/WorkbenchesViewModelSessionsTests.swift`, the MobileHub `SessionStartStopHandlers` test file

**Interfaces:**
- `func delete(_ session: TerminalSession) async` (same signature, deferred semantics)
- `func undoPendingDeletes() async`
- `func commitPendingDeletesForQuit()` (synchronous, bounded wait ≤ 2 s, logs on timeout/error)
- `var pendingDeleteToast: String?` (from `pendingDeletes.toastText`)

**Tests:**
- `testProj16_DeleteHidesAtOnceAndWritesNothingUntilTheWindowEnds` (row gone from `terminalSessions`, process closed, DB row present until the fake sleep completes).
- `testProj16_UndoBringsBackTheRowWithItsLinksAndAsks` (row, `terminal_session_targets`, open ask `session_id` byte-identical; row not live).
- `testProj16_CommitAfterTheWindowDeletesWithCascades` (links gone, ask `session_id` NULL).
- `testProj16_QuitCommitsPendingDeletes`.
- `testBatchUndoRestoresEverySessionOfTheBatch`, `testFailedCommitBringsTheRowBackWithAnError`, `testPendingRowIsInNoListGoToOrTargetLookup` (`orderedSessions`, `goToSessions`, `activeSessionID`, `readTargetSessions`), `testUndoStateSurvivesLeavingTheWorkbench`, `testWorkbenchDeleteDropsItsPendingSessions`.
- MobileHub: `testOpenExistingNeverPicksAPendingDelete`.
- Reap rule: no subprocess is spawned (terminal center faked); confirm no stub leaks.

**Verify:** `make test-swift FILTER='WorkbenchesViewModelSessionsTests|SessionStartStopHandlersTests'`, `make lint-diff`.

### Task 8 (#480): VM + views — grouped panel, sticky/pinned row, ⌘N, switcher, ⌘K

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+Panel.swift` (`panelSections(projectID:)`, fold read/toggle with cache, `stickySection`, `openSession(atShortcut:)` over `shortcutOrder`, `moveSessions` via `move(within:)`)
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+GoTo.swift` (`Current.orderedSessions` = main then finished)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchSessionsPanel.swift` (main `ForEach` with `onMove`, group header row, group rows / pinned row)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/SessionSwitcherPopover.swift` (main, "Finished" divider, group rows)
- Test: `WatchtowerDesktop/Tests/WorkbenchesViewModelSessionsTests.swift`, `Tests/WorkbenchSessionSwitchTests.swift`, `Tests/WorkbenchGoToPaletteTests.swift`

**Interfaces:** `func panelSections(projectID: Int64) -> SessionPanelSections`; `func isFinishedGroupExpanded(projectID:) -> Bool`; `func setFinishedGroupExpanded(_:projectID:)`.

**Tests:** `testFinishedFoldIsRememberedPerWorkbench`; `testShortcutOpensTheNumberedRowWithTheGroupFolded` (⌘2 = second main row; folded group rows unreachable by ⌘N, reachable when open); `testDragInMainKeepsAGroupSessionsSlot`; `testSessionFinishingOnScreenStaysInMainUntilSwitchedAway`; `testGoToCurrentSectionListsMainThenFinished`; `testSwitcherListsFinishedAfterTheMainRows`.

**Verify:** `make test-swift FILTER='WorkbenchesViewModelSessionsTests|WorkbenchSessionSwitchTests|WorkbenchGoToPaletteTests'`, `make lint-diff`. Manual: `make app-dev` only if the controller asks (machine load).

### Task 9 (#480): Views — ✕, panel keyboard, toast

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Workbench/SessionsPanelKeyView.swift` (`NSViewRepresentable`, `acceptsFirstResponder`; ↑ ↓ Return Esc ⌘⌫ ⌘Z; key-window/no-sheet gate as `OwnerAskKeyCatcher.takesKeys`)
- Create: `WatchtowerDesktop/Sources/Views/Workbench/SessionDeleteToast.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchSessionsPanel.swift` (hover ✕, cursor focus ring, the key view behind the `List`, toast at the bottom)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchesView.swift` (`sessionActions.delete`: `isQuick` → `vm.delete` directly, else the dialog; toast at level 1 and over the page when the panel is hidden)
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+Panel.swift` (`panelCursor`, `movePanelCursor(_:)`, `deleteAtPanelCursor() -> DeleteIntent` (`.quick` / `.confirm(TerminalSession)`), neighbour after delete)
- Test: `WatchtowerDesktop/Tests/WorkbenchesViewModelSessionsTests.swift`, a new `Tests/SessionsPanelKeyViewTests.swift`

**Tests:**
- `testDeleteMovesThePanelCursorToTheNeighbour` (✕, ⌘⌫ and the menu path).
- `testCommandDeleteOnAWorkingSessionAsksFirst` (`deleteAtPanelCursor` → `.confirm`).
- `testCursorMovesNeverStartASession` (↑ ↓ over not-running rows: no `open`).
- `SessionsPanelKeyViewTests`: `testKeysTakenOnlyAsFirstResponder` (a terminal-like first responder keeps ⌘⌫ and ⌘Z), `testNoKeysUnderASheet`, `testEscReturnsFocusToTheTerminal`.
- `testToastShowsBatchCountAndUndoRestores` (VM level; the view only binds `pendingDeleteToast`).

**Verify:** `make test-swift FILTER='WorkbenchesViewModelSessionsTests|SessionsPanelKeyViewTests'`, `make lint-diff`.

### Task 10 (#480 + #534): Inventory, feature notes, app guide

**Files:**
- Modify: `docs/inventory/workbench.md` — PROJ-11 per spec §8.1 (only after the owner's ask approval; record ask number and date), new PROJ-16 per §8.2, header module list, v1 limits (spec §7), changelog line
- Modify: `docs/features/workbench.md` — sessions panel: finished group, quick delete + Undo (PROJ-16), Ready to check in the state set
- Modify: `docs/app-guide.md` — the Sessions paragraph: Ready to check and the order, the group, ✕, ⌘⌫ / ↑ ↓ / Return / Esc / ⌘Z in the panel, Undo, ⌘1…⌘9 numbering

**Verify:** guard names in the inventory match the test names (`grep` each); `make lint-diff`.

### Task 11 (#480 + #534): Final gate

`bash scripts/dev-health.sh` first (stop on `HEALTH: overloaded`). Then `make test-swift` (includes the Kit), `make lint-all`; `make test` is not needed for a Desktop-only change unless Task 7 touched Go (it must not). Mobile: `make mobile-test` only if the phone app was touched (it should not be). Then `local-review` → PR.

## #561 — ordering and conflict risk

#561 (a new session row hidden under the asks stack) edits the same `List` in `WorkbenchSessionsPanel.body`. Run it before Task 8 or rebase Tasks 8–9 onto it; the conflict is textual. Whatever #561 does to scroll a new row into view must also cover the group header and the pinned row (they appear and disappear too).
