# Workbench board — Archive Closed Targets Now (board #415, 2026-10-07)

Status: approved by the owner on 2026-10-07 (ask #106) — all four §1
decisions as recommended, and the §3 PROJ-15 amendment. Amends the board
archive spec `2026-10-04-workbench-board-archive-design.md` (#301, PROJ-15).
Migration number: 00105 (00104 is the code-question orphans migration).

## 1. For the owner (one page)

**What the button does.** The workbench header "…" menu gets **Archive Closed
Targets Now**, next to **Archive Closed Targets After ▸**. One click archives
every closed target on this board *right now*, instead of waiting the 14 (or N)
days. The board gets short at once; nothing is deleted.

**What you see.**
- The closed targets disappear from the List, the Kanban, the agent's
  `workbench_board` and the session brief — exactly like targets the age rule
  archived. **Archive (K)** in the toolbar shows them again, dimmed; search
  and `get_target #id` still find them.
- Groups still go whole: a group with anything open under it stays on the
  board, and so do its closed sub-tasks' group counters (7/12 stays 7/12). The
  closed sub-tasks themselves are archived.
- The click remembers *a moment*, not a list of targets. Work closed after the
  click stays on the board and leaves later by the usual N-day rule (or the
  next click).
- Reopening an archived target still brings it back at once (status menu,
  Kanban drag, the agent's `update_target`).
- Unmerged work is still never hidden: the drift check sees archived targets.

**How to undo.** Recommended: a second item, **Undo Archive Now**, shown while
the moment is set. It forgets the moment: everything the button archived comes
back, except targets that the N-day rule would archive anyway. Nothing about
the targets themselves changes, so undo is exact.

**Decisions for you (each with my recommendation):**

1. **Does the button work when the setting is "Never"?** — *Recommend: yes.*
   "Never" means "never by itself"; pressing the button is an explicit request.
   With "Never" the button becomes the only way to archive, which is a useful
   mode on its own ("I'll tidy up when I want to").
2. **Ask "Archive N targets?" before doing it?** — *Recommend: no dialog.*
   Nothing is deleted, the result is visible at once, and Undo (decision 3)
   reverts it exactly. This matches the "Archive Closed Targets After" setting,
   which also applies at once without asking.
3. **Undo — needed?** — *Recommend: yes, "Undo Archive Now".* It is one
   database write. Without it, a mis-click can only be reverted by reopening
   targets one by one, which changes their statuses and status history.
   Undo forgets every earlier click too (there is one remembered moment per
   workbench, not a stack).
4. **Only `done`, or `done` and `dismissed`?** You asked for "done". —
   *Recommend: both (all closed targets),* hence "Closed" in the label, the
   same word as the existing setting. The archive already treats both as
   closed; a dismissed target is the clutter you least want to keep; and a
   group whose children are part done, part dismissed could otherwise never be
   archived by the button (groups go whole).

## 2. Technical decisions

1. **Storage: one nullable stamp per workbench, not a per-target flag.**
   Migration `00105` adds `projects.archived_through TEXT NULL CHECK
   (archived_through IS NULL OR julianday(archived_through) IS NOT NULL)` —
   a UTC timestamp `YYYY-MM-DDTHH:MM:SSZ`, NULL = never pressed. *Why:* it
   keeps every #301 property by construction — archiving writes nothing per
   target, reopening restores, the rule lives in one SQLite view read by Go
   and Swift. A per-target `archived_at` column was rejected in #301 for the
   same reasons (writer, un-archive on every reopen path, sweeps). The stamp
   is written only by SQL `strftime('%Y-%m-%dT%H:%M:%SZ','now')` in both
   languages (never a client clock string), the same format and second
   precision as `target_status_history.changed_at`.
2. **The rule (the view, recreated by 00105).** A workbench target is
   archived iff it and every descendant on the same board are
   `done`|`dismissed`, every close time among them parses, and
   **either** (a) `archive_after_days > 0` and the newest close time is more
   than `archive_after_days` days old (the #301 age rule, unchanged), **or**
   (b) `archived_through` is set and the newest close time is
   `<= archived_through`. Close time is unchanged from #301 (latest
   `target_status_history.changed_at`, else `updated_at`). Comparisons go
   through `julianday()`, never string order. The `archive_after_days > 0`
   gate moves inside branch (a) — that is what makes decision 1 "yes"; if the
   owner says "no", it stays outside both branches. Consequences, all by
   construction: groups go whole for (b) too; a target closed after the click
   (newest close > stamp) stays until (a) takes it; reopen-and-reclose after
   the click restarts the period (new history row > stamp); a `done` →
   `dismissed` change after the click is a new close time and brings the
   target back until (a) or the next click.
   The view keeps its columns `(target_id, project_id, archived)`; no
   "archived because" column in v1.
3. **Decision 4 is the existing definition of closed.** No status filter is
   added for the button; if the owner picks "done only", branch (b) gets
   `AND every status in the subtree = 'done'` (a group with a dismissed child
   then never archives by the button) — recommended against.
4. **Writers (dual path, same SQL).**
   - Go (`internal/db/workbenches.go`), for tests and tooling, like
     `SetWorkbenchArchiveDays`:
     - `func (db *DB) ArchiveWorkbenchClosedNow(projectID int64) error` —
       `archived_through = now`, `updated_at = now`.
     - `func (db *DB) ClearWorkbenchArchivedThrough(projectID int64) error` —
       `archived_through = NULL`, `updated_at = now`.
     Both return `ErrWorkbenchNotFound` (via `requireAffected`) for an
     unknown id.
   - Swift (`WorkbenchQueries`, WatchtowerCore) — the only production writer:
     - `package static func archiveClosedTargetsNow(_ db: Database, projectID: Int64) throws`
     - `package static func clearArchivedThrough(_ db: Database, projectID: Int64) throws`
     Both throw `WorkbenchQueryError.workbenchNotFound` when nothing changed.
     Doc comments name each other as the dual path.
5. **Models.** Go `Workbench.ArchivedThrough string` (`""` = not set; scanned
   through `sql.NullString`), `archived_through` added to `workbenchCols`.
   Swift `Workbench.archivedThrough: String?` from `row["archived_through"]`.
6. **Desktop.** `WorkbenchHeaderControls` gets, beside `archiveMenu`:
   **Archive Closed Targets Now** (always enabled in v1) and, when
   `project.archivedThrough != nil`, **Undo Archive Now**. Both call new
   `WorkbenchesViewModel` methods
   `archiveClosedTargetsNow(projectID: Int64) async` and
   `undoArchiveNow(projectID: Int64) async`, which write via `dbPool.write`,
   report failures in the existing `archiveSettingErrors[projectID]`
   ("Could not archive closed targets: …" / "Could not undo Archive Now: …"),
   and `reload()` on success — the same shape as `setArchiveAfterDays`.
   `WorkbenchBoardViewModel.fingerprint` reads `archive_after_days,
   archived_through` from `projects`, so the open board reloads at once.
   No confirmation dialog (decision 2, if approved).
7. **Go readers: no code change.** `GetWorkbenchBoard`,
   `IsWorkbenchTargetArchived`, `GetTargets` in a workbench session, the
   brief, `workbench_board`, `workbench_info`, `list_targets`, `get_target`
   all read the view, so they follow the stamp for free. The drift check and
   `internal/sessionreport` keep reading the full board (#301 decisions 5, 8).
8. **CLI / MCP parity.** `workbench show` prints `Archived through: <ts>` when
   the stamp is set (nothing when not), and `workbench show --json` carries
   `archived_through` (omitted when empty) — cheap and read-only. **No CLI
   writer and no MCP tool:** like `archive_after_days` (#301 owner decision B,
   "Desktop only, the agent cannot change it"), the stamp is the owner's
   action; the agent must not tidy the owner's board away. `update_workbench`
   does not gain it; the skill text is unchanged.

## 3. Inventory impact — PROJ-15 amendment (needs owner approval)

PROJ-15's **Observable** changes in one sentence; the guarantees ("hidden,
never lost") are unchanged. Proposed replacement of its first sentence:

> A workbench target is archived iff it and every descendant on the same
> board are `done` or `dismissed`, every close time among them parses, and
> either its workbench's `projects.archive_after_days` (migration `00103`,
> default 14, `CHECK` 0..365, 0 = never) is above 0 and the newest close time
> among them (a target's latest `target_status_history.changed_at`, else its
> `updated_at`) is more than `archive_after_days` days old, or the
> workbench's `projects.archived_through` (migration `00105`, set by the
> Desktop's "Archive Closed Targets Now", cleared by "Undo Archive Now") is
> set and that newest close time is not after it.

Plus, after "Reopening restores it: …": "A target closed or reopened after
`archived_through` is judged by the age rule alone until the next Archive
Now." Status line gains "amended 2026-10-07 (board #415)". "Why locked" is
unchanged — restore is still reopening; Undo is an extra, not the only way
back.

Existing guards are not weakened: `TestProj15_PerWorkbenchSettingAndNever`
keeps asserting that 0 archives nothing *with no stamp*; every other
`TestProj15_*` runs with the stamp NULL and is unchanged. New guards are
added (§4). PROJ-05/06/07/09 untouched: the button writes only `projects`.

## 4. Tests

Go `internal/db` (`proj15_archive_now_test.go`; times seeded from
`time.Now()`, the stamp from `ArchiveWorkbenchClosedNow`):
- `TestProj15_ArchiveNowArchivesEveryClosedSubtree` — `done` and `dismissed`
  leaves closed minutes ago are archived after the call, open ones are not;
  N = 14 throughout.
- `TestProj15_ArchiveNowGroupsGoWhole` — a group with one open grandchild
  stays with its open chain; its closed siblings archive alone; a fully closed
  group archives whole.
- `TestProj15_ArchiveNowCloseAfterTheStampStays` — close a target, stamp,
  close another (history `changed_at` seeded one second after the stamp) →
  the second is not archived; with its close aged past N it is.
- `TestProj15_ArchiveNowLaterCloseInAGroupKeepsTheGroup` — a group archived by
  the stamp whose child is reopened and closed again after it → the whole
  group is back.
- `TestProj15_ArchiveNowReopenRestores` — status write after the stamp → not
  archived; one history row with the writer's actor.
- `TestProj15_ArchiveNowSameSecondIsArchived` — close time equal to the stamp
  is archived (`<=`).
- `TestProj15_ArchiveNowUnderNever` — N = 0: no stamp archives nothing (the
  existing guard), stamp archives the closed subtrees (decision 1 "yes").
- `TestProj15_ArchiveNowUnparseableCloseTimeKeepsTheChain` — a garbage
  `updated_at` on a history-less closed target keeps it and its ancestors on
  the board with the stamp set.
- `TestProj15_ArchivedThroughMustParse` — writing `'not a date'` to
  `archived_through` is refused by the CHECK.
- `TestProj15_UndoArchiveNowRestoresOnlyWhatTheAgeRuleWouldNot` — stamp,
  clear → recent closes back, a close older than N still archived.
- `TestProj15_ArchiveNowWritesNothingPerTarget` — `targets`, `updated_at`
  and `target_status_history` unchanged across the call and board reads.
- `TestProj15_ArchiveNowIsPerWorkbench` — a stamp on one workbench archives
  nothing on another.
- `TestMigration00105_ArchivedThroughStartsNull`; `TestSchemaGolden` /
  `TestDesktopTestSchema` regenerated; `TestProj15_LargeBoardReadIsFast`
  re-run with a stamp set.
- Unknown id → `ErrWorkbenchNotFound` for both writers.

Go `cmd`, `internal/tools`:
- `TestWorkbenchShowCmd_PrintsArchivedThrough` (text and `--json`, set and
  unset).
- `TestWorkbenchBoard_ArchiveNowLeavesTheBoardSmall` — after the stamp,
  `workbench_board` lists only open work and reports `archived: K`.
- `TestProj15_DriftStillSeesArchivedUnmergedWork` gains a stamp-only case
  (N = 14, closed an hour ago, stamped, branch unmerged → still reported).

Swift (`Tests/Core` where possible):
- `WorkbenchQueriesTests` — `archiveClosedTargetsNow` sets the stamp and the
  board marks recent closed targets archived; `clearArchivedThrough` brings
  them back; unknown project throws `workbenchNotFound`; `Workbench` decodes
  `archivedThrough` (nil and set).
- `WorkbenchBoardViewModelTests` — the fingerprint changes with the stamp; a
  board open in the pane drops the targets after the call without a manual
  refresh.
- `WorkbenchesViewModel` — a failed write fills `archiveSettingErrors` and
  skips the reload.

## 5. v1 limits

- The menu item is always enabled, even when nothing is closed (the header
  does not load the board); pressing it then only sets the stamp.
- A target closed by anyone in the same second as the click, after it, is
  archived with the rest (second precision, `<=`).
- One remembered moment per workbench: Undo forgets every earlier click, not
  just the last one.
- A history-less closed target (older than migration 00086) uses `updated_at`
  as its close time, so a later edit of it (e.g. a rename) brings it back
  until the age rule takes it — the same limit as #301.
- No "archived by: age | Archive Now" distinction anywhere in the UI or the
  agent's answers.

## 6. Tasks

| Task | Scope | Depends on |
| --- | --- | --- |
| G1 | Migration 00105 (column + CHECK, view drop/recreate; Down restores the 00103 view and drops the column), `schema.sql`, golden + Swift test schema regen; `Workbench.ArchivedThrough`, `ArchiveWorkbenchClosedNow`, `ClearWorkbenchArchivedThrough`; `workbench show` line + JSON; `internal/db` and `cmd` tests | none |
| S1 | `Workbench.archivedThrough`, `WorkbenchQueries.archiveClosedTargetsNow` / `clearArchivedThrough`; Core tests | G1 |
| S2 | Header menu items, `WorkbenchesViewModel.archiveClosedTargetsNow` / `undoArchiveNow`, fingerprint; VM tests | S1 |
| D1 | `docs/features/workbench.md` board-archive bullet, `docs/inventory/workbench.md` PROJ-15 amendment (after approval) + changelog, `docs/app-guide.md` | G1, S2 |

S1 can start as soon as G1's migration lands (it needs only the regenerated
test schema); S1+S2 are one Swift lane.
