# Reviewing a big branch — danger first, never all-or-nothing (board #1025)

**Date:** 2026-11-07 · **Board:** #1025 · **Technical spec:** `2026-11-07-big-branch-review-technical.md` (for the agents)
**Builds on:** `docs/features/diff-reviewer.md`, `docs/inventory/review.md` (REVIEW-01..05)

## The problem

A feature branch that collects many agents' lanes is Watchtower's main way of shipping
(lanes merge into `feature/<x>`, one PR goes to `main`). Such a branch is hundreds of files.
On one of them (≈700 files, ≈35k changed lines) Branch review's AI overview failed outright
("context deadline exceeded"), and what was left was a bare diff: fixtures, golden files,
generated schema and real code mixed together, no chapters, no reading order. Where help is
needed most, the product gave none.

The cause: the overview is one model call over the whole diff, cut blindly at 6,000 lines,
with a 5-minute budget; when it runs out, everything is lost and Retry starts from zero.

## What changes for the owner

1. **Chapters at once, without AI.** Opening Branch review shows chapters within seconds:
   by the lanes and tickets merged into the branch (a lane's branch → its board target or
   Jira issue, with the title), split by package inside a large lane; by package when the
   branch has no lanes. Fixtures, golden, generated and lock files go into one folded
   chapter **Can skip**, with their size; noise is never sent to the model and costs no
   AI budget.
2. **Danger first.** Chapters are ordered by how dangerous their changes are, not by the
   branch's history. Instantly and without AI, every chapter gets a danger level from what
   it touches: migrations and schema, behaviour contracts (`docs/inventory`), guard tests
   changed or deleted, tests deleted, public functions and types removed or renamed, MCP
   tools / CLI flags / pinned JSON keys, dependencies and CI, prompts, auth / tokens /
   policy. A repository can add its own patterns (breaking / significant / can skip) in
   `.watchtower/review-map.md` — a file of its own, because every `## ` heading of
   `.watchtower/review.md` is already a review lens. On top sits
   **Breaking and significant** — that is what to read first; noise is last.
3. **AI per chapter, as it arrives.** Chapters are described in their own model calls (one
   per batch, item 5): what a chapter does, what can break and why. At most 3 calls run at
   once, each with 4 minutes; the summary has 2 minutes; the whole overview stops at 15
   minutes (today: one call, 5 minutes). Chapters fill in as they finish; a chapter that
   fails or runs out of time shows a plain line ("The overview of chapter X did not finish
   in 4 min — Retry") and Retry redoes only that chapter. The provider's own error text is
   behind a disclosure; the log file gets only the error class and counts, never names or
   text (FILES-01). Finished chapters are cached and survive Retry, relaunch and Refresh;
   only chapters whose code changed are redone.
4. **Checked against the goal.** A short summary on top checks the whole branch against the
   intent of its ticket(s) — the session's ticket and every lane's ticket found on the board
   or in Jira: done, partial, not found, and what was done outside the goal. The agent's
   finish check still looks at its own session's ticket only. If the summary fails while the
   chapters are ready, the chapters stay shown, the summary place says so with its own
   **Retry** (it redoes only the summary, from the cached chapters), and the agent's finish
   check refuses with "re-run the overview; only what is missing is redone" — the same as
   today when no overview exists. A lane ticket whose title cannot be found (no board
   target, Jira issue not synced) is shown by its branch name; Jira is read from
   Watchtower's own database, never over the network.
5. **Small and big, one path.** There is no size threshold. Chapters are packed into batches
   that fit one model call (about 2,500 diff lines): a small PR is one
   batch, so it is one call that returns the chapter texts and the goal summary together —
   no extra calls, no extra wait; a big branch is many batches in parallel plus a short
   summary call. The mechanical part (chapters, danger, **Can skip**) is instant and always
   there. With a single chapter the chapter list is not shown: a small PR looks as it does
   today, plus the danger marks. A chapter larger than one call (one huge package) gets a
   call of its own and is cut inside it by priority: its most dangerous files first, and each
   file shows at most its first 300 changed lines with "(+N lines not shown)" — never dropped
   whole as today.
6. **Reading progress.** "N chapters / M files left", chapter viewed (exists today), next
   chapter in danger order.
7. **Honest limits.** A branch past the diff's own cap (50k changed lines) says so in a
   banner instead of cutting silently.
8. **Phase 3 — the reviewer.** An independent read-only agent beside the diff (not the
   author): one thread per branch, each turn a fresh call that gets a compact map of the
   branch (chapters, danger, summary, the open chapter) and reads the code itself. It
   answers "what breaks if…", "what would adding another provider take". An answer becomes
   a comment for the author only when the owner presses **Send to author**. A failed or
   timed-out turn shows an error line with Retry, like the other embedded chats. To read a
   session that works in its own worktree, `ai query --read-folder` is widened from the
   workbench folder to that workbench's registered session worktrees (ask #560; amends the
   read-folder capability rule of spec 2026-10-02 §9.1).

## Contracts and storage that change

- **REVIEW-01 (amendment, needs the owner's approval with this spec):** the overview writes,
  besides `review_overviews`, one new table `review_overview_parts` (one cached description
  per chapter); `review start` and Refresh store the commit the round was taken at
  (`review_rounds.head_sha`). Both are database rows; no file, ref or index is written.
  Nothing else in REVIEW-01..05 changes.
- **Read-folder capability rule** (spec 2026-10-02 §9.1): widened as in item 8 (ask #560).
- **Migration 00173:** `review_overview_parts`, `review_rounds.head_sha`; phase 3 adds the
  reviewer's thread table.
- **Chapters move to Go entirely.** Swift's `ReviewChapters.mechanical` is removed — no
  second implementation. The existing chapter keys (`agent:<n>`, `dir:<dir>`, `collapsed`)
  stay exactly as they are, so saved positions and checks in rounds keep matching; a shared
  Go↔Swift fixture pins them before the Swift code goes. Old `ai:` chapter keys stop
  matching (the round opens on its first chapter).

## Phases

1. **Go:** chapters from the branch structure, danger signals, noise chapter, per-chapter AI
   with its own cache, the goal summary, honest errors.
2. **Desktop:** danger order, chapter progress as it arrives, Retry of one chapter, counters.
3. **Reviewer** chat.

## Out of scope

- Reading results of review skills (local-review, debate-review): they are the owner's own
  skills, not Watchtower's, and Watchtower cannot rely on them.
- Raising the diff's 50k-line cap.
- Any change to rounds, comments, Undo, Approve or REVIEW-01..05 beyond what is listed.

## Done when

- On a branch of ≈700 files Branch review shows chapters, the **Can skip** chapter and the
  danger order within 30 s, with no AI; AI chapter texts arrive as they finish.
- One chapter's call cut off by force leaves the others shown; its Retry redoes only it;
  the cache survives a relaunch.
- Tests on a large synthetic branch (hundreds of files plus fixtures) and on "one chapter
  failed".
- A branch past 50k changed lines shows the size banner; a one-chapter PR shows no chapter
  list and makes exactly one model call.
- The summary's failure leaves the chapters shown and its Retry redoes only the summary.
- Phase 3: the reviewer answers a cross-chapter question from a session in its own
  worktree, its failed turn shows Retry, and **Send to author** adds one design comment to
  the open round — nothing reaches the author's session without that press.
- REVIEW-01 changes only as listed above; REVIEW-02..05 unchanged.

## Decisions

- Item 6 of the target (reading other review skills' reports) is dropped: they are user
  skills, not Watchtower's — conversation (ask #555, and the owner's later reply).
- Chapters from lanes, commits and tickets, tried on this repo and neighbouring ones before
  committing to it — conversation.
- Reading order by danger: breaking and significant changes first, not everything in a row;
  the branch is checked against its end goal — conversation.
- The reviewer is a separate read-only agent, one thread per branch, no live session, the
  branch map in every turn — ask #558 and conversation.
- The reviewer is phase 3, after the overview — ask #559.
- The reviewer may read the session's own worktree: `--read-folder` is widened to the
  workbench's registered session worktrees — ask #560.
- The goal check covers the session's ticket and every lane's ticket; the agent's finish
  check stays on its own ticket — agent's call, see the technical spec §3.1.
- No size thresholds: one path that packs chapters into call-sized batches, so a small PR is
  one call and a big branch many — conversation.
- Noise goes into a folded **Can skip** chapter and never into the model's budget; a branch
  past the diff cap gets a banner — target #1025's requirements 3 and 8 (the owner's
  target text), kept as written.
- The numbers (3 parallel calls, 4 min per call, 2 min summary, 15 min ceiling, ≈2,500
  lines per call) — agent's call, replacing the target's "2 min" example: a smaller call
  finishes sooner, and 4 min leaves room on a slow provider.
- The danger patterns' file is `.watchtower/review-map.md`, not `review.md` (which the
  conversation named): every heading of `review.md` is a lens — agent's call.
- REVIEW-01 amendment and Go-only chapters — agent's call, approved with this spec.

## What the spike showed (lane attribution, no AI)

On this repository's largest feature branch and on two dozen branches of a dozen other
repositories: where a branch merges lanes or carries ticket keys in commits or branch
names, 70–100 % of the files fall into a named lane; a single-author branch with no tags
gets 0–46 %, so the package fallback is required. Lanes are very uneven (one lane of
≈150 files next to many of 1–3 files), so a large lane is split by package; 30–45 % of the
files were touched by more than one lane, so a file sits in one chapter and shows the other
lanes as labels. Attribution took 3–4 s on 700 files.
