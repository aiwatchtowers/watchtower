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
   chapter **Can skip**, with their size.
2. **Danger first.** Chapters are ordered by how dangerous their changes are, not by the
   branch's history. Instantly and without AI, every chapter gets a danger level from what
   it touches: migrations and schema, behaviour contracts (`docs/inventory`), guard tests
   changed or deleted, tests deleted, public functions and types removed or renamed, MCP
   tools / CLI flags / pinned JSON keys, dependencies and CI, prompts, auth / tokens /
   policy. A repository can add its own patterns in `.watchtower/review-map.md`. On top sits
   **Breaking and significant** — that is what to read first; noise is last.
3. **AI per chapter, as it arrives.** Chapters are described in their own model calls (one
   per batch, item 5), each with its own budget: what a chapter does, what can break and why. Chapters fill in as they finish; a chapter
   that fails or runs out of time shows a plain line ("The overview of chapter X did not
   finish in 4 min — Retry") and Retry redoes only that chapter. Finished chapters are
   cached and survive Retry, relaunch and Refresh; only chapters whose code changed are
   redone.
4. **Checked against the goal.** A short summary on top checks the whole branch against the
   intent of its ticket(s) — the session's ticket and every lane's ticket found on the board
   or in Jira: done, partial, not found, and what was done outside the goal. The agent's
   finish check still looks at its own session's ticket only.
5. **Small and big, one path.** There is no size threshold. Chapters are packed into batches
   that fit one model call (about 6,000 diff lines, today's input size): a small PR is one
   batch, so it is one call that returns the chapter texts and the goal summary together —
   no extra calls, no extra wait; a big branch is many batches in parallel plus a short
   summary call. The mechanical part (chapters, danger, **Can skip**) is instant and always
   there. With a single chapter the chapter list is not shown: a small PR looks as it does
   today, plus the danger marks.
6. **Reading progress.** "N chapters / M files left", chapter viewed (exists today), next
   chapter in danger order.
7. **Honest limits.** A branch past the diff's own cap (50k changed lines) says so in a
   banner instead of cutting silently.
8. **Phase 3 — the reviewer.** An independent read-only agent beside the diff (not the
   author): one thread per branch, each turn a fresh call that gets a compact map of the
   branch (chapters, danger, summary, the open chapter) and reads the code itself. It
   answers "what breaks if…", "what would adding another provider take". An answer becomes
   a comment for the author only when the owner presses **Send to author**.

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
- REVIEW-01..05 not weakened; any amendment goes through the owner.

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

## What the spike showed (lane attribution, no AI)

On this repository's largest feature branch and on two dozen branches of a dozen other
repositories: where a branch merges lanes or carries ticket keys in commits or branch
names, 70–100 % of the files fall into a named lane; a single-author branch with no tags
gets 0–46 %, so the package fallback is required. Lanes are very uneven (one lane of
≈150 files next to many of 1–3 files), so a large lane is split by package; 30–45 % of the
files were touched by more than one lane, so a file sits in one chapter and shows the other
lanes as labels. Attribution took 3–4 s on 700 files.
