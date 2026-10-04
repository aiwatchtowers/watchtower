# Workbench board archive — design (board #301, 2026-10-04)

Status: approved by the owner 2026-10-04 (decisions A–D as recommended). Migration number: 00103 (00102 was taken by the turn-order migration).

## 1. What the owner sees

- **Closed work leaves the board by itself.** A `done` or `dismissed` target
  whose whole subtree has been closed for more than **N days** (default
  **14**, set per workbench) is *archived*: it no longer appears in the List,
  the Kanban, the agent's `workbench_board` or the session brief's
  target lines. Nothing is deleted — comments, images, status history, branch
  and PR stay; `get_target #id` and the board search (`#id` or words) still
  find it.
- **Groups go whole.** An umbrella target is archived only when everything
  under it is closed and the last of it closed more than N days ago. A closed
  sub-task of a group that is still open is archived on its own, but the
  group's counter keeps counting it (7/12 stays 7/12).
- **Opening the archive.** The board toolbar gets an **Archive (K)** toggle
  next to **Show done** (K = archived targets on this board). On, archived
  targets come back in both List and Kanban, dimmed with an "Archived" tag
  (Kanban: in the Done/Dismissed columns, uncapped). Board search always
  includes archived matches.
- **Restoring = reopening.** Set an archived target's status to anything open
  (status menu, or a drag in Kanban; the agent's `update_target` likewise) and
  it is back on the board at once. Adding an open sub-target under an archived
  group also brings the group back.
- **The setting.** Workbench header menu → **Archive Closed Targets After ▸
  Never / 3 / 7 / 14 / 30 / 90 days**, default 14. Changing it applies
  immediately, both ways (shortening archives more now, lengthening brings
  targets back), because nothing is stored per target.
- **Unmerged work is never hidden.** The drift check still looks at archived
  targets, so a done target whose branch never merged is reported exactly as
  today, even if it is archived.

## 2. Technical decisions

1. **Storage: a SQLite view, not an `archived_at` column and not a Go/Swift
   age filter.** Migration `00102` (next free number on
   `feature/polish-wave-1004`) adds `projects.archive_after_days INTEGER NOT
   NULL DEFAULT 14 CHECK (archive_after_days BETWEEN 0 AND 365)` (0 = Never)
   and a view `workbench_target_archive(target_id, project_id, archived)`.
   *Why:* one implementation read by Go and Swift alike (the PROJ-05/06
   "rule lives in SQLite, no dual path" precedent); nothing is ever written,
   so "nothing is deleted" and "reopening restores" hold by construction, and
   a changed N applies retroactively. An `archived_at` column would need a
   writer, an un-archive trigger for every reopen path, a re-sweep on every N
   change, and would lag between sweeps. A filter coded in Go and in Swift
   would duplicate the subtree rule in two languages.
2. **Who archives: nobody.** The view decides on every read. No daemon
   phase, no lazy write on read (which would also break the `query_only`
   handle of the dev-mode MCP).
3. **The rule (the view).** A workbench target is archived iff
   `archive_after_days > 0`, it and every descendant on the same board are
   `done`|`dismissed`, and the newest *close time* among them is older than
   `archive_after_days` days. Close time = the target's latest
   `target_status_history.changed_at` (PROJ-06), else its `updated_at` (a
   target with no history). Consequences, all by construction: an archived
   target's whole subtree is archived; a hand-set `done` parent with an open
   child is never archived; `snoozed`/`blocked`/open statuses never are; a
   re-parent (PROJ-09) of open work under an archived group un-archives it.
   *Why the subtree's newest close and not the target's own:* the PROJ-05
   rollup closes a parent when its last child closes, but a hand-set or
   dismissed parent may predate its children's closes — the group must wait
   for its last piece.
4. **Board reads.** `db.GetWorkbenchBoard` keeps its signature and still
   returns the full forest; it now fills `BoardNode.Archived` from the view.
   A pure `db.WithoutArchived` drops archived subtrees and sets the kept
   node's `ArchivedChildren`. *Why:* counters, the drift check and the
   session report need the full tree; display callers opt into the pruned
   one.
5. **Drift check (`done_but_unmerged`).** `workbenchcheck.Check` keeps
   receiving the full board, and its 14-day `DoneRecentWindow` stays
   independent of N. A finding on an archived target is shown in the brief,
   the Desktop banner and `workbench check` as today. With N ≥ 14 the two
   never overlap; with N < 14 the finding still surfaces. The other kinds
   concern open targets, which are never archived. *Why:* the owner's
   requirement "do not hide unmerged work" wins over "archived is invisible".
6. **MCP tools (workbench session).**
   - `workbench_board`: archived subtrees omitted; a node that lost archived
     children carries `archived_children: k`; the answer carries
     `archived: K`. New argument `include_archived` (default false).
     See Owner decision A for closed-but-not-archived targets.
   - `workbench_info`: `targets_by_status` still counts the whole board; new
     `archived` count.
   - `list_targets`: in a workbench session archived targets are left out
     unless `include_archived: true` (also with an explicit `status`).
     Outside a workbench session nothing changes (PROJ-01).
   - `get_target`: unchanged lookup, answer gains `archived: true|false`.
   - `update_target`, `create_targets` (with an archived `parent_id`),
     comments: allowed on archived targets; reopening is the restore.
   - `update_workbench` does **not** gain N — the owner's setting.
7. **Session brief.** Built from the pruned board; the header line keeps the
   status counts of the non-archived board and adds `, K archived`. The
   drift section is unchanged (decision 5).
8. **CLI.** `workbench board` prints the pruned board, `--archived` prints
   all; `workbench show` prints `Archive after: N days|never`. The briefing's
   `=== WORKBENCHES ===` block and `internal/sessionreport` keep reading the
   full board (a session's report must show work it closed even once
   archived); the implementer confirms each remaining `GetWorkbenchBoard`
   caller against that rule.
9. **Desktop List/Kanban.** `WorkbenchQueries.board` joins the view and fills
   `WorkbenchBoardNode.archived`; nodes stay in the tree, so the card counter
   (`children.done/children.total`) is unchanged. `WorkbenchBoardOutline.rows`
   and `WorkbenchBoardKanban` take `showArchived` and drop archived nodes
   when it is off (search ignores it and always matches archived ones).
   `WorkbenchBoardViewModel.showArchived` is session-only like `showDone`.
   *Why load everything:* a few hundred rows read cheaply; the cost the owner
   saw is rendering, which the filter removes.
10. **Setting location.** The workbench header menu
    (`WorkbenchHeaderControls`), written by `WorkbenchQueries.setArchiveAfterDays`
    (GRDB, the board-mutator path; the SQL `CHECK` bounds both languages).
    The board's fingerprint adds `archive_after_days`. v1 limit: a target that
    ages into the archive while the pane is open leaves it at the next reload
    (any board change, Refresh, reopening the pane), not at the exact minute.
11. **Skill.** The `watchtower-workbench` skill gains two lines: archived
    targets are omitted from the board; use `get_target #id` or
    `include_archived` to look one up, and reopen it to bring it back.

## 3. Inventory impact

- **PROJ-05 untouched.** Archiving writes no status; the rollup triggers and
  every `TestProj05_*` guard (including
  `TestProj05_SwiftTestSchemaMirrorsTheTriggers`) run unchanged. The Swift
  test schema is regenerated to carry the view.
- **PROJ-06 untouched.** No history row is ever written by archiving; a
  restore is an ordinary status change recorded with its writer's actor.
  `TestProj06_*`, `TestMigration00086_*`, `TestUpdateTarget_InReviewIsRecordedAsTheAgentsAndShown`,
  `testDesktopStatusWritesAreRecordedAsTheOwners` unchanged.
- **PROJ-07 untouched in wording, kept in substance** (decision 5): "the
  brief and the Desktop show every finding" now explicitly includes findings
  on archived targets. All `TestProj07_*` guards run unchanged; one new guard
  is added under PROJ-15.
- **PROJ-01, PROJ-09 untouched.** The view covers only `project_id IS NOT
  NULL` rows; re-parenting rules are unchanged.
- **New PROJ-15 (proposed, Owner decision C):** *an archived workbench target
  is hidden, never lost* — archiving writes nothing, every archived target is
  still found by id and search, reopening restores it, a group is archived
  only whole, and the drift check never skips an archived target.

## 4. Owner decisions

- **Owner decision A — the agent's board also drops recent closed work by
  default.** A board younger than N days archives nothing yet, so the archive
  alone does not bring `workbench_board` under the MCP response cap for
  about two weeks. Recommendation: `workbench_board` by default lists open
  work plus the closed targets that still have open descendants (the same
  rule as the Desktop List with Show done off); the other closed targets
  become a per-node `closed_children: k` count; `include_closed: true`
  lists them as title/status/since only (no intent). Alternative: archive
  alone, with a lower default N (e.g. 3).
- **Owner decision B — the setting's choices.** Recommendation: Never / 3 /
  7 / 14 / 30 / 90 days, default 14, Desktop only (the agent cannot change it).
- **Owner decision C — approve PROJ-15** with the wording in §3.
- **Owner decision D — restore means reopen.** Recommendation: yes, no
  separate "Unarchive" action — a target taken out of the archive but still
  done for more than N days would be archived again on the next read.

## 5. Tests

Go `internal/db` (new `proj15_board_archive_test.go`, times seeded from
`time.Now()`):
- `TestProj15_ClosedLeafArchivedAfterNDays` — N days ± 1 minute boundary;
  `done` and `dismissed`.
- `TestProj15_UmbrellaArchivedOnlyWhole` — one open grandchild keeps the
  whole chain visible; the closed siblings of open work archive alone.
- `TestProj15_GroupWaitsForItsLastClose` — old parent close, recent child
  close → not archived.
- `TestProj15_HandSetDoneParentWithOpenChildIsNotArchived`.
- `TestProj15_ReopenRestores` — status write → not archived; one history row
  with the writer's actor.
- `TestProj15_ReparentOpenWorkUnderArchivedGroupRestoresIt`.
- `TestProj15_ArchiveWritesNothing` — `targets`, `updated_at` and
  `target_status_history` unchanged across board reads.
- `TestProj15_PerWorkbenchSettingAndNever` — two workbenches, different N;
  0 archives nothing; out-of-range values refused by the CHECK.
- `TestProj15_CloseTimeFallsBackToUpdatedAt`.
- `TestWithoutArchived_CountsArchivedChildren`.
- `TestMigration00102_DefaultsToFourteen`; `TestSchemaGolden` /
  `TestDesktopTestSchema` regenerated; a 2000-target fixture reads the board
  within a stated bound.

Go `internal/tools`, `cmd`:
- `workbench_board` omits archived subtrees, reports `archived_children` and
  `archived`, `include_archived` returns them; decision A's default and
  `include_closed`; a size test: a 300-target fixture with 280 closed
  answers under 40k characters by default.
- `list_targets` in a session with/without `include_archived`; `get_target`
  finds an archived target and says so; `update_target` reopens one.
- `workbench_info` counts.
- Brief: archived targets absent, header `K archived`.
- `TestProj15_DriftStillSeesArchivedUnmergedWork` — N = 3, a target done
  5 days ago on an unmerged branch → `done_but_unmerged` in `workbench check`
  and in the brief.
- `workbench board --archived`, `workbench show`.

Swift (`Tests/Core` where possible):
- `WorkbenchBoardOutlineTests` — archived hidden with `showArchived` off,
  shown with it on, search always matches archived.
- `WorkbenchBoardKanbanTests` — archived leaves only with the toggle, Done
  uncapped for them.
- `WorkbenchQueries` board fills `archived` from the view; the card counter
  counts archived children; `setArchiveAfterDays` writes and the CHECK
  refuses out-of-range.
- `WorkbenchBoardViewModelTests` — restore via `setStatus(_:for:)` brings the
  target back after reload; fingerprint changes with the setting.

## 6. Tasks

| Task | Scope | Depends on |
| --- | --- | --- |
| G1 | Migration 00102 (column + view), `schema.sql`, golden + Swift test schema regen; `Workbench.ArchiveAfterDays`, `BoardNode.Archived`/`ArchivedChildren`, `db.WithoutArchived`, `db.SetWorkbenchArchiveDays(projectID int64, days int) error`, `TargetFilter.IncludeArchived`; the `internal/db` tests | none |
| G2 | `workbench_board` (+ decision A), `workbench_info`, `list_targets`, `get_target`; brief; `workbench board`/`show`; caller audit (decision 8); drift guard; tools/cmd tests | G1 |
| G3 | `docs/features/workbench.md`, `docs/inventory/workbench.md` PROJ-15 (pending approval) + changelog, skill lines, `docs/app-guide.md` | G2, S2 |
| S1 | `WorkbenchBoardNode.archived` from `WorkbenchQueries.board`; `showArchived` in `WorkbenchBoardOutline.rows`/`WorkbenchBoardKanban`; `WorkbenchQueries.setArchiveAfterDays`; Core tests | G1 |
| S2 | Archive (K) toggle, archived styling, header menu setting, VM `showArchived`, fingerprint; VM tests | S1 |

G2 and S1 can run in parallel after G1 (separate worktrees); S2 is the only
heavy Swift build.
