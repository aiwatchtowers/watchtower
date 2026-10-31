# Session row progress shows the session's own work

**Board:** #1352 · **Backlog finding:** `docs/backlog/2026-10-31-session-row-progress-counts-every-touched-target.md`
**Status:** draft for owner review

## Intent

The workbench session row shows a progress bar and `done/total` (e.g. `42/72`)
from the session report (`internal/sessionreport`). Today the count is the
session's own target subtree **plus every target its agent ever wrote to**
(`terminal_session_targets`, written by `update_target`, `create_targets`,
`add_comment`, `ask_owner`, `finish_session`), with the subtrees of linked
parents. A link is never removed. A long session that first worked one group
(now driven by another session) and then another group shows the union — the
owner's live case: `42/72` where the session's actual current phase is `30/33`.

The owner wants the bar to show the real state of **this session's own work**.

## Goals

1. Targets another session has since taken over leave this session's count
   automatically, with no owner action and no agent action.
2. A session can be pointed at one target (a group or a task) at any time after
   launch, by its agent or by the owner; then only that subtree counts.
3. Existing sessions are fixed on upgrade, without a backfill job.

## Non-goals

- No change to the row's look, the report screen layout, or the phone's
  screens. Only the numbers they show change.
- No change to which writes create a link (PROJ-14's link list stays).
- No "+N outside the target" marker (owner, ask #846).
- No ownership for the owner's own board moves (owner, ask #846).

## Anti-goals

- An unbound session's count must never drop its own fresh work (a target it
  created or just moved). A bound session drops work outside its target on
  purpose (owner, ask #846).
- No new screen or sheet for binding: a submenu on the existing row menu.

## Behaviour

### Rule (option C, owner ask #844)

The report's **progress scope** of session S:

1. **S has a session target** (`terminal_sessions.target_id`, set at launch or
   by the new binding): the scope is that target's subtree only. Other linked
   targets stay in the report's lists (`targets`, timeline) but not in
   `progress`. No ownership exclusion here: a bound group shows the whole
   group's progress, whoever moved its leaves. If the bound target is not on
   the board (archived, or deleted — the FK is `ON DELETE SET NULL`), S falls
   back to rule 2.
2. **S has no session target**: the scope is today's — linked targets plus the
   subtrees of linked targets that have children — **minus every leaf owned
   by another session**.

**Ownership** is decided for **leaves only** (progress counts leaves). The
owner of a leaf is the session with the latest
*status stamp* for it among all agent sessions of the workbench. A session's
status stamp for a target is:

- `status_at` on its link row, set when that session's write **changed the
  leaf's status** (an `update_target` with a new `status`, or a `column` move
  that changes the status), **created** it (`create_targets`), or **bound the
  session to a target whose subtree holds it** (`set_session_target`, see
  below);
- a link row with `status_at` NULL (a comment or ask only) gives no ownership.

**Old rows.** The migration sets `status_at = last_at` on every existing row
once. Before this change there is no record of which write was a status
change, so for old links the last write of any kind stands in; this is what
fixes the owner's live session on upgrade. From the upgrade on, a comment
never takes a leaf. This is a one-time approximation, recorded as an agent
decision.

A leaf has no owner when no session stamped it; it then counts for every
session whose scope reaches it, as today. Moving a **group** gives no
ownership of its leaves: another session setting a group `in_progress` takes
nothing from S.

Owner moves on the Board (actor `owner`) write no link
and so never change ownership (ask #846).

Ties (equal stamps, second resolution) go to the higher session id.

### Binding a session to a target (owner ask #844, option B part)

**Writers of `terminal_sessions.target_id`:** the Desktop writes it once, in
the row's INSERT at launch (unchanged). After launch only Go re-writes it,
through the two entry points below; the Desktop never UPDATEs it.

- **MCP tool `set_session_target`** on the workbench surface (DEV-06: nineteen
  → twenty tools; skill pack bump). Args: `target_id` (a target of this
  workbench; `0` clears), `reason`. Resolves the calling session exactly like
  `finish_session` (`terminalSessionOf`; no session → refused with
  `set_session_target needs a Watchtower terminal session`, before any row or
  audit row). Applied directly and audited like the other workbench writes.
  When non-zero it links the target and **stamps every leaf of its subtree**
  for the session (`status_at = now`), so the bound session takes those leaves
  from other unbound sessions at once (otherwise re-pointing would not move
  the numbers until the new session changes a status). The `target_id` write
  and the leaf stamps are **one write transaction** (`BEGIN IMMEDIATE`, no
  reads of the board inside it beyond the subtree ids, collected first): a
  failure rolls back both and the tool fails like any write (the registry's
  `failed` audit row), unlike the best-effort `linkSession` of the other
  tools. The CLI uses the same db function. Refused with a clear
  error when the target is not on the board (archived) or is `dismissed`:
  rule 1 would fall straight back to rule 2 and the call would look like a
  no-op. A `done` target may be bound (it shows N/N).
- **CLI `watchtower workbench session-target --session N (--target M | --clear) [--json]`**:
  same validation; refused under an agent marker (owner verb, like `coach
  accept`). The Desktop calls it.
- **Desktop**: the session row's context menu gets **Session Target ▸**, a
  submenu built from the same outline as the board's **Move to…**
  (`WorkbenchBoardOutline`, archived and dismissed targets left out), plus
  **None — Count What It Touched** at the top and a checkmark on the current
  one. After the CLI returns, the report refreshes (the existing
  session-report refresh). Sketch (native menu, between **Rename…** and
  **Clean Up…**):

  ```
  Rename…
  Session Target          ▸ │ ✓ None — Count What It Touched
  Clean Up…                 │ ─────────────────────────────
  …                         │   Фаза 1: Go-хаб           ▸ │ ✓ Фаза 1: Go-хаб (whole group)
                            │   Релей                    ▸ │   Задача 1.1 …
                            │   Монетизация                │   …
  ```

  A group is chosen with its own first item, as in **Move to…**.
- The workbench skill tells the agent: when the work of the session moves to a
  new group, call `set_session_target` with that group.

**Side effect on `finish_session`** (owner approved, ask #850):
the finish gate's "ticket" is `terminal_sessions.target_id`, so re-binding also
changes which subtree must be closed before `finish_session` passes.

## Data

Migration `00167_session_target_status_at.sql (next free number at implementation time)`:

```sql
-- +goose Up
ALTER TABLE terminal_session_targets ADD COLUMN status_at TEXT;
UPDATE terminal_session_targets SET status_at = last_at;
-- +goose Down
ALTER TABLE terminal_session_targets DROP COLUMN status_at;
```

Mirror in `schema.sql`, regenerate the golden snapshot and the Swift test
schema. The one-line backfill above is the whole upgrade.

`db.LinkSessionTarget(sessionID, targetID)` gains a sibling
`LinkSessionTargetStatus(sessionID, targetID)` that sets `status_at = last_at =
now`. `linkSession` takes a flag. `update_target`'s `Execute` does not have
the old status today (`t` is read in `Scope`), so `applyTargetUpdate` returns
whether it wrote a status (the plain `status` path and the column path) and
`Execute` passes that; `create_targets` passes the flag for every created
target.

`db.SessionTargetOwners(workbenchID) map[targetID]sessionID` computes
ownership in one query (window over `terminal_session_targets` joined to
`terminal_sessions` of the workbench and of kinds `claude`/`codex`).

## Report

`newScope` gets the owners map and the session id. `progress()` uses the
narrowed scope; `targets()` (the report's lists) keeps today's wider scope so
the report still says what the session touched. `Summaries` loads the owners
map once per workbench.

The Desktop row and the phone read `progress` from the report JSON
unchanged — no Swift change for the count.

## Contracts

- **PROJ-14 amended**: the progress scope rule above; the Desktop's launch
  INSERT as the only Desktop write of `terminal_sessions.target_id`,
  `set_session_target` and the CLI as its only re-writers after launch, which also re-points the finish gates' ticket (ask #850); `status_at` written only by the status-changing / creating writes.
  Guard tests renamed in place only if their wording changes; none relaxed.
- **DEV-06**: twenty tools; the vocabulary test's count bumps.

## UI text (model-owned, tested)

In a WatchtowerCore presentation type, covered by a test:

- menu title `Session Target`
- top item `None — Count What It Touched`
- failure line (the CLI's error) `Couldn't change the session target: <error>`

No new screen and the row itself does not change. The submenu is a native
`NSMenu`, which the DesignShot harness cannot render, so the sketch above is
its mockup (decision: agent); the owner checks it in the running app at the
manual check.

## Tests (minimum)

Go (`internal/sessionreport`, `internal/db`, `internal/tools`):

1. The owner's case: S1 linked 35 targets of group A by old rows, S2 later moved
   them (`status_at` set) → S1's progress excludes them; S1's group B counts.
2. Migration backfill: old rows get `status_at = last_at`; the later one wins.
3. A comment from S2 (new row, `status_at` NULL) on a leaf S1 moved does not
   take it.
3a. S2 moves a **group** S1 linked: S1 keeps every leaf under it.
3b. `create_targets` stamps: the creating session owns the new leaves.
3c. Tie on `status_at` → the higher session id owns.
4. Session target set → progress = its subtree only; lists still show other
   links.
4a. Bound target archived (off the board) → rule 2 applies.
5. `set_session_target`: no session → refused before any row; other
   workbench's target, archived or dismissed target → refused; `0` clears and
   rule 2 applies (old links kept); audit row present; binding stamps the
   subtree's leaves so another unbound session loses them; a failure in the
   stamp write leaves `target_id` unchanged (one transaction).
6. Owner board move does not change ownership.
7. CLI refused under an agent marker.

Swift: the presentation strings; the menu model builds from the outline with
the checkmark on the current target and "None" when unbound.

## Decisions

| Decision | Source |
|---|---|
| Option C: automatic ownership + explicit binding | owner, ask #844 |
| Ownership moves only on a status change (comments don't steal) | owner, ask #844 (option text) |
| Owner board moves don't change ownership | owner, ask #846 |
| Work outside a bound target: in the report, not in the number, no marker | owner, ask #846 |
| Old links: one-time backfill `status_at = last_at` (comments-only old rows may own) | agent |
| Ownership on leaves only; moving a group takes nothing | agent |
| Binding stamps the subtree's leaves (re-pointing moves numbers at once) | agent |
| Binding refused for archived/dismissed targets; `done` allowed | agent |
| Submenu sketch instead of a DesignShot (native menu) | agent |
| `create_targets` counts as a status stamp | agent |
| Bound scope is strict: work outside it is in the report only | owner, ask #846 |
| No ownership exclusion inside a bound target | agent |
| Bound target off the board (archived/deleted) → rule 2 | agent |
| Finished sessions keep ownership | agent |
| Clearing the target (`0`) keeps the links; rule 2 applies | agent |
| One Go writer (MCP tool + CLI), Desktop through the CLI | agent |
| Submenu on the row menu, reusing the Move to… outline; no new screen | agent |
| Ties → higher session id | agent |
| Re-binding also changes the `finish_session` ticket (one field) | owner, ask #850 |

## Left to the builder

Exact query shape for owners; where the menu model lives; skill pack wording.
