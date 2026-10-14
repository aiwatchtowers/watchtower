# Sessions panel: a new session hides under the asks stack (board #561) — Fix Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After "+" (or ⌘T, Work on it, a switcher pick) the selected session row of the workbench sessions panel is always fully visible, whatever the "Waiting for you" stack above it holds (0, 1, 3, 5+ asks), and the list never jumps when the stack changes.

**Status of the analysis:** static only (no build or repro was possible while writing this). The ranking below is from the code; Task 1 confirms it on a dev build before any fix lands.

**Plan style:** no code bodies; files, interfaces, test cases, verification commands. Task-scope checks only; the full gate runs once in the final task.

## Root cause (ranked, with evidence)

What the panel is: `WorkbenchSessionsPanel.body` (`WatchtowerDesktop/Sources/Views/Workbench/WorkbenchSessionsPanel.swift:21-53`) is a `VStack` of header, `OwnerAskStackSection`, the SESSIONS label, a plain `List` (`.clearPlainList()`, rows `.panelTab`) and `WorkbenchFilesSection`. The `List` is the only flexible child, so it gets whatever height is left after the stack (up to 220 pt of rows, `OwnerAskStackSection.swift:17,53`, plus its title, quick notices, the "Outside the app ▸ N closed" line and padding). With 3 asks and the outside line that is roughly 280 pt, so the list is short and scrolls with a modest number of sessions.

**H1 — confirmed as the root cause (high confidence).** A new session is inserted as row 0 and nothing ever scrolls the list to it.
- Row order: `TerminalSessionOrder.apply` puts sessions never placed by a drag first, newest first (`Sources/WatchtowerCore/Services/TerminalSessionOrder.swift:14-23`), so "+" always inserts at index 0.
- There is no `ScrollViewReader`, `scrollTo`, `scrollPosition` or `defaultScrollAnchor` anywhere on the panel (`grep` over `Sources/`: the only `scrollTo` users are the calendar, chat feed, ideas, logs, Open Quickly, ask drawer and artifact comments).
- The selection is only a fill: `panelTab(isSelected: vm.panelSelection == .session(row.id))` (`WorkbenchSessionsPanel.swift:47`), deliberately without List selection (`:30-34`), so AppKit's own "scroll selected row to visible" never runs either.
- The list is an `NSTableView` inside an `NSScrollView`: an insertion at row 0 keeps the clip view's bounds origin. Whenever that origin is not exactly 0 (the owner scrolled the long list even slightly, elastic rest after a scroll, or SwiftUI's estimated-then-measured row height for the inserted row — a session row is two-three lines with the tab's 4 pt padding, taller than an estimate), the new row 0 lands partly above the visible top, i.e. under the SESSIONS label. That is the screenshot: row 0's title cut, the selected tab's fill half visible. With 0 asks the list is tall enough that it often does not scroll at all, which is why the owner sees it "when there are open asks".
- Ordering trap that any fix must handle: `activate` sets the layout (so `panelSelection` already names the new session) **before** `loadSessions` adds the row (`Sources/ViewModels/WorkbenchesViewModel+Sessions.swift:676-679`). A plain `onChange(of: panelSelection) { proxy.scrollTo(id) }` fires while the row is not yet in the `List` and does nothing. The scroll must also run when the selected id first appears in the rows.

**H2 — not a cause on its own (medium confidence; checked in Task 1).** The stack does measure itself after layout (`rowsHeight` starts at 0 and is set by `onGeometryChange`, `OwnerAskStackSection.swift:21,51,53`), so the list's frame shrinks one pass later. But a frame change of an `NSScrollView` with a flipped document keeps the clip's top origin: a shrink cuts the bottom, not the top. The stack only aggravates H1 by making the list short enough to scroll. No stack-driven scrolling is added (it would jerk the list when an ask arrives, against Done 2).

**H3 — ruled out (high confidence).** `PanelTab` pads the content by 4 pt vertically *inside* the row and draws its fill in `.background` of that padded content; the only overhang is trailing (`trailingOverhang = 16`, `Sources/Views/Components/PanelListStyle.swift:87-104`). Row insets are 1 pt top/bottom. Nothing extends above the row's bounds, so the list's clip cannot cut half a row, and nothing in the `VStack` draws over the list (each child has its own frame; the stack's rows sit in their own clipping `ScrollView`).

**H4 (folded into H1):** the "half" height of the cut matches an estimated-vs-measured height of the inserted row while the table keeps the clip origin; Task 1 records whether the cut also happens from offset 0 (then this is the mechanism) or only after a scroll. The fix below covers both.

## Fix

Follow the selection, and only the selection:
1. A pure WatchtowerCore policy decides when the panel scrolls: when `panelSelection` changes to a session, or when the selected session's id first appears among the rows (the insert case). Status/report refreshes, asks arriving or closing, and stack height changes never scroll.
2. The panel wraps its `List` in a `ScrollViewReader`, keeps the policy's pending target, and on the policy's yes calls `proxy.scrollTo(id)` with **no anchor** (minimal scroll: a fully visible row does not move, a cut one comes fully into view; the new row 0 aligns to the top) on the next main-queue turn, so the table already has the row.
3. Same treatment for the AI Chat history (`ChatSidebarView.swift:36-51`, same `panelTab`, no follow either): follow `historyVM.selectedConversationID` with the same policy (a new chat lands in TODAY below New chat and PROJECTS).

No contract in `docs/inventory/workbench.md` (PROJ-01..15) covers the panel's scrolling; no contract change, no migration, no Go change.

## Conflict with #480 (finished group, ✕ / ⌘⌫ delete with Undo)

Both touch the `List` block of `WorkbenchSessionsPanel.body` (`:35-51`). Recommended order: #561 first (small, one file plus a Core helper), #480 rebases onto it. #480 should reuse the follow policy: after a delete the selection moves to the neighbour row (#480 item 3) — that is a `panelSelection` change and scrolls for free; a selected session inside the collapsed "▸ N finished" group must map to the group's row id (or expand the group first, as #480 decides) before `scrollTo`, so the policy takes the visible row ids, not the sessions. #480's Undo toast at the panel bottom shortens the list like the stack does — no extra handling needed (bottom cut, not top). Hidden pending-delete rows must not be scroll targets (they are not in the row ids, so the policy keeps the target pending and drops it on the next selection change).

## Tasks

### Task 1 — Reproduce and record before screenshots

Depends on: none. Manual, on a dev build (`make app-dev`) of the branch, one Swift build at a time.

- Workbench with ≥ 8 sessions; matrix of 0, 1, 3, 5+ open asks (5+ = the stack at its 220 pt cap) and the "Outside the app ▸ N closed" line on/off.
- For each: list at the top, press "+"; then scroll the list a few points down, press "+". Record whether the new row is cut, and whether the cut happens from offset 0 (H4 note).
- Also: with the list at the top, let an ask arrive and close one (`ask_owner` / answer) — does the top row move? (H2 check.)
- Save screenshots (light mode) for the PR "before" section. Redact workbench and session titles if real.

### Task 2 — `SessionPanelScrollPolicy` in WatchtowerCore

Depends on: none (can run in parallel with Task 1).

Files: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionPanelScrollPolicy.swift` (new), `WatchtowerDesktop/Tests/Core/SessionPanelScrollPolicyTests.swift` (new).

Interface (value type, generic over the id so the chat history reuses it):
- `package struct SessionPanelScrollPolicy<ID: Hashable>: Equatable` with `package private(set) var pending: ID?`.
- `package mutating func selectionChanged(to id: ID?, rows: [ID]) -> ID?` — new target; returns `id` to scroll now when it is in `rows`, otherwise stores it as `pending` and returns nil. `nil` clears `pending`.
- `package mutating func rowsChanged(_ rows: [ID]) -> ID?` — returns and clears `pending` once it appears in `rows`; otherwise nil (never re-scrolls to an already-shown selection).

Test cases:
- `testSelectionOfListedRowScrollsAtOnce` — row present → returns it, `pending` nil.
- `testNewSessionSelectedBeforeInsertScrollsWhenRowAppears` — the `activate` order: select id 9 with rows [5, 4] → nil, pending 9; `rowsChanged([9, 5, 4])` → 9; pending nil.
- `testRowsRefreshWithoutPendingNeverScrolls` — status refresh / reorder / ask change → nil (Done 2: no jerk).
- `testSelectionClearedDropsPending` and `testNewerSelectionReplacesPending` (a quick second "+": only the latest id scrolls).
- `testPendingRowNeverAppearingStaysQuiet` — creation failed/row deleted: repeated `rowsChanged` without it → nil.
- `testSameSelectionAgainDoesNotRescroll` — re-render with the same selection → nil (the owner's own scroll stays put).

Verify: `make test-swift FILTER=SessionPanelScrollPolicyTests > log 2>&1; echo "exit=$?"`.

### Task 3 — Follow the selection in the sessions panel

Depends on: Task 2.

Files: `WatchtowerDesktop/Sources/Views/Workbench/WorkbenchSessionsPanel.swift`.

- Wrap the `List` (`:35-51`) in `ScrollViewReader`; `@State private var scroll = SessionPanelScrollPolicy<Int64>()`.
- `.onChange(of: selectedSessionID, initial: true)` (derived from `vm.panelSelection`, `.session(id)` only) → `scroll.selectionChanged(to:rows:)`; `.onChange(of: rowIDs)` (`vm.sessionRows(sessions).map(\.id)`) → `scroll.rowsChanged`. A non-nil result → `DispatchQueue.main.async { proxy.scrollTo(id) }` (no anchor, no animation — the insert already animates). Reset the policy on `project.id` change.
- The rows' `ForEach` already identifies rows by `row.id` (`Row: Identifiable`, `id = session.id`), so `scrollTo` needs no extra `.id`.
- Self-review: review-rules "Swift / Desktop conventions"; the state is view-local by design (it is about this view's scroll, nothing to survive navigation; a return to the panel re-runs `initial: true`).

Tests: logic is covered by Task 2. Optional ViewInspector smoke in `WatchtowerDesktop/Tests/WorkbenchSessionsPanelTests.swift` only if the panel already builds under ViewInspector with a test VM (it asserts the `List` sits inside a `ScrollViewReader`); scroll position itself is not inspectable, so the manual matrix of Task 5 is the real check.

Verify: `make test-swift FILTER=SessionPanelScrollPolicyTests`, `make lint-diff`.

### Task 4 — Same follow in the AI Chat history

Depends on: Task 2. Run after Task 3 (one Swift lane).

Files: `WatchtowerDesktop/Sources/Views/Chat/ChatSidebarView.swift`.

- Same wrapper keyed on `historyVM.selectedConversationID` and the flattened conversation ids of `historyVM.sections`. Project rows (`sidebarRowKey`) are not targets.
- Verify: `make test-swift FILTER='SessionPanelScrollPolicyTests|ChatHistoryViewModelTests'`, `make lint-diff`.

### Task 5 — Manual check, docs, gate

Depends on: Tasks 3, 4.

- Re-run the Task 1 matrix: in every cell the new session is fully visible and has the tab fill right after "+" (Done 1); with the list scrolled down, "+" brings the new row in; an ask arriving/closing and the stack growing/shrinking do not move the list (Done 2); an owner scroll is not undone by a status refresh. AI Chat: New chat, then send the first message — the new conversation is visible in TODAY with the list scrolled down.
- "After" screenshots for the PR next to Task 1's (Done 3).
- `docs/features/workbench.md`: one line in the panel section — the panel follows the session on screen (new or picked), never the stack. `docs/app-guide.md` only if it describes the panel's scrolling (it currently does not need a change otherwise).
- Gate before the PR: `make test-swift`, `make lint-all` (no Go change, so `make test` only if the controller's phase gate asks for it).
