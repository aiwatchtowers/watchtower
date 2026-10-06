# Workbench board hierarchy — plan (2026-10-06)

**Spec:** `docs/superpowers/specs/2026-10-06-workbench-board-hierarchy-design.md` (Parts 2–6 are
the contracts; quote them, do not re-decide them).
**Branch:** `feature/board-hierarchy`, one worktree, one implementer at a time (Swift-only work:
one ML-stack link at a time).
**Board:** #253; tasks map to #254 (Tasks 1–2), #255 (Tasks 3–4), #256 (Tasks 5–6).

Inner loop per task: `make test-swift FILTER=<classes>` and `make lint-diff`. Full gate
(`make test-swift`, `make lint-all`) once at the end, before the PR. Every UI string is English.
House rules: `docs/review/review-rules.md` "Swift / Desktop conventions".

---

## Task 1 — Lanes in `WorkbenchBoardKanban` (Core)

**Depends on:** none.
**Files:** `Sources/WatchtowerCore/Services/WorkbenchBoardKanban.swift`,
`Tests/Core/WorkbenchBoardKanbanTests.swift`.
**Produces:** `WorkbenchBoardKanban.Lane { root: WorkbenchBoardNode?, title, columns, progress,
showsCard(_:) }`, `lanes: [Lane]`, per-column `totals`; `WorkbenchBoardLanesMode`
(`group` | `none`); `WorkbenchBoardPreferences.lanesMode`, `.foldedLanes: Set<Int>` (keys in
spec Part 2). Existing `columns` keep their behaviour unchanged (the "None" layout).
**Tests:**
- two top-level groups + one top-level leaf → two lanes then No group; no top-level leaf → no
  No group lane;
- lane order by `WorkbenchBoardOrder` (high before medium; equal priority → status, id);
- a leaf two levels under a lane root has breadcrumb = the one middle group; a direct child
  has none;
- a nested group is cards in its top-level lane, never a lane;
- lane Done folded: `doneFolded == true`, count kept, unless Show done or a non-empty search;
- `lane.showsCard` false for a card of another lane;
- totals per status equal the sum over lanes;
- an empty lane (all closed, Show done off) hidden; with Archive on its archived cards return;
- preferences round-trip both keys; an unknown lanes value reads `group`; a folded id that is
  no longer a lane is ignored by the view model, not dropped from storage.

## Task 2 — Lanes in the kanban view (#254)

**Depends on:** Task 1.
**Files:** `Sources/Views/Workbench/WorkbenchBoardKanbanView.swift`,
`WorkbenchBoardCardView.swift` (full-wrap caption for kanban), `WorkbenchBoardView.swift`
(Lanes menu in the header), `Sources/ViewModels/WorkbenchBoardViewModel.swift` (`lanesMode`,
`foldedLanes`, `toggleLane(_:)`), `docs/app-guide.md` (Kanban paragraph).
**Consumes:** Task 1. Lane header click → `vm.openGroup(id)` stub that just selects the root
(Task 4 swaps it to the group panel); double-click → no-op until Task 6.
**Produces:** a totals header row; a lane = fold chevron + `#id` + title + progress bar +
status chip, then the columns; folded Done row "✓ N done — show" (per-lane session state).
**Tests:** ViewModel — `toggleLane` persists through `WorkbenchBoardPreferences`; switching
`lanesMode` to `none` renders `columns` (assert via the VM's exposed layout enum). Manual: drag
inside a lane moves status; drag into another lane is refused.

## Task 3 — Panel state in the view model (Core + VM)

**Depends on:** none (may run before Task 2 in the same lane).
**Files:** `Sources/WatchtowerCore/Models/Target.swift` (`branch`, `pr`, decoded from the
existing columns, default ""), `Sources/ViewModels/WorkbenchBoardViewModel.swift`, a VM test
file under `Tests/` next to the existing board VM tests.
**Produces:** `panelPath: [Int]`, `selectedTargetID` derived from it, `select(_:)` (reset),
`push(_:)`, `back()`, `canGoBack`; `selectedHistory: [TargetStatusChange]` loaded with the
comments; `saveIntent(_:) -> Bool` via `TargetQueries.updateIntent` + `onOwnerWrite`.
**Tests:** select resets; push/back; back on one entry is a no-op; reload after the last id is
deleted pops to the previous surviving id, then closes; `boardFocus` handoff resets the path;
history newest first after load; `saveIntent` failure keeps `errorMessage` and returns false;
`Target` decodes `branch`/`pr` (TestDatabase schema already has the columns — verify).

## Task 4 — `WorkbenchTargetPanel` replaces the popup (#255)

**Depends on:** Tasks 2, 3.
**Files:** new `Sources/Views/Workbench/WorkbenchTargetPanel.swift` (+ small subviews in the
same folder if it passes ~300 lines), delete `WorkbenchTargetDetailCard.swift` (keep
`WorkbenchDetailSectionHeader` by moving it), `WorkbenchBoardView.swift` (trailing overlay,
`PanelResizeHandle`, width in UserDefaults `projects.boardPanelWidth`, no scrim, Esc order),
List: a click on a group row opens group mode (it already selects; mode is derived),
`docs/app-guide.md` (Board paragraph: the card → the panel).
**Consumes:** Task 3; Task 2's lane header → `select(rootID)`.
**Produces:** task and group modes per spec Part 3; group sub-task tree from
`WorkbenchBoardOutline` rooted at the group.
**Tests:** Core helper for the group summary (`done`, `total`, breakdown by status, zeros
omitted, archived per toggle) with unit tests; the sub-task tree rows (closed folded into one
row). Manual: open card → click parent link → "‹" back; click another card while open swaps;
Esc closes; terminal split unaffected; description edit saves on ⌘↩ and cancels on Esc.

## Task 5 — Board scope at any depth (Core)

**Depends on:** Task 1.
**Files:** `WorkbenchBoardKanban.swift` (scope replaces `filterOptions`/`filterRootID`),
`WorkbenchBoardOutline` (rows for a scope), `WorkbenchBoardPreferences` (`boardScopeID` on the
existing filter key), new `Tests/Core/WorkbenchBoardScopeTests.swift`.
**Produces:** `WorkbenchBoardScope.resolve(_ id: Int?, in roots:, showArchived:) -> (node?,
path: [WorkbenchBoardNode])`; scoped lanes (own leaves first as "Tasks", nested groups as
lanes); scoped List rows.
**Tests:** a top-level id stored by the old filter resolves the same; a depth-3 group
resolves with a 3-entry path; stale / leaf / archived-with-Archive-off → root; scoped lanes
order; scoped List rows start at the scope's children; search inside a scope stays inside.

## Task 6 — Path bar and entry points (#256)

**Depends on:** Tasks 4, 5.
**Files:** `WorkbenchBoardView.swift` (path bar, remove the filter menu, Esc order: panel,
then one scope level), `WorkbenchBoardKanbanView.swift` (lane header double-click),
`WorkbenchTargetPanel.swift` (Open group), the target context menu (`Open Group` on a target
with children), `WorkbenchBoardViewModel.swift` (`enterScope`, `leaveScope`, `scopePath`),
`docs/app-guide.md`.
**Tests:** VM — enter/leave persists and survives `mode` List ↔ Kanban; leaving from depth 2
goes to depth 1; a path click jumps to that level. Manual: all three entry points; Esc order.

---

## Gate and PR

Controller: `bash scripts/dev-health.sh`, then full `make test-swift`, `make lint-all`; the
`local-review` skill's final round (debate-review); one PR for the branch; the owner's manual
check filed as an ask with the Task 2/4/6 manual steps.
