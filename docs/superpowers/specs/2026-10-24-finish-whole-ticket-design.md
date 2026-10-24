# A session finishes its whole ticket, checked against the reviewer's AI overview

Board target #947. Status: draft for the owner's review.

## Why

Session 18 (track #907) took the order in ask #517 — "first A, then B" — as
the edge of its work, called the track done after A and left B "for later".
The session card (12 of 18 leaves) and the reviewer's AI overview (round #2:
coverage `partial` / `not_found`) both showed the truth; nothing made the
agent look at either before `finish_session`. The owner: "this is the order,
not the end of the work".

## What changes

1. **The ticket is the scope.** A session's work is the whole target it was
   started for — every leaf of that target's subtree — not the part the agent
   assigned itself. An order of parts is a sequence, never a boundary.
2. **`finish_session` checks it, in Go, cheaply,** through two gates (below).
   A gate that fails refuses the call with the list of what is open and the
   exact next step. The way past a gate without doing the work is one ask to
   the owner that names what is left and why (`handover_ask_id`).
3. **The skill pack says it** (core skill "Finishing a session", pack v14),
   so the agent runs the check before it calls `finish_session` instead of
   learning it from a refusal.

The reviewer itself (its input — the session-linked targets — and its
prompt) is not touched here.

## The ticket

The session's ticket is `terminal_sessions.target_id` — the target the
Desktop launched the session for (**Work on It**: "Work on target #N" /
"Work on group #N"). A session started by hand has none; then the
`target_id` argument of `finish_session` is the ticket. Neither → no ticket,
gate 1 is skipped.

## Gate 1 — open leaves

The open leaves of the ticket: the ticket itself when it has no sub-targets,
else every leaf of its subtree, not archived, with status `todo`,
`in_progress` or `in_review`. `blocked` leaves do not count — a blocked leaf
already waits on someone and carries its ask or comment. `done` and
`dismissed` never count.

Any open leaf → refused, unless `handover_ask_id` is given (see "The
handover ask"). The refusal lists up to 20 leaves as `#id [status] title`
and says: finish them, or file one ask that explains why each is not needed
now and pass it as `handover_ask_id`.

## Gate 2 — the reviewer's AI overview

Runs when the session's folder (`ReviewSessionFolder`: the session's worktree
or the workbench folder) has a non-empty diff against its base
(`reviewdiff`: merge-base with the default branch, working tree included).
An empty diff skips the gate (research, docs on another branch, a branch
already merged — see v1 limits).

1. `finish_session` takes a fresh snapshot (`repo.Snapshot`, the same temp
   index `annotate_changes` uses), the base, and the intent hash the overview
   cache is keyed by (`reviewai.IntentHash` over the session's context items
   and its notes).
2. It looks the overview up in the existing cache
   (`ReviewOverviewJSON(workbench, tree, base, hash)`). It never calls the
   model.
3. **Missing** → refused: "run `<bin> workbench review overview --session
   <id> --json`, read its coverage, then call finish_session again". `<bin>`
   is the hooks' absolute binary, as in the brief's `Cleanup:` line.
4. **Present** → every coverage item with status `partial` or `not_found` is
   listed. Any → refused unless `handover_ask_id` is given.

### `workbench review overview --session <id>`

New form of the existing command, for the agent: no `--round`, no round
created. It snapshots the session's folder, finds the base and the intent,
answers a cached overview or makes the one model call and caches it — the
same cache key the Desktop's round uses, so when the owner opens a round on
the same tree, the overview is already there (one model call serves both).
`--round` and `--session` are exclusive. Same JSON envelope, same 5-minute
budget, same `--cached-only`.

Cost: one strong-tier call per distinct (tree, base, intent). A finish
after more work on a changed tree needs one more call; a repeated finish on
the same tree is a cache hit. The overview's intent hash includes the agent's
notes, so the skill orders it: `annotate_changes` first, then the overview,
then `finish_session` (a note added after the overview makes gate 2 ask for
it again).

**The overview fails** (no provider, timeout, a malformed reply — failures
are never cached): the command exits non-zero as today; the agent cannot pass
gate 2 without it, so it says so in the handover ask (it is the owner who
decides that the work is complete without the reviewer).

## The handover ask

`finish_session` gains `handover_ask_id` (optional). It passes both gates
when it names an ask that:

- belongs to this workbench and was filed by this session
  (`owner_asks.session_id`);
- is `open`, `answered` or `delivered` (not `withdrawn` — a superseded ask is withdrawn);
- has its `target_id` inside the ticket's subtree (the ticket itself
  included), when there is a ticket.

The ask is the owner's view of "what is left and why": the gate checks that
it exists, not what it says. With it open, the session ends **Finished with
open asks** (orange, PROJ-11 unchanged); the owner's answer reaches the
session as any answer does.

## The finish check toggle

Both gates run only with the workbench's finish check on (the default). With
it off (`workbench methodology --finish-check off`, owner only) the call
behaves as today. Ask guard modes do not matter here.

## Result and refusals

Refusals are `ValidationError`s (nothing written, no audit row — as every
`Validate`/`Scope` refusal today), so the agent's retry is clean. A pass adds
to the result `ticket_id`, `open_leaves` (0, or the count handed over) and
`overview` (`checked` / `handed_over` / `skipped_no_diff` /
`skipped_no_ticket`).

Gate 2's git work runs in `Scope`, bounded by the existing workbench git
budget; a git failure refuses with the error (the agent retries or hands
over), never silently passes.

## Skill pack v14

Core skill, "Finishing a session", new first paragraph:

- The work is the whole ticket the session was started for — every leaf. An
  order the owner gave ("first A, then B") is a sequence, not a scope cut.
- Before `finish_session`: `annotate_changes`, then
  `<bin> workbench review overview --session <id> --json`; compare your
  "done" with its coverage — finish what is `partial`/`not_found`, or file
  one ask that says why it is not needed and pass it as `handover_ask_id`.
  Do the same for any open leaf of the ticket.

v13 joins the DEV-04 re-install fixtures; the Codex copy follows. The Stop
hook's finish reasons (`askGuardReasonFinish*`) gain "check the ticket and
the overview first" — text only, the decision table is unchanged.

## Contracts

- **PROJ-14 amended** (owner approval = this spec's review): `finish_session`
  refuses while the ticket has open leaves or the session's diff has no
  checked overview, unless a handover ask of this session is named. Only the
  session itself still says it finished.
- **PROJ-13**: reason texts only; no guard relaxed.
- **DEV-06**: tool count unchanged; `finish_session` schema gains one field.
- **PROJ-04**: pack v14, v13 fixture.

New guards: `TestProj14_FinishRefusesOpenLeaves`,
`TestProj14_FinishRefusesWithoutOverview`,
`TestProj14_FinishRefusesUncoveredItems`,
`TestProj14_HandoverAskPassesBothGates`,
`TestProj14_HandoverAskOfAnotherSessionRefused`,
`TestProj14_FinishCheckOffSkipsGates`.

## v1 limits

- A session that merged its PR and returned to the default branch has an
  empty diff: gate 2 is skipped, gate 1 still holds.
- The overview judges only the session-linked targets (the reviewer's input
  is unchanged); gate 1 covers the rest of the subtree mechanically.
- A session with no ticket and no diff is not checked.
