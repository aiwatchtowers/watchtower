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
   subtrees of linked targets that have children — **minus every target owned
   by another session**.

**Ownership.** The owner of a target is the session with the latest
*status stamp* for it among all agent sessions of the workbench. A session's
status stamp for a target is:

- `status_at` on its link row: set when that session's write **changed the
  target's status** (an `update_target` with a new `status`, or a `column`
  move that changes the status) or
  **created** the target (`create_targets`);
- for a link row with `status_at` NULL (every row written before this change,
  and links from comments/asks only), its `last_at` stands in **only if no
  session has a non-NULL `status_at` for that target**. Rationale: old rows get
  a sensible owner (the session that touched the target last), while from now
  on comments never steal a target from a session that moved it.

Exclusion is decided per leaf: walk from the leaf up through its ancestors
and take the **first one that has an owner** (the leaf itself included). If
that owner is another session, the leaf leaves S's progress. If no target on
the path has an owner, the leaf stays. So a group another session took over
(by moving the group itself) goes with all of its leaves, unless S later
moved a leaf inside it.

A target nobody owns (no link row at all) counts for every session whose scope
reaches it, as today. Owner moves on the Board (actor `owner`) write no link
and so never change ownership (ask #846).

Ties (equal stamps, second resolution) go to the higher session id.

### Binding a session to a target (owner ask #844, option B part)

**One Go writer**: `terminal_sessions.target_id` stays written by the Desktop
at launch (unchanged) and is re-written only through Go:

- **MCP tool `set_session_target`** on the workbench surface (DEV-06: nineteen
  → twenty tools; skill pack bump). Args: `target_id` (a target of this
  workbench; `0` clears), `reason`. Resolves the calling session exactly like
  `finish_session` (`terminalSessionOf`; no session → refused with
  `set_session_target needs a Watchtower terminal session`, before any row or
  audit row). Applied directly and audited like the other workbench writes.
  It also links the target (`LinkSessionTarget`) when non-zero.
- **CLI `watchtower workbench session-target --session N (--target M | --clear) [--json]`**:
  same validation; refused under an agent marker (owner verb, like `coach
  accept`). The Desktop calls it.
- **Desktop**: the session row's context menu gets **Session Target ▸**, a
  submenu built from the same outline as the board's **Move to…**
  (`WorkbenchBoardOutline`), plus **None — Count What It Touched** at the top
  and a checkmark on the current one. After the CLI returns, the report
  refreshes (the existing session-report refresh).
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
-- +goose Down
ALTER TABLE terminal_session_targets DROP COLUMN status_at;
```

Mirror in `schema.sql`, regenerate the golden snapshot and the Swift test
schema. No backfill (old rows use the `last_at` fallback above).

`db.LinkSessionTarget(sessionID, targetID)` gains a sibling
`LinkSessionTargetStatus(sessionID, targetID)` that sets `status_at = last_at =
now`. `linkSession` takes a flag; `update_target` passes it when the status
changed (it already knows: `a.Status != t.Status`, and the column path), and
`create_targets` passes it for every created target.

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

- **PROJ-14 amended**: the progress scope rule above; `set_session_target`
  and the CLI as the only re-writers of `terminal_sessions.target_id` after
  launch, which also re-points the finish gates' ticket (ask #850); `status_at` written only by the status-changing / creating writes.
  Guard tests renamed in place only if their wording changes; none relaxed.
- **DEV-06**: twenty tools; the vocabulary test's count bumps.

## UI text (model-owned, tested)

In a WatchtowerCore presentation type, covered by a test:

- menu title `Session Target`
- top item `None — Count What It Touched`
- failure line (the CLI's error) `Couldn't change the session target: <error>`

No new screen; the row itself does not change, so no new DesignShot. The
existing row shots stay valid (decision: agent).

## Tests (minimum)

Go (`internal/sessionreport`, `internal/db`, `internal/tools`):

1. The owner's case: S1 linked 35 targets of group A by old rows, S2 later moved
   them (`status_at` set) → S1's progress excludes them; S1's group B counts.
2. Old rows only (all `status_at` NULL): the later `last_at` wins.
3. A comment from S2 on a target S1 moved does not take it.
4. Session target set → progress = its subtree only; lists still show other
   links.
5. `set_session_target`: no session → refused before any row; other
   workbench's target → refused; `0` clears; audit row present.
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
| Old links fall back to `last_at`, no backfill | agent |
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
