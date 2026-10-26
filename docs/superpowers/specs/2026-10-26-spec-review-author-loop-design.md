# Spec review — the author fixes first, the owner sees only what is disputed (design)

Builds on `docs/superpowers/specs/2026-10-25-spec-review-design.md` (the reviewer, its result and the findings screen) and `docs/features/spec-review.md` (what shipped). Brainstorm: owner asks #647, #649, #650 (2026-10-26).

## Why

The spec reviewer works, but every round goes through the owner. In most rounds the owner decides nothing:

- the reviewer finds something obvious, and the owner presses "yes, fix it";
- the author fixes it, the reviewer finds new small things in the new version, and the loop starts again;
- to send a round, the owner has to mark findings and write a comment, even when the whole answer is "fix it".

The owner wants the reviewer to run in the background, hand its list straight to the author, and call the owner only when something is genuinely disputed.

## What it is

A review ask for a spec or a plan first goes through an **author loop** the owner does not see: reviewer → author fixes or disagrees → reviewer checks again. When the loop settles, the owner gets **one** review ask: the disputed findings on top, what the author fixed on its own folded below, and Approve.

## Decisions

- D1 (#647): the owner's wasted rounds are "yes, fix it" on obvious findings and the reviewer finding new things after the fixes; marking every finding and writing a comment to send a round is pointless when the answer is "fix it".
- D2 (#649): the owner sees only findings where the reviewer and the author disagree. Everything else — including what the author decided alone — the author fixes or justifies without the owner.
- D3 (#650): when the loop ends, the owner gets one ask: the disputed findings plus the final approval. With nothing disputed it is just Approve. No automatic approval.

## Goals

- A spec or plan reaches the owner already corrected for every finding the author accepted.
- The owner's pass is: settle each dispute with one tap, glance at the folded list of fixes if they want, Approve.
- No marks, no comments required to approve or to settle a dispute.
- The loop always ends: in a bounded number of rounds, and on any failure the ask reaches the owner the way it does today.

## Non-goals

- Other documents (guide pages, notes) and `doc_type: other` keep today's review ask.
- The phone gets no new screen (see Mobile).
- The reviewer still never edits the document and never writes anything but its own row (SPECREVIEW-01 unchanged).

## Anti-goals (failure even if it technically works)

- **An ask that never arrives.** A loop stuck on a dead session, a failed reviewer or a silent author must never hide the owner's ask for long.
- **Endless ping-pong.** The reviewer keeps raising fresh nits each round and the author keeps "fixing" them.
- **Silent rewrites.** The author changes what the owner agreed and the owner cannot see it: every change made in the loop stays visible in the final ask.
- **The owner back to marking every item.** The final screen must not require a mark per finding.

## How it works

### 1. Starting the loop

Unchanged entry point: the author files `ask_owner` with `kind: review` and `doc_type: spec|plan` (SPECREVIEW-02 holds: the ask is filed at once whatever the reviewer does). What changes: such an ask starts **hidden** — it is not in the Desktop stack, the drawer, notifications, the Home feed or the phone slice — while its review row is in the author loop. How "hidden" is stored (a column on `spec_reviews`, a new ask state) is the builder's call, with one rule: the Desktop's guarded `open → answered` update can never answer a hidden ask.

The `ask_owner` result tells the author the loop is on (e.g. `spec_review: "author_loop"`), so the agent knows findings will come back to it, not the owner's answer.

Which asks get the loop is decided when the review row is queued (my call): a spec/plan ask that is bound to a terminal session (`session_bound`) on a surface with a reviewer launcher. Anything else — no session, no launcher, a skip at queue time — is a visible ask as today. A launch that fails later makes the ask visible at once (§5).

A hidden ask is still an open ask for the author's side (my call): the Stop ask guard counts it, so the author may end its turn and wait like after any ask; `get_ask` and `list_asks` return it as open, with the loop state; the brief's open-asks line names it as "in spec review". The session state shows the review progress (§10), not "waiting for you". Only the owner-facing surfaces of §1 leave it out.

Review rows and asks that exist when this ships keep today's flow; there is no backfill (my call).

### 2. Findings go to the author

When the reviewer finishes a round, the findings are delivered to the author's session the same way an answered ask is today: the Desktop types one line into the session (an `asks.DeliveryLine`-style line with its Go/Swift twin and fixtures), for example:

> Spec review of ask #N, round 2: 5 findings to address — read them with get_spec_review N using the watchtower-workbench skill.

A new read tool on the workbench surface, `get_spec_review` (name is the builder's call), returns the round's open findings: the reviewer's text, the anchor in the document, the quotes, and the item key. The reviewer process itself does not type anything (SPECREVIEW-01): delivery is the Desktop's, triggered by the row turning `done`.

All four finding kinds go to the author (D2): agreements that differ or are missing, decided alone, blind spots, and checks with a concern.

### 3. The author answers

The author edits the document and files the next round as today's re-round: `ask_owner` with `previous_ask_id` (the hidden previous ask is withdrawn as superseded), plus a reply per finding of the previous round:

- `fixed` — optional one-line note of what changed;
- `disagree` — a required reason.

Every finding of the previous round needs a reply; a missing one counts as `fixed` (my call: the reviewer will flag it again if it is not). Where the replies live (a new `ask_owner` field, a separate tool call) is the builder's call; they are stored with the review row so the next round and the final ask can show them.

### 4. The next round

The reviewer runs on the new snapshot with the previous round's findings and the author's replies (today's re-round input, extended with the replies). For each previous finding it says:

- **resolved** — the fix is in the document, or the author's reason convinces it;
- **disputed** — it keeps its position after the author's `disagree` (one line why). A disputed finding is not sent back to the author again; it waits for the owner;
- **still open** — the author said `fixed`, but the fix is not there. It goes back to the author.

From round 2 on, the reviewer raises a **new** finding only about text changed since the previous round, or when it would block the work (a broken promise to the owner, a missing contract, a data-loss path). Small new remarks on unchanged text are dropped (my call: this is what stops the "new things after every fix" loop of D1). The prompt carries the rule; Go does not enforce it.

### 5. When the loop ends

The ask becomes visible to the owner when any of these happens:

- a round leaves nothing for the author: every finding is resolved or disputed (the normal end);
- the round cap is reached: **3 reviewer rounds** per loop — round 1 on the first version, rounds 2 and 3 on the author's fixes (my call). Findings still open after round 3 are shown to the owner like disputes, labelled "not settled in 3 rounds";
- the reviewer fails, is skipped, or cannot start (today's skip reasons): the ask shows at once with today's status strip;
- the author's session is gone (ended, deleted) or the findings line could not be delivered: the ask shows at once with the round's findings as today's findings screen;
- the author does not answer a delivered round within **30 minutes** (my call): the ask shows with that round's findings.

The daemon sweep (`phaseSpecReviewSweep`) owns the time-based exits, so they happen without the Desktop open. The 30-minute timer runs per round, from the delivery of that round's findings. Whatever the exit, the result is one visible ask; the owner never gets more than one ask per loop.

The visible ask is the latest ask of the `previous_ask_id` chain (the earlier ones were withdrawn as superseded); the loop's history — every round's findings, replies and verdicts — belongs to the chain and is shown on that last ask. Whether it is read by walking the chain or copied forward is the builder's call.

On an early exit (cap, timeout, gone session, failed delivery) every finding not yet resolved is shown as a dispute: the author's reason when it gave one, "the author did not answer" otherwise, with the exit reason on top of the screen.

### 6. The owner's screen

The findings screen of 2026-10-25 changes for a loop that ended:

- **Disputed** on top: each card shows the finding, the reviewer's position and the author's reason, with two buttons — **Reviewer is right** (the author must fix it) and **Author is right** (keep the document). An optional comment, never required.
- **Fixed by the author**, folded: each finding the author fixed in the loop, with its note and round, so a change to something the owner agreed is visible (anti-goal "silent rewrites"). Opening one shows the finding and the author's note; **Reopen** turns it into a dispute the owner settles like the others.
- The rest of the screen (Meaning, the chapters, **Read the spec**) stays for an owner who wants to read, but nothing there needs a mark. The per-finding **Fine as is / Comment** marks and the "unmarked items" flags of Wrap-up go away for loop reviews.
- **Approve** is always one press after a normal end. An unsettled dispute on Approve counts as **Author is right** (my call: Approve means "the document as it is"). After an early exit, Approve with unsettled items asks once to confirm, since those findings were never answered.

The **Fixed by the author** list holds the findings the reviewer judged resolved after an author's `fixed` (a claimed fix the reviewer did not confirm is a dispute or "not settled", never in this list). Each shows the round it was resolved in and the author's note; an auto-`fixed` for a missing reply shows "no note".

With nothing disputed, the screen is the folded fixes list and Approve (D3).

### 7. The answer to the author

The owner's answer stays the existing answer JSON (`internal/asks/answer.go` unchanged):

- each **Reviewer is right** becomes a comment anchored like today's (`SpecReviewAnswer`), with the finding's text and the reviewer's position, plus the owner's optional comment;
- **Author is right** sends nothing;
- the verdict: **Approve** with no **Reviewer is right** is `approved`; with at least one it is `approved` too, and the comments are fixes to make (my call: the owner already approved, the fixes are small and decided). The author applies them and carries on; it does not file another review round for them. The skill pack says so.

### 8. Plans

The same loop for `doc_type: plan`; the plan's agreements are the spec's requirements, as today.

### 9. Mobile

A hidden ask is not in the phone's `owner_ask` slice. When it becomes visible, the phone shows it as today (classic review view plus the one-line reviewer status, which gains the disputed count).

### 10. Visible progress (Desktop)

While the loop runs, the session's row or strip shows one line, e.g. "Spec review: round 2 of 3" (placement is the builder's call, design kit components only). No notification until the ask becomes visible.

### 11. Skill pack and guide

- Pack version bump (core skill + `watchtower-flow`): after a spec/plan review ask, expect a findings line, not the owner's answer; read the findings, fix or disagree with a reason, file the re-round with replies; after an approve with comments, apply them and go on.
- Guide: the owner-asks / spec review page describes the loop, the disputed list and the folded fixes.

## Contracts

- SPECREVIEW-01, -02, -03 unchanged. Delivery of findings is the Desktop's, not the reviewer's.
- New: **SPECREVIEW-04 — a hidden review ask always becomes visible**: on a normal end, the round cap, a reviewer failure or skip, a gone session or failed delivery, and an author silent past the timeout. Guarded by Go tests over the sweep and the loop's state transitions.
- New: **SPECREVIEW-05 — nothing the author changed in the loop is hidden from the owner**: every finding the author answered `fixed` in any round is in the final ask, either in the fixes list (resolved) or as a dispute / "not settled".
- The old spec's non-goal "the reviewer does not message the author; only what the owner sends reaches the author" and its §8 rule "the owner is the filter" are replaced by this design for spec/plan asks (owner's D2).

## Left to the builder

- How "hidden" is stored, and the migration (`spec_reviews` columns for the round, the loop state, the author's replies and the delivery time are the expected shape).
- The tool names and where the author's replies are passed.
- How the Desktop notices a finished round for delivery (it already polls review rows on the open drawer; it needs a watcher that runs without it).
- Exact copy of the findings line and the progress line.
- Prompt changes for the round-2+ rule and the resolved / disputed / still-open verdicts, on both providers.
