# Workbench board hierarchy — design (2026-10-06)

**Board:** feature target #253 "Канбан с иерархией: все карточки по группам и нормальная
карточка таски" — #254 (swimlanes, K), #255 (side panel, N + O), #256 (enter a group, P).
**Plan:** `docs/superpowers/plans/2026-10-06-workbench-board-hierarchy.md`.
**Desktop only.** No migration, no Go change, no new MCP tool.

**Owner rulings (2026-10-06, ask #87):** "＋ Add" sub-task is out of this feature (its own
board target); the panel lies over the board, no scrim.

Part 1 is the one-page owner spec. Parts 2–6 are the technical spec: decisions and contracts
for the implementing sessions.

---

## Part 1 — For the owner (one page)

**Problem.** Kanban shows leaf cards in five columns with a one-line, cut-off breadcrumb.
On a board with a dozen groups you cannot tell which card belongs where, and a group itself
is never a card, so its progress is invisible. Opening a target shows a modal card over a
dimmed board: you cannot click the next card without closing it first, a group opens the same
card as a leaf (with a status you are not allowed to set), and there is no way back to the
parent.

**What you will see.**
- **Swimlanes (K).** In Kanban every top-level group is a horizontal lane: a header you can
  fold (`#id`, title, an "N/M" progress bar, its status) and the same To Do … Done columns
  inside. Top-level tasks without a group sit in a **No group** lane at the bottom. Totals per
  column stay above the lanes. Card titles wrap in full; the path below the title
  (`Workbench header › Git branch ›`) is no longer cut. Done in every lane is folded to
  "✓ N done — show"; **Show done** opens them all. A **Lanes: By group / None** switch keeps
  today's flat kanban one click away. Dragging a card between columns of its lane changes its
  status as now. Folded lanes are remembered per workbench.
- **A side panel instead of the popup (N + O).** A click on a card opens it in a panel on the
  right side of the board, over it, resizable (~460 pt). The board stays live: click another
  card and the panel switches to it. One panel, two shapes:
  - *Task:* `#id` (click copies), **Work on It**, **⋯** (the card's menu), ✕; a parent link
    "▦ #249 … ›" that opens the parent in the same panel, with "‹" to go back; title; Status
    and Priority menus; branch and PR; the description folded with **Show all**, editable on
    click; images; **Asks** (instead of the Documents field, see below); **Comments | History** tabs; the comment field pinned at the
    bottom (⌘↩ / ⌃↩).
  - *Group:* the same, except a **GROUP** tag; the status is not a menu but reads
    "from sub-tasks", with an "N of M done" bar and a per-status breakdown; **Work on It**,
    with **Open group** beside it; a **SUB-TASKS** tree (nested groups fold, done ones fold into one row,
    a click opens the sub-task in the panel).
  The panel opens from a card (task) and from a lane header or a group row in List (group).
  Esc or ✕ closes it.
- **Enter a group (P).** **Open group** in the panel, or a double-click on a lane header,
  shows only that group: a path "Board › #249 <title>" with its progress and
  "✕ Leave group" (Esc). Its direct tasks are the first lane, its nested groups get their own
  lanes. Every step of the path is clickable back up to Board. It is today's kanban filter,
  widened to any level; it stays when you switch List ↔ Kanban (List shows that subtree).

**Decisions** (answered 2026-10-06: both as recommended):
1. **"＋ Add" sub-task in a group's panel.** Today only the agent creates workbench targets;
   the Desktop has no write path for them. *Recommended:* leave it out of this feature and
   file it as its own target — it is a new owner write (status history, rollup, the agent's
   brief) that deserves its own contract. *Alternative:* a title-only "＋ Add" now.
2. **Panel over the board or beside it.** *Recommended:* over the board (the kanban keeps its
   full width — the reason the popup replaced a side column in board #155), no dimming.
   *Alternative:* a real side column that narrows the board.

**Amended 2026-10-08 (board #472, spec `2026-10-08-workbench-group-work-on-design.md`):** a group's panel shows **Work on It** as the primary button with **Open group** beside it; Work on It is also on a group lane header and in every target's context menu.

**Why there is no "Documents" field.** The #255 sketch has one, but targets no longer have
documents. On 2026-10-03 the Documents tab and documents attached to a target were removed
(the owner asks feature): a spec or plan now reaches you as a **review ask** filed on the
target — the document opens inside the ask, with the agent's notes and your comments. So the
panel shows an **Asks** section instead: every ask about this target (reviews, checks,
questions), title and status, newest first. A click on one opens it in the ask drawer, exactly
like a row in the "Waiting for you" stack. Today that section is read-only; this makes it the
way into the target's documents.

**Not in scope.** Dragging a card into another lane (that would move it to another group —
the List's drag-to-nest and **Move to** stay the way to regroup); creating targets from the
Desktop (decision 1, now #410); any change to what the agent sees.

**Done when** lanes, the panel in both shapes and entering a group work on the live board, the
popup is gone, parent ↔ sub-task navigation goes back with "‹", the layout has tests in
WatchtowerCore, and `docs/app-guide.md` describes the new board.

---

## Part 2 — Lanes (`WorkbenchBoardKanban`, #254)

- **Pure, in WatchtowerCore.** `WorkbenchBoardKanban` gains a `lanes: [Lane]` output next to
  the existing `columns` (which stay — they are the "Lanes: None" layout and the totals row).
  `Lane { root: WorkbenchBoardNode?, columns: [Column], progress: (done, total) }`; `root` nil
  = the No group lane. Card collection, search, archive and Show done rules are the existing
  ones, applied per lane — one code path, not a second collector.
- **Which nodes make lanes.** At the board root: each top-level target with children is a
  lane; top-level leaves go to No group (last, only when non-empty). Inside an entered group
  (Part 4) the same rule applied to the group's children: the group's own leaf children form
  the first lane (`root` = the group itself, title "Tasks"), each child with children is a
  lane. Deeper levels are cards with a breadcrumb, never lanes.
- **Lane order:** `WorkbenchBoardOrder` on the lane roots (priority, then status, then id),
  No group last. A lane with no card left after the filters is hidden, except while a search
  is empty and the lane's root is open (it shows "No open tasks").
- **Breadcrumb** is relative to the lane root: the chain *below* the lane root, so a card
  right under it has none. The card wraps title and breadcrumb fully (`lineLimit(nil)`),
  dropping `truncationMode(.middle)` for kanban cards.
- **Done per lane.** Done is folded per lane unless Show done is on or a search is active:
  the lane's Done column renders as one row "✓ N done — show" which unfolds that lane's Done
  only (session state, not remembered). The global `doneCap` stays for "Lanes: None".
- **Totals row:** per column, the sum over the lanes shown, above the lanes; the column
  headers move there and lanes have no column titles of their own.
- **Drops** are accepted only by a column of the card's own lane (`Lane.showsCard(id)`); a
  drop from another lane is refused like a foreign payload today.
- **Preferences** (`WorkbenchBoardPreferences`, UserDefaults, the `projects.` prefix kept):
  `projects.boardLanes.<id>` = `"group"` (default) | `"none"`;
  `projects.boardFoldedLanes.<id>` = an array of lane root ids (an id no longer a lane is
  ignored; No group folds under id `0`).

## Part 3 — The side panel (#255)

- **Placement.** A trailing panel inside the Board pane, overlaid on the board (ZStack,
  `.trailing`), no scrim; width 460 by default, dragged between 360 and 720 with the existing
  `PanelResizeHandle`, remembered globally (`projects.boardPanelWidth`). Not `.inspector` and
  not `.sheet`: both would act on the window, and the terminal split must stay untouched.
  Esc keeps today's pane-scoped handling (`onExitCommand`, never a window shortcut).
- **One view, two modes.** `WorkbenchTargetPanel` replaces `WorkbenchTargetDetailCard`
  (deleted); the mode is `node.children.isEmpty ? .task : .group`, never stored.
- **Navigation stack** in `WorkbenchBoardViewModel`: `panelPath: [Int]` (target ids). A
  board click resets it to `[id]`; the parent link and a sub-task click push; "‹" pops (shown
  only when the path has more than one entry). `selectedTargetID` = `panelPath.last`. A
  reload that loses the last id pops to the nearest surviving one, or closes the panel. The
  `boardFocus` handoff from the Session view resets the path as a board click does.
- **Parent link** shows the nearest parent's `#id` and title; absent at top level.
- **Fields.** Status/priority menus and `#id` copy are today's. Branch and PR are read-only
  text (the `Target` model gains `branch`/`pr`, read from the existing columns; empty =
  the row is hidden). Description: folded to 6 lines with **Show all** when longer; a click
  switches to an editor, ⌘↩ or focus loss saves through `TargetQueries.updateIntent` (owner
  write, reported to `onOwnerWrite`), Esc cancels. Images are today's section. Asks are
  today's section (`OwnerAskQueries.targetAsks`), but each row is a button that calls
  `WorkbenchesViewModel.showAsk(askID, projectID:)` — the stack row's path, so a click never
  starts an agent; a `false` return shows "This ask is gone" in the panel's error row.
- **Comments | History.** History lists `TargetQueries.statusHistory` (already in Core),
  newest first: "from → to", actor, relative time. Loaded with the comments on selection and
  on reload, not per tab switch.
- **Group mode.** Status shown as a label "<status> · from sub-tasks", no menu; "N of M done"
  over the group's leaves with a breakdown by status (counts only, statuses with zero
  omitted); **Work on It**, with **Open group** (Part 4) beside it; a SUB-TASKS tree from the node's
  children (`WorkbenchBoardOutline` rows rooted at the group, done/dismissed folded into one
  "✓ N closed" row that unfolds in place; nested groups fold, folds are panel-local state).
  Archived sub-tasks follow the board's Archive toggle.
- **Opening a group** in the panel: a click on a lane header (not its fold chevron), a click
  on a group row in List. A card opens task mode.

## Part 4 — Entering a group (#256)

- **One filter, generalised.** `kanbanFilterRootID` becomes `boardScopeID` (any target id
  with children, any depth), used by both Kanban and List; `filterOptions` (top-level only)
  is replaced by the scope path. Stored under the existing key
  `projects.boardKanbanFilter.<id>` so the remembered top-level filter carries over. A stale
  id (deleted, now a leaf, or archived with Archive off) resolves to the board root, as today.
- **List in a scope** shows the scope's subtree (its children as the top rows).
- **Path bar** above the board while scoped: "Board › #A <title> › #B <title>" — every
  ancestor clickable, then the scope's progress "N of M" and "✕ Leave group". Esc leaves one
  level only when the panel is closed (panel first, then scope). The parent filter menu in the
  header is removed; the path bar replaces it.
- **Entry points:** Open group (panel), double-click on a lane header, and the List context
  menu's new **Open Group** on a target with children.

## Part 5 — Error handling and invariants

- Every new owner write is the existing mutator (`setStatus`, `setPriority`, `rename`,
  `updateIntent`, comments); a failure shows in the panel's error row as today; a failed
  intent save keeps the draft.
- A group's status is never written from the panel (PROJ-05: it follows its children).
- Drag-and-drop never changes a parent (Part 2); PROJ-09 is unaffected.
- No behaviour visible to the agent changes; no inventory contract changes.

## Part 6 — Tests

WatchtowerCore (`Tests/Core/WorkbenchBoardKanbanTests.swift` and a new
`WorkbenchBoardScopeTests.swift`): lanes per top-level group and the No group lane (and its
absence); lane order; relative breadcrumb; nested group as cards inside the top lane; scoped
lanes (own tasks first, nested groups as lanes); per-lane Done fold vs Show done vs search;
drop refused across lanes; totals equal the lane sums; folded-lane and lanes-mode preferences
round-trip, stale ids ignored; scope resolution (stale, leaf, archived) and the path; panel
path push/pop/reset and the reload fallback (ViewModel test with an in-memory pool).
