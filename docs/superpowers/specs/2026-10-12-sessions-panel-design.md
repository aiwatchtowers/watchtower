# Sessions panel: finished group, one-gesture delete with Undo, "Ready to check" (board #480, #534) — design

**Status:** Draft, 2026-10-12. Needs the owner's approval of the PROJ-11 amendment and the new PROJ-16 (§8)
before the tasks that touch them merge.
**Business spec:** `2026-10-12-sessions-panel-business.md`. **Plan:** `docs/superpowers/plans/2026-10-12-sessions-panel.md`.
**Related:** #411 Agents working (`2026-10-10-session-background-agents-design.md`), owner asks v2
(`2026-10-10-owner-asks-v2-design.md`), #561 (new session row hidden under the asks stack — same `List`, §10).
**Touches (Desktop only, no Go, no migration):** WatchtowerCore `SessionAgentStatus`, `SessionSwitcherPresentation`,
`SessionStatePresentation`, `SessionAgentNoticePolicy`, `WorkbenchNotificationPolicy`, `TerminalSessionOrder`,
`TerminalSessionQueries`, `WorkbenchQueries+Activity`; new Core `SessionPanelSections`, `PendingSessionDeletes`,
`SessionDeletePolicy`; app `WorkbenchesViewModel(+Panel, +Sessions, +GoTo)`, `WorkbenchSessionsPanel`,
`SessionSwitcherPopover`, `WorkbenchesView`, `AppState` (quit hook), MobileHub slices and start/stop handlers;
Kit `TerminalSessionState` known values; `docs/inventory/workbench.md`, `docs/features/workbench.md`,
`docs/app-guide.md`.

## 1. Two targets, one panel

#480 decides **where** a session row sits and **how** it leaves; #534 adds a state that changes **which** rows
count as "finished". They are designed together because the group's membership rule reads the state kind: with
#534, "finished with only check/review asks open" is no longer `.finished`, so it never qualifies for the group.
Neither target needs a Go change: the state order is Desktop-only (Go stores raw columns; `effective` is Swift),
and the deferred delete runs the existing `TerminalSessionQueries.delete`.

## 2. #534 — the Ready to check state

### 2.1 Data

`TerminalSessionQueries.fetchAgentStates` adds two correlated counts beside `open_asks`:
`open_question_asks` (`kind = 'question'`) and `open_review_asks` (`kind = 'review'`), both over
`status = 'open'`. Checks are `open_asks - question - review`. `SessionAgentStateRow` gains
`openQuestionAsks: Int`, `openReviewAsks: Int` (CodingKeys snake_case). An ask the Chat question escalation filed
(`origin = 'chat'`) is a `question`, so it keeps "Waiting for you" — correct: the agent is blocked on it.

`SessionSwitcherPresentation.State` gains `openQuestionAsks: Int` and `openReviewAsks: Int` (filled from the row
for every kind, like `openAsks`). The initializer takes `openQuestionAsks: Int? = nil` — nil means every open ask
is a question (stored as `openAsks`) — and `openReviewAsks: Int = 0`: a state built without ask kinds (an older
caller, a test fixture) reads as before asks had kinds, so it never turns into Ready to check by default. The same
`Int? = nil` default is on the `SessionAgentStateRow` memberwise initializer, and `Kind` gains `case readyToCheck` ("every open ask of the
session is a check or a review; the agent waits for the owner's verdict, not a decision").

Derived (on `State`, pure): `asksAreOnlyChecks: Bool` = `openAsks > 0 && openQuestionAsks == 0`;
`asksAreOnlyReviews` = `asksAreOnlyChecks && openReviewAsks == openAsks`.

### 2.2 Order (`SessionAgentStatus.effective`)

```
approval > error > working > agents working > READY TO CHECK > finished > open ask > stopped > running > not started
```

New branch right after `agents != nil`: `row.openAsks > 0 && row.openQuestionAsks == 0 → .readyToCheck`.
Reasons for the slot:
- **Below working / agents working** (#534: "a working session with an open check stays Working with a badge";
  the same holds for #411's Agents working — the agents may still change what the owner is asked to check, and
  Agents working already outranks every ask state).
- **Above finished:** the prime case is "agent filed a check, then `finish_session`". Finished-with-asks is
  orange today; this is exactly the case #534 wants told apart. A finished session with an open question stays
  `.finished` (orange), unchanged.
- **Above open ask:** the two are exclusive by construction (any question → not ready), so the relative order
  only documents that.
Not run-scoped (asks are not): a non-live session shows it as a ring, like Waiting for you.

### 2.3 Presentation (`SessionStatePresentation`)

| | Ready to check | Ready for review (all open asks are reviews) |
|---|---|---|
| Tone | new `.purple` (system purple) | `.purple` |
| Glyph | `checklist` | `checklist` |
| Caption | "Ready to check · ask #N" (+ " · M asks" when M > 1) | "Ready for review · ask #N" (+ " · M asks") |
| Dot | filled when live, ring when not; no pulse | same |

`#N` is the oldest open ask, as for Waiting for you. Mixed checks and reviews read "Ready to check" (a check is
the broader verb). Working / Agents working with `asksAreOnlyChecks`: glyph `checklist` instead of
`questionmark`, the ask count beside it unchanged; captions unchanged ("Working · 1 ask open"). The view-side
`Tone.color` maps `.purple` to `Color.purple`. `SessionStateLabel` shows the count beside the glyph for working,
and for background with asks — unchanged rule, the glyph swaps only.

Colour choice: purple is the one system hue not yet used by a state (green working, orange owner's move, blue
finished, red error, grey stopped) and reads distinctly from both blue and orange in light and dark.

### 2.4 Notices

- **State notices** (`SessionAgentNoticePolicy.transition`): `.readyToCheck` joins `.waitingOnAsk` — no state
  notice, and a delivered stopped/finished banner of the session is withdrawn on entering it. The ask's own
  notice already announced it (PROJ-11 rule "waiting on an ask … gets no state notice"). Consequence pinned by a
  test: check filed, then `finish_session` → no "finished" banner (one notice per hand-off, not two).
- **Ask notices** (`WorkbenchNotificationPolicy.openedAsks`): `OpenAsk` gains `kind: String?`
  (`decodeIfPresent`, the snapshot is persisted — an older snapshot decodes with nil). Title: `check` →
  "Ready to check: <title>", `review` → "Ready for review: <title>", else (and nil) "Agent asks: <title>". The
  coalesced summary reads "Ready to check (N)" when every coalesced ask is check/review, else "Waiting for you
  (N)". `WorkbenchQueries+Activity` selects `kind` with the open asks.

### 2.5 Other readers of the kind

Every exhaustive `switch` over `Kind` gets the case (the compiler lists them):
- `SessionAgentStatus.isAtPrompt`: `.readyToCheck` → true (like `.waitingOnAsk`; it still needs `at != nil`).
  PROJ-12's Return gate reads `needsApproval`/`hooksReported`, not the kind — unchanged, pinned by a supporting
  test.
- MobileHub `TerminalSessionSlice.wire(kind)` → `"ready_to_check"`, `wire(tone)` → `"purple"`;
  `sessionCounts` counts it under `waiting` (the owner's move; no new wire field);
  `SessionTimelineSlice.stateText` → "Ready to check" / "Ready for review". Kit `TerminalSessionState.Kind`
  and `.Tone` add the two known values (open wire values: an older phone decodes them as unknown and draws its
  fallback). The phone app's own drawing of the new tone is a small follow-up, not part of Done.
- `SessionBackgroundProber` reads only `.background` — no change.

## 3. #480 — the finished group

### 3.1 Membership

A row of a workbench's session list goes to the group when `state.kind == .finished && state.openAsks == 0`,
live or not. Everything else is the **main list** — including Ready to check and Finished with an open question
(they still wait for the owner). Standalone terminals have no states: no group.

**Ready to check vs the group (decision).** Ready to check stays in the main list; no separate "ready" group.
Reasons: (1) it waits for the owner, the same rule that keeps a finished session with an open ask in the main
list (#480 brief); (2) its asks already sit in the Waiting for you stack directly above SESSIONS — a third fold
would repeat them; (3) it is transient: answering the check either leaves it Finished (→ group) or wakes the
agent. Revisit only if the main list grows long with ready rows.

### 3.2 Order inside each section

- **Main list:** `TerminalSessionOrder.apply` over the main rows only, as today (unplaced newest first, then the
  saved drag order).
- **Group:** most recently finished first — `finishedAt` (status row) descending, then id descending. The saved
  drag order is **not** consulted and **not** rewritten for group rows: when a row returns to the main list it
  takes its saved slot back.
- **Drag** (`onMove`) is offered in the main list only. `TerminalSessionOrder.move` gains a variant that keeps
  every hidden id's slot: `move(_ displayed: [TerminalSession], within full: [Int64], from:to:) -> [Int64]` —
  `full` is the saved order applied over all the workbench's sessions; the displayed ids' positions inside
  `full` are refilled in their new order, hidden ids (group, pending delete) stay where they were. Today's
  `move` (displayed only) would drop group ids from the saved order and make them jump to the top on return.

### 3.3 The session on screen never jumps (sticky section)

The VM keeps `stickySection: SessionPanelSections.Sticky?` (`sessionID`, `section`) for the session on screen
(`panelSelection`), captured the first time it is grouped while on screen. The sticky section only holds a row
that is **still finished**: a session finishing in front of the owner stays in its main-list slot until another
session comes on screen. A session resumed from the group (a new prompt lifts `finished`: working, running…)
always returns to its place in the main list, on screen or not (owner brief #480 §1), and `finishedCount`
counts only rows that are really finished. When another session comes on screen the sticky entry is replaced
and the row moves to its real section on the next render.

A collapsed group whose on-screen session is in it shows that one row under the "▸ N finished" header
(`pinned`), without changing the remembered fold. Decision over "auto-expand": expanding would write the
persisted preference behind the owner's back (or need a second, transient state) and would show every
finished row to surface one.

### 3.4 Fold persistence

UserDefaults key `projects.finishedSessionsExpanded.<workbenchID>` (Bool, default **false** = folded; the
`projects.` prefix follows the house rule for workbench keys). Cached in the VM like `sessionOrders` so a toggle
re-renders. Deleting a workbench removes the key (next to its other per-workbench keys, if a cleanup exists;
otherwise a stale Bool is harmless).

### 3.5 Pure model — `SessionPanelSections` (WatchtowerCore)

```
package struct SessionPanelSections: Equatable, Sendable {
    package enum Section: Equatable, Sendable { case main, finished }
    package let main: [SessionSwitcherPresentation.Row]
    package let finished: [SessionSwitcherPresentation.Row]   // empty while folded
    package let finishedCount: Int
    package let pinned: SessionSwitcherPresentation.Row?      // folded + on-screen row in the group
    package var shortcutOrder: [Int64]                        // main ids, then the open group's ids
    package let expanded: Bool
    package var visibleOrder: [Int64]                         // main, then the open group or the pinned row
    package struct Sticky { package let sessionID: Int64; package let section: Section }
    package static func grouping(
        sessions: [TerminalSession], savedOrder: [Int64], statuses: [Int64: SessionAgentStatus],
        liveIDs: Set<Int64>, now: Date, expanded: Bool, sticky: Sticky?
    ) -> SessionPanelSections
    package static func panelSection(of state: SessionSwitcherPresentation.State) -> Section
    package static func panelNeighbour(of id: Int64, in visible: [Int64]) -> Int64?
}
```
Names are specific (`grouping`, `panelSection`, `panelNeighbour`) rather than `make`/`section`/`neighbour`:
sentrux resolves calls by bare name, and generic names collide with unrelated methods.
Rows are built by `SessionSwitcherPresentation.rows` with shortcuts assigned over `shortcutOrder` (§3.6). The
standalone list keeps `rows(orderedSessions(nil))` unchanged.

### 3.6 ⌘1…⌘9, the switcher and ⌘K (decision: number the visible order, main first)

- **⌘N** follows `shortcutOrder`: the main list numbered from 1, then the group's rows only while it is open.
  Folding never renumbers the main list (it comes first); a folded group's rows (and the pinned row) get no
  number — a shortcut to a row the owner cannot see would be a surprise. `openSession(atShortcut:)` reads the
  same `shortcutOrder` as the rows' badges, so the hint and the key never disagree.
- **Session switcher popover** (`SessionSwitcherPopover`): main rows, then a "Finished" divider and the group's
  rows (always listed there — the popover is a search surface), shortcut hints as above.
- **⌘K** `GoToRanking.Current.orderedSessions`: main then finished, the same list. Other workbenches' sessions
  are unchanged.
- **⌘T** unchanged (a new session is unplaced → top of the main list).
- `WorkspacePaneView` / `WorkbenchHeaderControls` session menus and `CodeHandoffCenter` keep
  `orderedSessions` (all non-pending sessions, saved order) — they are pickers, not the panel.

## 4. #480 — one-gesture delete

### 4.1 Who gets the quick path — `SessionDeletePolicy` (WatchtowerCore, pure)

```
package enum SessionDeletePolicy {
    /// ✕ and ⌘⌫ without a dialog.
    package static func isQuick(_ state: SessionSwitcherPresentation.State, isWorkbenchSession: Bool) -> Bool
}
```
Rule: a workbench session that is **not live** → quick, whatever its ring says (no process to kill). A **live**
one → quick only for `.finished`, `.stopped`, `.failed`. Everything else live — `.working`, `.background`,
`.needsApproval`, `.running` (hooks have not reported: unknown), `.waitingOnAsk`, `.readyToCheck` (an agent
sits waiting on the owner's answer; killing it is not a tidy-up) — goes through the confirmation. A standalone
terminal never gets the quick path (no state; v1 keeps its dialog). The ✕ is shown exactly when `isQuick`.

### 4.2 Deferred DELETE

The DELETE erases the report links (`terminal_session_targets` ON DELETE CASCADE) and unbinds asks
(`owner_asks.session_id` ON DELETE SET NULL), so Undo never re-inserts rows; the DELETE is postponed instead.

`PendingSessionDeletes` (WatchtowerCore, pure value):
```
package struct PendingSessionDeletes: Equatable, Sendable {
    package struct Entry: Equatable, Sendable { let sessionID: Int64; let workbenchID: Int64?; let title: String }
    package private(set) var batch: [Entry]          // in delete order
    package private(set) var deadline: Date?
    package static let window: TimeInterval = 5
    package var ids: Set<Int64>
    package mutating func enqueueSessionDelete(_ entry: Entry, now: Date) // appends, deadline = now + window (restarts)
    package mutating func restoreBatch() -> [Entry]            // Undo: whole batch back, cleared
    package mutating func expiredBatch(now: Date) -> [Entry]?  // the batch to commit once past the deadline
    package mutating func takeBatch() -> [Entry]               // quit / workbench delete: commit now
    package mutating func discardBatch(workbenchID: Int64)     // the workbench is gone: nothing to commit
    package var toastText: String?                             // "Session deleted" / "N sessions deleted"
}
```
The method names are specific (not `add`/`undo`/`expire`/`takeAll`/`drop`) so sentrux, which resolves calls by
bare name, does not tie them to unrelated methods of the same name.

**Batch decision:** one batch, one timer. Each delete inside the window joins the batch and restarts the 5 s;
the toast reads "Session deleted — Undo" or "N sessions deleted — Undo"; Undo (button or ⌘Z) restores the whole
batch. Chosen over "Undo returns the last one" (a stack with per-entry timers, a toast that changes meaning
under the cursor): one rule, one timer, and the count tells exactly what Undo will bring back.

`WorkbenchesViewModel` (on `AppState`, survives navigation — review rule "async state survives navigation"):
- `pendingDeletes: PendingSessionDeletes` (observed), `deleteCommitTask: Task<Void, Never>?`, injectable
  `deleteSleep` like `titleSleep`.
- `delete(_ session:)` becomes: clear the session error → `pendingDeletes.add` → `terminalCenter.close` (the
  process stops now) → `forgetProcessState`, title bookkeeping, `forgetInLayout`, standalone selection (as
  today) → drop the row from `terminalSessions` in memory → (re)arm the commit task. No DB write yet.
- **Commit** (`commitPendingDeletes(_ entries:)`): one `dbPool.write` running `TerminalSessionQueries.delete`
  for each entry (a row already gone is fine: DELETE of nothing), then `loadSessions` for each touched list. A
  failed write → `setSessionError("Could not delete the session: …")` and a reload: the row comes back — never
  silently kept hidden.
- **Undo** (`undoPendingDeletes()`): cancel the task, `pendingDeletes.restoreBatch()`, reload the touched lists. The
  row returns not running; a click or Restart resumes it (`--resume`, its `claude_session_id` is intact). The
  layout is not restored (the owner clicks it back on screen).
- **Quit:** `AppState`'s `willTerminate` observer calls `workbenchesViewModel?.commitPendingDeletesForQuit()`:
  `takeBatch()` and a synchronous GRDB write bounded like `OwnerPresenceCenter.clearForQuit` (≤ 2 s; a timeout or
  error is logged — the row survives and reappears next launch, the safe side).
- **Crash / kill -9:** nothing was deleted → the row reappears on next launch (v1 limit, safe).
- **Workbench delete** while a batch holds its sessions: `discardBatch(workbenchID:)` — the cascade removes them.

### 4.3 The hidden row must not be seen or used

Filtering happens at the VM's read points, so every consumer downstream sees the same list:
- the workbench session read behind `loadSessions` and `loadStandaloneSessions` drops `pendingDeletes.ids`;
- `readTargetSessions` (Work on It, the phone's `session_start` with `open_existing`) drops them — otherwise
  "open existing" could resume a row the owner just deleted;
- `loadGoToPalette`'s `goToSessions` drops them;
- `sessionStatuses` drops them (the sessions panel, notices routed through `agentStates`, prober — the row is
  not live anyway after `close`, so no state notice can fire);
- the asks stack keeps showing an ask of a pending session (it is still open and bound); its "go to session"
  finds no row and reports "That session no longer exists." (today's path for a deleted row).
Go never sees the hiding and needs none: every Go reader of `terminal_sessions` acts on that session's own
process (hooks, `ask_owner`, `finish_session`, the drift check) — stopped by `close` — or on a Desktop request
(`workbench session-report`, `session-probe`), which the VM no longer issues for a hidden row. A late async
hook of the killed process may still write the row's state; Undo then shows it, which is truthful.
MobileHub: the `terminal_session` slice reads the DB, so the phone may show the row until the commit (≤ 5 s +
one tick) — v1 limit; `session_stop` on it is a no-op, `session_start` goes through `readTargetSessions` (above).

### 4.4 Panel keyboard (⌘⌫, ⌘Z, ↑ ↓, Return, Esc)

Today a row click opens the session and its terminal takes the keyboard on attach, and the `List` has no
selection. #480 needs "focus in the panel, not the terminal or the editor" and "after a delete the selection
moves to the neighbour". Design:
- **`panelCursor: Int64?`** (VM) — a keyboard highlight separate from the on-screen tab, drawn as a focus ring
  on the row. Moving it never opens or starts a session (opening a finished session would `--resume` it).
- **`SessionsPanelKeyView`** — an `NSViewRepresentable` behind the panel's `List`, `acceptsFirstResponder`,
  shaped like `OwnerAskKeyCatcher` (key window, no sheet). The panel **has the keyboard** while this view is
  first responder. It becomes first responder on: a click on an empty part of the panel or the SESSIONS label or
  the group header; a ✕ click; the toast's Undo. It loses it the normal AppKit way (a click into the terminal,
  Monaco, a field). Entering sets `panelCursor` to the on-screen session if it is none.
- While it has the keyboard: ↑/↓ move `panelCursor` over the visible order (main, open group, pinned); Return
  opens the cursor row like a click; Esc hands the keyboard back to the focused terminal
  (`requestKeyboardFocus`); **⌘⌫** on the cursor row: `isQuick` → delete with Undo, else the confirmation;
  **⌘Z** → `undoPendingDeletes()` when a batch is pending. Outside it, ⌘⌫ and ⌘Z belong to whoever has the
  keyboard (Claude Code's line editing, Monaco's undo).
- **Neighbour after delete** (`SessionPanelSections.panelNeighbour(of:in:)`, pure): the next row in visible order,
  else the previous, else nil. Applies to ✕, ⌘⌫ and the menu's Delete….
- A row click keeps today's behaviour (keyboard into the terminal) — open question Q1 (§9).

### 4.5 Views

- Row (`TerminalSessionRow`): `onHover` state; trailing `Button` with `xmark.circle.fill`, `.borderless`,
  `.help("Delete session")`, `.accessibilityLabel("Delete session")`, shown while hovered **or** the row is the
  panel cursor, only when `isQuick`; it sits outside the open gesture (like the closed-asks button). VoiceOver
  also gets an `accessibilityAction(named: "Delete session")` on quick rows. Context menu Delete… unchanged
  (dialog for every state; after confirming, the same deferred path).
- Group header row: "▸ N finished" / "▾ N finished", a button toggling the fold, `.isHeader`, label
  "N finished sessions, collapsed/expanded"; rows of the group look like main rows (state label, report line).
- Toast: bottom of the left column (sessions panel at level 2, workbench list at level 1); with the panel hidden,
  bottom-leading over the page. "Session deleted" / "N sessions deleted" + **Undo** button; announced to
  VoiceOver (`AccessibilityNotification.Announcement`). Disappears on commit or Undo.
- Confirmation dialog text unchanged; its Delete Session button calls the same `delete` (deferred, with Undo).

## 5. Contracts read and their status

- **PROJ-02** (workbench delete leaves nothing): unchanged. The session DELETE and its cascades are the same
  statement, run later. A workbench delete during the window cascades the hidden rows itself.
- **PROJ-14** (session report links come only from the session's own tools): unchanged — nothing writes links;
  Undo works because none were erased.
- **PROJ-11**: amended by #534 (§8.1).
- **PROJ-12**: unchanged (gate does not read the kind); a supporting test pins an answer into a Ready to check
  session behaving like one into Waiting for you.
- New **PROJ-16** for the undoable delete (§8.2): the Undo promise is a data-loss promise and deserves a guard.

## 6. Tests (names; plan lists the files)

Core (`Tests/Core`):
- `SessionAgentStatusTests.testProj11_StateOrder` — table extended to ten kinds: ready beats finished; agents
  working and working beat ready; a question with a check → waitingOnAsk; finished + question → finished;
  not live + checks only → ring `.readyToCheck`.
- `testProj11_ReadyToCheckNeedsOnlyCheckOrReviewAsks`, `testProj11_OneQuestionKeepsWaitingForYou`,
  `testProj11_ReadyToCheckIsAtPrompt`.
- `SessionStatePresentationTests.testReadyToCheckIsPurpleWithChecklist` (captions: check, review, mixed, M > 1),
  `testWorkingWithOnlyChecksShowsChecklistGlyph`.
- `SessionAgentNoticePolicyTests.testProj11_OneNoticePerTransition` extended: entering ready posts nothing and
  withdraws a stopped banner; check filed then finish → no finished notice.
- `WorkbenchNotificationPolicyTests.testCheckAskNoticeSaysReadyToCheck`, `testSnapshotWithoutAskKindDecodes`,
  `testCoalescedChecksSayReadyToCheck`.
- `TerminalSessionQueriesTests.testAgentStatesCountQuestionAndReviewAsks`.
- `SessionPanelSectionsTests`: finished without asks → group; finished with ask / ready / stopped → main;
  group ordered by `finishedAt` desc; folded group has no rows but a count; sticky keeps a just-finished
  on-screen row in main; sticky keeps an on-screen group row pinned under a folded header; `shortcutOrder` main
  first, group only when open; a session resumed from the group returns to main; `panelNeighbour`
  next/previous/nil.
- `TerminalSessionOrderTests.testMoveWithinKeepsHiddenSlots` (a group id between two main ids keeps its slot
  after a drag; returning it to main restores its place).
- `SessionDeletePolicyTests.testQuickDeleteTable` (every kind × live/not live × workbench/standalone).
- `PendingSessionDeletesTests`: add restarts the deadline; batch toast text; undo returns all and clears;
  expire before / after deadline (`expiredBatch`); `takeBatch`; `discardBatch` by workbench.
App (`Tests/`):
- `WorkbenchesViewModelSessionsTests`: `testProj16_DeleteHidesAtOnceAndWritesNothingUntilTheWindowEnds`,
  `testProj16_UndoBringsBackTheRowWithItsLinksAndAsks` (a session with a `terminal_session_targets` row and an
  open ask: after delete + undo both are byte-identical), `testProj16_CommitAfterTheWindowDeletesWithCascades`,
  `testProj16_QuitCommitsPendingDeletes`, `testPendingRowIsInNoListGoToOrTargetLookup`,
  `testFailedCommitBringsTheRowBackWithAnError`, `testUndoStateSurvivesLeavingTheWorkbench`,
  `testDeleteMovesThePanelCursorToTheNeighbour`, `testFinishedFoldIsRememberedPerWorkbench`,
  `testShortcutOpensTheNumberedRowWithTheGroupFolded`.
- MobileHub: `TerminalSessionSliceTests.testReadyToCheckWiresKindAndPurpleTone`,
  `SessionStartStopHandlersTests.testOpenExistingNeverPicksAPendingDelete`.
Kit: `TerminalSessionStateTests.testReadyToCheckAndPurpleAreKnown`.

## 7. Docs

`docs/features/workbench.md` (sessions panel: group, quick delete, Undo, PROJ-16; state set: Ready to check),
`docs/app-guide.md` (the Sessions paragraph: the new state and its place in the order, the group, ✕, ⌘⌫, ↑↓ /
Return / Esc in the panel, Undo, ⌘N numbering), `docs/inventory/workbench.md` (§8, changelog, v1 limits below).

v1 limits (inventory "v1 limits and notes"): a crash inside the 5 s window keeps the row (it reappears); the
phone may list a hidden row until the commit; standalone terminals get Undo but no ✕; a row click still sends the
keyboard into the terminal (⌘⌫ needs the panel to hold it).

## 8. Contract changes (need owner approval)

### 8.1 PROJ-11 amendment (#534)

Status line append: "amended 2026-10-xx for Ready to check, owner approved in ask #N, board #534".

Replace in the states paragraph "and shows **Finished** (blue, orange while the session has open asks)" with:
> and shows **Finished** (blue; orange while the session has an open `question` ask; Ready to check below while
> every open ask is a check or a review)

Replace the order sentence "The order is: approval > error > working > agents working (since 2026-10-10, below)
> finished > open ask > stopped > running > not started" with:
> The order is: approval > error > working > agents working (since 2026-10-10, below) > ready to check (since
> 2026-10-xx, below) > finished > open ask > stopped > running > not started

Replace "waiting on an ask, or working with asks, gets no state notice (the ask's own notice announced it)" with:
> waiting on an ask, ready to check, or working with asks, gets no state notice (the ask's own notice announced
> it)

Add after the board #543 paragraph:
> Since 2026-10-xx (board #534, owner approved in ask #N): a session with open asks none of which is a
> `question` — every one a `check` or a `review` — shows **Ready to check · ask #N** (**Ready for review** when
> every one is a review; "· M asks" with more than one), purple with a checklist glyph, instead of Finished or
> Waiting for you; one open `question` keeps Waiting for you, or Finished in orange. Like the open asks it is not
> run-scoped: a session that is not live shows it as a ring. Working and Agents working keep their kind with only
> checks or reviews open and show the ask count beside a checklist glyph instead of `?`. Ready to check counts as
> at the prompt (`isAtPrompt`) like Waiting for you, and an ask answer's Return into it follows PROJ-12 unchanged.
> An ask notice of a check or review reads "Ready to check: <title>" / "Ready for review: <title>".

Guard list: `testProj11_StateOrder` "(a table over the ten kinds …)"; `testProj11_OneNoticePerTransition` adds
"ready to check posts nothing and withdraws a stopped banner"; new guards
`testProj11_ReadyToCheckNeedsOnlyCheckOrReviewAsks`, `testProj11_OneQuestionKeepsWaitingForYou`,
`testProj11_ReadyToCheckIsAtPrompt`. No guard is relaxed: the existing rows of the order table stay; rows whose
fixture has open asks keep their expectation because the fixture's asks are questions (`openQuestionAsks =
openAsks` in the helper's default) — the helper change is stated in the test, not hidden.

### 8.2 New PROJ-16 (#480)

> ## PROJ-16 — a deleted session can be undone until it is gone, and then leaves nothing
>
> **Observable:** Deleting a session in the Desktop (✕, ⌘⌫ or Delete…) stops its process and hides its row from
> the panel, the session switchers, Go to…, ⌘1…⌘9, the target lookup of Work on It and the phone's start, and
> writes nothing. Its row is deleted (`TerminalSessionQueries.delete`; its `terminal_session_targets` by
> cascade, its asks' `session_id` set NULL) only when the Undo window (5 s from the last delete of the batch)
> ends, or when the app quits; a workbench deleted meanwhile cascades it. Until then **Undo** brings back every
> session of the batch with its row, links and asks byte-identical, not running. A failed delete brings the row
> back with an error, never keeps it hidden. A live session that is working, at a permission prompt, running
> without a reported state, waiting on an ask or ready to check is deleted only after a confirmation.
>
> **Why locked:** Owner decision (#480, variants 5 + 1 + 2): one-gesture delete is safe only because Undo is
> complete; an Undo that lost the report or the asks would be worse than the dialog it replaces.
>
> **Test guards:** `WatchtowerDesktop/Tests/WorkbenchesViewModelSessionsTests.swift`:
> `testProj16_DeleteHidesAtOnceAndWritesNothingUntilTheWindowEnds`, `testProj16_UndoBringsBackTheRowWithItsLinksAndAsks`,
> `testProj16_CommitAfterTheWindowDeletesWithCascades`, `testProj16_QuitCommitsPendingDeletes`;
> `WatchtowerDesktop/Tests/Core/SessionDeletePolicyTests.swift::testProj16_QuickDeleteTable`.

The inventory header's module list names Core services one by one, so its WatchtowerCore line gains
`Services/{SessionPanelSections,PendingSessionDeletes,SessionDeletePolicy}.swift`.

## 9. Open questions (recommendation first)

1. **Row click and the keyboard.** (a) **Keep today: a row click sends the keyboard into the session's terminal**;
   the panel holds the keyboard after a click on its empty space, the group header, a ✕ or Undo — rec. (b) A row
   click keeps the keyboard in the panel until the owner clicks the terminal or presses Return/Esc — faster
   cleanup, but every session switch costs one more action before typing, and today's "click, type" habit breaks.

Decided here (not open): batch Undo (§4.2); purple + `checklist` (§2.3); Ready to check stays in the main list
(§3.1); ⌘N numbers main first, group only while open (§3.6); a collapsed group pins the on-screen row instead of
auto-expanding (§3.3); the group orders by finish time (§3.2); standalone terminals get Undo only (§4.1).

## 10. Interaction with #561 and ordering risk

#561 (a new session row hidden under the asks stack) changes the same `List` in `WorkbenchSessionsPanel` —
likely its scroll position or the stack's height. Both edit `WorkbenchSessionsPanel.body`. Land #561 first or
rebase this plan's view task (plan Task 8) onto it; the conflict is textual (the `List` block), not semantic —
#480's new rows (group header, pinned row) must also scroll into view when they appear, which is #561's concern
to keep generic ("a row that appears is visible"), not a per-row fix.
