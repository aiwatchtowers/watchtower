# Clean Up Old Worktrees — a screen instead of a sheet (board #1107) — design

**Status:** draft for the owner's review
**Builds on:** `docs/superpowers/specs/2026-10-12-session-cleanup-design.md` (board #535) §8, §9, §12; PROJ-18 in
`docs/inventory/workbench.md`.

## 1. Why

On the owner's own repository the **Clean Up Old Worktrees…** sheet (`WorkbenchSweepSheet`) cannot be used:

- **No bulk choice.** A measured sweep of the workbench repository (2026-10-26) lists 69 worktrees and 130 branches;
  53 worktrees (~294 GB) and 111 branches can go. The sheet offers one checkbox per row and nothing else — no select
  all, no filter, no sort.
- **Modal and slow.** The sheet shows nothing until the whole plan is ready: 18 s without sizes, 42 s with them on
  that repository (`internal/sessioncleanup`: per-worktree `git status`, the W9 nested walk, then a `du`-like walk of
  every removable worktree, 4 at a time, 20 s budget each). While it plans, the owner is locked out of the app's
  window.
- **Noise.** Kept rows ("Kept — unpushed commits") are mixed into the list; every row says "Owner unknown" (5 of 199
  items had a known owner), so the column tells nothing.

Done means: the owner opens the screen, sees the list within a second or two, sorts by size, selects everything
that can go (or everything merged / older than a month) in one or two clicks, confirms once, and keeps using the app
while it is removed.

## 2. Goals, non-goals, anti-goals

**Goals**
- A non-modal screen in the workbench window; the owner can leave it and come back while it plans or removes.
- Rows appear as soon as git has listed them; checks and sizes fill in as they finish.
- Bulk selection: everything shown that can go, a shift/⌘ range, ⌘A.
- Sort by size, age, name; filter by kind, age and "merged into the default branch"; search by name.
- A worktree and its branch are one row and go together.
- Kept items out of the way, grouped by why they are kept.
- Removal in the background with per-row progress and a one-line result ("Freed ~140 GB; kept 2 — git refused").

**Non-goals**
- No change to any safety catch (PROJ-18, design §5). The screen only changes how the owner picks among items the
  CLI already marks `remove`; the apply still re-plans and re-checks every item.
- The session row's **Clean Up…** sheet and **Delete and Clean Up** stay as they are (one session, few items).
- No size cache on disk; no background sweep the owner did not start (the one-time hint stays as it is).

**Anti-goals** — a failure even if it works:
- Anything removed the owner did not see selected. Selecting is the owner's act; the screen never pre-selects.
- A screen that again shows nothing until everything is checked.
- More settings or a wizard. One screen, one confirmation.

## 3. Where it lives

**Builder's call, recorded here:** a workspace pane kind like Analytics (`WorkspacePaneView`), titled **Clean Up**,
opened by the ⋯ menu's **Clean Up Old Worktrees…** and by the one-time hint's button. It sits in the workspace area
(can be split beside a terminal), shows in the title-row crumbs, and closes like any pane. Leaving the pane or
switching workbench does not stop a plan or an apply: the plan already lives in `SessionCleanupCenter` (scope
`.workbench(id)`) and the apply in `WorkbenchesViewModel.sweepRuns`; the screen re-reads them when shown. The sheet
`WorkbenchSweepSheet` is removed.

**Builder's call:** the Clean Up pane kind is not saved in `WorkspaceLayout` — after a relaunch or a layout restore
it is gone, so no sweep ever starts without the owner opening the screen. Opening it plans, unless a ready plan
younger than `sweepPlanReuseWindow` (10 min) or a running one exists. Closing the pane keeps the plan and its rows in
the center (reused within the window, as the sheet's are today); the existing `cleanupHintTimeLimit` watchdog stays
as the plan's stop.

## 4. Screen

```
┌ Clean Up — watchtower ─────────────────────────────────────────────────────────────────┐
│ Checking 23 of 69 worktrees…  ▓▓▓▓▓░░░░░            [Refresh]                         │
│ [🔍 Search      ] [All ▾ Worktrees | Branches]  [Any age ▾]  [☐ Merged only]           │
├────┬──────────────────────────────────────┬─────────┬─────────────┬──────────────────────┤
│    │ Name                                  │ Size ▼  │ Last commit │ State                │
├────┼──────────────────────────────────────┼─────────┼─────────────┼──────────────────────┤
│ ✓  │ 595-mac            wt/595-mac         │ ~12 GB  │ 9 days ago  │ Merged               │
│ ✓  │ agent-a3eb667f…    feature/604-files… │ ~12 GB  │ 2 days ago  │ Pushed               │
│    │ 712-linear-ai-13…  wt/712-linear-…    │ ~12 GB  │ 6 days ago  │ Merged               │
│    │ agent-a4e21905…    lane/718-t5-b      │ ~97 MB  │ 1 day ago   │ Merged               │
│    │ agent-a550cee6…    lane/718-t5-d1     │ measuring│ 1 day ago  │ Merged               │
│    │ feature/old-thing  (branch only)      │   —     │ 2 months ago│ Merged               │
│    │ 801-builtins       wt/801-builtins    │ checking…│            │                      │
│ ▸ Kept (35): 19 unpushed commits · 8 recent sessions · 3 in use · …                    │
├────┴──────────────────────────────────────┴─────────┴─────────────┴──────────────────────┤
│ [Select All That Can Go]  [Clear]       2 worktrees, 2 branches · ~24 GB  [Clean Up…] │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Table** (SwiftUI `Table`, native multi-selection). The selection *is* the choice: click, ⇧-click range, ⌘-click,
  ⌘A (selects every selectable row shown). Only rows that can go are selectable; a row still being checked is shown
  but not selectable until its check lands.
- **Columns:** Name (worktree folder name, branch in secondary text; a branch with no worktree shows its name and
  "branch only"), Size (`~12 GB` / `measuring…` / `checking…` / `size unknown` / `—` for a branch), Last commit
  (relative, from the tip's committer date), State (`Merged` = tip is an ancestor of the default branch; `Pushed` =
  contained in a remote ref only). Owner shows only when known: a session title under the name, no "Owner unknown"
  column. Default sort: Size descending, unmeasured rows last.
- **Worktree + branch = one row.** A worktree row carries its branch: selecting it removes the worktree and, when
  that branch's item is `remove`, the branch too (both keys go to `--item`). When the branch is kept (checked out
  elsewhere, unpushed), the row says so in its State ("branch kept — unpushed commits") and only the worktree goes.
  Branch-only rows are the branches with no worktree. The same goes for the worktree's `lsreg:` items (LaunchServices
  entries of `.app` bundles inside it): they are part of the worktree row and go with it — otherwise removing the
  folder would leave entries pointing at a deleted app. Only the sweep's stale-entry `lsreg` items (registered paths
  under the workbench folder that no longer exist) are rows of their own.
- **Filters** (toolbar, none saved): kind (All / Worktrees / Branches only), age (Any / older than 7 / 30 / 90 days,
  by last commit), Merged only, a name search. **Select All That Can Go** selects every selectable row the filters
  show — so "older than 30 days" + "Merged only" + one click is the common case.
- **Kept** rows sit in one folded group at the bottom: the header counts them by reason; unfolded they are plain
  rows with the reason in words (`SessionCleanupPresentation`), not selectable. Stale-entry `lsreg` items are
  ordinary selectable rows named "LaunchServices entry".
- **Progress line** at the top while planning: "Listing worktrees…", "Checking N of M worktrees…", "Measuring sizes
  N of M…", then "Checked 2 min ago" with **Refresh**. A ready plan younger than 10 minutes is reused when the
  screen opens (`sweepPlanReuseWindow`, unchanged).
- **Footer:** the total of the selection (`2 worktrees, 2 branches · ~24 GB`, "some sizes unknown" when so),
  **Clean Up…** (disabled with nothing selected).

## 5. Confirming and removing

- **Clean Up…** asks once: "Remove 12 worktrees and 15 branches (~140 GB)? Uncommitted or unpushed work is never
  removed; anything that changed since the check is kept." Buttons **Remove** (destructive) / Cancel.
- The apply runs in the background (`sweepRuns`, as today). Each row shows a spinner while its turn comes, then
  leaves the list when removed; a row kept at apply time (re-check, git refused) stays with its new reason and an
  orange mark. Plan rows not selected are untouched and stay.
- When it ends, a result line replaces the progress line: "Freed ~140 GB · kept 2 — git refused, changed since the
  check" (from the CLI's `summary` / `removed_bytes`), dismissible. A failure of the whole run shows the same way, in
  red, with **Retry** for the rows still selected.
- While an apply runs, **Refresh** and **Clean Up…** are disabled; selection of other rows stays possible but not
  applicable.

## 6. CLI: a streamed plan and apply

The sweep stays `watchtower workbench cleanup --workbench N --sweep [--apply --item KEY…]`. New flag **`--stream`**
(only with `--json`): JSON lines on stdout, one event each, so the Desktop can show rows before the plan is done.
Without `--stream` the output is unchanged (agents, tests, the session sheet).

```
{"event":"listed","items":[ …items as in §4.1, with "state":"checking" … ]}      // after git worktree list + for-each-ref
{"event":"checked","item":{ …the item with its action/reason… }}                  // one per item, as its catches finish
{"event":"sized","key":"worktree:/…","bytes":11811160064,"bytes_known":true}      // one per measured worktree
{"event":"removing","key":"…"}  {"event":"removed","item":{…done:true…}}         // --apply only, in removal order
{"event":"done","plan":{ …the full §4.1 object, unchanged… }}                      // always last on success
```

- `listed` comes from the cheap git listing only (worktree list, branch list, default branch); its items carry the
  new keys below and `action` absent. A failure before `listed` is the old exit-1 path; the Desktop treats a stream
  that ends without `done` as a failed plan (rows stay as they were, with the error line).
- A worktree's bundle items (`lsreg:` found under it) carry `"worktree":"<root>"` and are emitted with that
  worktree's `checked` event, before sizing (the bundle scan moves ahead of `measureAll` in the sweep), so a worktree
  row is complete — and selectable — once checked. Stale-entry `lsreg` items carry no `worktree`.
- Item gains two keys, in streamed and non-streamed output alike (additive, pinned in the JSON key test):
  `last_commit_at` (RFC 3339 UTC of the tip's committer date; `""` when unknown) and `merged` (bool: tip is an
  ancestor of the local default branch or of its remote counterpart — `refs/remotes/origin/<default>` when it exists
  — so a branch merged on GitHub while the local `main` lags still reads as merged; false when unknown; builder's
  call). Both come from one `git for-each-ref` over `refs/heads` plus
  one per detached worktree HEAD.
- Checks may finish in any order; the Desktop applies events by `key`. `done.plan` is the authority: the Desktop
  replaces its rows with it.
- Apply events are new only in that the CLI reports per item as it goes; the apply's logic, order and re-checks
  (design §7) are unchanged.

**Builder's call:** the order of work inside the plan does not change except that the listing is emitted first and
each item's `checked` event is written as soon as its catches are done; sizes still run after the checks, only for
`remove` worktrees. Where the 18 s goes (git status vs the W9 walk vs lsof) is measured in plan Task 0; a cheap
speed-up found there (e.g. running the per-worktree checks in parallel, as sizes already are) is in scope, a deeper
one is not.

## 7. Desktop internals

- `SessionCleanupCenter` gains a streamed sweep plan: it keeps, per workbench, the rows received so far plus the
  stage (listing / checking N of M / sizing N of M / ready / failed) and the plan's time. The existing
  `SessionCleanupPhase` stays for the session scope; the sweep phase gets the partial rows. The center still never
  runs git itself.
- Row model and the worktree+branch pairing, filters, sort, "selectable", the selection total and the confirmation
  text are pure WatchtowerCore code (`SweepScreenModel` or similar), tested in `Tests/Core`.
- The apply passes exactly the keys of the selected rows — for a worktree row its own key, its branch's key when
  that branch item is `remove`, and its bundles' `lsreg:` keys — of known kinds only — the existing `removableItems(among:)` rule.
- The one-time hint's button opens the pane instead of the sheet.

## 8. Contracts

No contract is weakened. PROJ-18 says "the sweep ticks nothing by itself" and "apply exactly the ticked keys of a
known kind" — both hold: selection is the owner's click or ⌘A, and the apply sends exactly the selected rows' keys,
with a worktree's own branch (when that branch item is `remove`) and its own bundles' entries.

**Needs the owner's approval — a guard test changes.** The pairing is new behaviour, and the PROJ-18 guard
`testSweepAppliesOnlyTickedKeys` (`WatchtowerDesktop/Tests/SessionCleanupSweepTests.swift`) asserts the opposite:
ticking a worktree whose branch is also removable sends only the worktree's key. With approval, PROJ-18 gets an
amendment ("in the sweep screen a worktree row is the worktree, its branch when removable and its bundles' entries;
the apply sends exactly the selected rows' keys so expanded") and that test is rewritten for it — keeping its
assertions on unknown kinds, kept items and stray keys, adding one for the pairing. Without approval, the row shows
the branch as its own checkbox inside the row, unticked. The other sweep guards (`testSweepTicksNothingByDefault`,
`testSweepNeverAppliesUnknownKinds`, `testSweepSurvivesLeavingThePage`, …) move to the screen with their assertions
unchanged. The `--json` output gains two
keys (additive); `--stream` is new.

## 9. Guide

`docs/guide/` page on cleaning up worktrees is updated for the screen (where it opens, select all, filters).

## 10. Left to the builder

- Exact SwiftUI `Table` column widths, icons, the colour of the progress bar — the design kit and
  `docs/design/desktop-style-guide.md` decide.
- Whether rows that leave after removal fade or vanish.
- Event decoding details and how the center coalesces many `checked` events into view updates (no more than a few
  redraws per second).

## Decisions

- Make it a screen, not a popup; it must not block the owner while it plans — conversation (owner, 2026-10-26).
- The points proposed in the conversation (non-modal screen; list first, sizes later; bulk selection; sortable
  table; kept items folded; background removal with progress) are accepted as they are — ask #628.
- Nothing pre-selected stays; a single "select all that can go" click is the bulk path — conversation proposal,
  accepted in ask #628.
