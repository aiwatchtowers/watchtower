# Spec review — Behavior Inventory

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/specreview/`, `internal/db/spec_reviews.go`,
> `internal/daemon/spec_review_sweep.go`, `cmd/workbench_spec_review*.go`, or the spec
> review parts of `internal/tools/workbench_asks.go`, read this file first. Any proposed
> change that would break a guard test or remove a contract must be raised as a
> question before touching code.

**Module:** `internal/specreview/` (`loop.go`) + `internal/db/spec_reviews.go` + `internal/daemon/spec_review_sweep.go` + `cmd/workbench_spec_review.go` + `cmd/workbench_spec_review_launch.go` + `internal/tools/workbench_asks.go` (`doc_type`, launcher)
**Last full audit:** 2026-10-25 (created)
**Owner approval:** spec `docs/superpowers/specs/2026-10-25-spec-review-design.md`; author loop spec `docs/superpowers/specs/2026-10-26-spec-review-author-loop-design.md` (asks #647, #649, #650, #653, #658); feature note `docs/features/spec-review.md`.

---

## SPECREVIEW-01 — the reviewer never writes the folder, and writes only its own `spec_reviews` row

**Status:** Enforced (Go).

**Observable:** A reviewer run (`workbench spec-review run`, `specreview.Run`) reads
the ask, the conversation and the workbench folder, and stores its result in the ask's
`spec_reviews` row (claim, finish or fail). Every other table keeps its rows, the
folder keeps every entry's mtime and size, on success and on failure alike.

**Why locked:** The reviewer is an agent that reads an unreviewed document and the
folder; a write outside its row would let a spec steer the owner's data.

**Test guards:**
- `internal/specreview/run_test.go::TestSpecReview01_RunWritesOnlyItsRow` (every table but `spec_reviews` diffed before and after a done run and a failed run; the folder's mtimes and sizes)

**Locked since:** 2026-10-25

---

## SPECREVIEW-02 — `ask_owner` files the ask whatever the reviewer does

**Status:** Enforced (Go).

**Observable:** A review ask is filed and returned even when the reviewer cannot be
launched, the surface has no launcher, or the
`spec_reviews` queue write fails (it runs after the ask's own transaction has
committed). The review row is then `skipped` with the reason ("launch failed: …",
"no reviewer on this surface", "could not queue: …"; a queue
failure may leave no row, and the reason is then only in `spec_review`); the ask
itself is never failed or delayed by it.

**Why locked:** The ask is the owner's channel; a broken background reviewer must
not cost the owner the question.

**Test guards:**
- `internal/tools/workbench_asks_spec_review_test.go::TestSpecReview02_AskOwnerLaunchFailureStillFiles`
- `internal/tools/workbench_asks_spec_review_test.go::TestSpecReview02_AskOwnerQueueFailureStillFiles` (an injected `spec_reviews` insert failure)

**Locked since:** 2026-10-25

---

## SPECREVIEW-03 — no stored quote is absent from its source, and "the owner's words" are the owner's

**Status:** Enforced (Go).

**Observable:** `specreview.Parse` keeps an item only when each quote it cites is a
(whitespace-normalised) substring of the conversation or the document it names; an item
with an invented quote is dropped and counted in `dropped`. A quote shorter than 8 runes or
longer than 1000 is rejected, never clipped, so every stored quote is a real substring.
Every stored `source` carries the `speaker` Parse found (`owner` | `agent`, never the
model's): `owner` only when the quote lies in the owner's own words of that ref — an
owner line of the conversation, the owner's answer texts — the chosen option labels and
free answers — / notes / comment bodies of an ask (in the asks block or as a conversation
ask-answer entry; never the ask's questions or check items), an owner comment. The
target, the Decisions section and the spec are `agent` (author side). `idea.owner_source`
must be `owner`; an agreement citing the conversation, an ask or a comment must be
`owner`, while `decisions`, `spec` and `target` sources stay allowed as `agent`.

**Why locked:** The owner reads the findings as evidence; one invented quote makes
all of them unreliable.

**Test guards:**
- `internal/specreview/specreview_test.go::TestSpecReview03_ParseDropsInventedQuotes`
- `internal/specreview/specreview_test.go::TestSpecReview03_IdeaNeedsOwnerWords` (an idea quoting an agent line or the target is dropped)
- `internal/specreview/specreview_test.go::TestSpecReview03_AgreementSpeakers` (agent conversation line, an ask's question and an agent comment dropped; speakers recorded)

**Locked since:** 2026-10-25

---

## SPECREVIEW-04 — a hidden review ask always becomes visible

**Status:** Enforced (Go).

**Observable:** A spec or plan review ask in the author loop (`spec_reviews.loop = 'author'`) is hidden from the owner only while the loop runs. Every exit ends in `loop = 'owner'` with its `loop_end`: the normal end (`settled`: nothing left for the author), the round cap (`cap`, 3 rounds), a reviewer that failed, was skipped or could not start (`reviewer_failed`, also from `ask_owner` when the queue or launch is skipped), an ask that lost its session or whose findings could not be delivered (`session_gone`), an author silent for `AuthorTimeout` (30 min from `finished_at`, `timeout`) and the owner's **Show Now** (`owner`; on a first round the reviewer has not finished, the row leaves the loop as a plain review, `loop = ''` with `loop_end = 'owner'`, so the findings land on the findings screen). The daemon's `sweepSpecLoops` owns the time-based and dead-reviewer exits and does not depend on the launcher or on the Desktop being open; the owner never gets more than one ask per loop.

**Why locked:** A loop stuck on a dead session, a failed reviewer or a silent author would hide the owner's ask for good.

**Test guards:**
- `internal/daemon/spec_review_sweep_test.go::TestSpecReviewSweep_LoopTimeoutReveals`
- `internal/daemon/spec_review_sweep_test.go::TestSpecReviewSweep_LoopSessionGoneReveals`
- `internal/daemon/spec_review_sweep_test.go::TestSpecReviewSweep_DeadReviewerRevealsLoop`
- `internal/daemon/spec_review_sweep_test.go::TestSpecReviewSweep_FailedOrSkippedLoopReveals`
- `internal/tools/workbench_spec_review_loop_test.go::TestAskOwner_LoopSkipReveals`
- `internal/specreview/run_test.go::TestRun_LoopFailureReveals`
- `internal/specreview/loop_test.go::TestNextRound_CapMovesOpenToUnsettled`

**Locked since:** 2026-10-26

---

## SPECREVIEW-05 — nothing the author changed in the loop is hidden from the owner

**Status:** Enforced (Go).

**Observable:** Every finding the author answered `fixed` in any round ends in the final ask, either in the `ledger` (the reviewer judged it resolved, with its round and note) or in `open_items` (a dispute or "not settled"). `NextRound` drops no `fixed` reply, and an early `Reveal` keeps each such item: a done row shows its own `open_items`, a failed row the previous round's, and an unchecked fix says so instead of "the author did not answer".

**Why locked:** The author could otherwise rewrite what the owner agreed without the owner seeing it.

**Test guards:**
- `internal/specreview/loop_test.go::TestNextRound_*` (resolved and disputed settle, a disputed-after-fixed item stays open, a missing verdict stays open, a missing reply is `fixed`, new findings skip known keys, settled when nothing is open)
- `internal/specreview/run_test.go::TestReveal_DoneRowUsesItsOpenItems`
- `internal/specreview/run_test.go::TestReveal_FailedRowUsesPrevious`

**Locked since:** 2026-10-26

---

## Changelog

- 2026-10-25 (spec review Plan 1): file created with SPECREVIEW-01, 02, 03.
- 2026-10-25 (Plan 1 final review fixes): SPECREVIEW-02 covers a failed queue write (queued after the ask's commit); SPECREVIEW-03 checks the speaker of the owner's words and stores `speaker` on every source.
- 2026-10-25 (PR #473 review fixes): wording only, no guard changed — SPECREVIEW-03's Observable names the chosen option labels among the owner's answer texts (as `ownerAnswerWords` always did). A plan's review header carries no `decisions_section`; a spec's Decisions section is a `## ` heading starting with "Decisions" (`isDecisionsHeading`, Swift `SpecReviewDecisions`); an empty idea is left out of the result (`idea` omitted).
- 2026-10-26 (spec review author loop, board #1121, **owner approved in asks #653 and #658**): **SPECREVIEW-04** and **-05** added; SPECREVIEW-01..03 unchanged (delivery of findings is the Desktop's, not the reviewer's). Migration 00160 (`spec_reviews` `loop`, `round`, `replies`, `open_items`, `ledger`, `loop_end`), `get_spec_review` (DEV-06 nineteen tools), `review_replies` on `ask_owner`, prompt `review.spec` v2, pack v18. The old "the owner is the filter" rule of the 2026-10-25 spec is replaced for spec and plan asks in a loop (owner decision D2, ask #649).
- 2026-10-26 (author loop final review fixes): SPECREVIEW-04 gains the guard `TestSpecReviewSweep_FailedOrSkippedLoopReveals` — the sweep reveals a loop row left `failed`/`skipped` when the immediate reveal did not land. No guard weakened.
- 2026-10-26 (owner): wording only, no guard changed — the automatic start no longer skips on the Claude plan's limits, so SPECREVIEW-02's Observable drops "plan near limit" from its examples.
- 2026-10-26 (agent coach, board #1120): additive, no guard changed. `spec_review_marks.state` gains `not_useful` (migration 00162; Swift `SpecReviewMarkState.notUseful`, never sent to the author by `SpecReviewAnswer`; an older reader skips it), so `workbench spec-review show --json` `marks[].state` may be `ok`, `comment`, `viewed` or `not_useful`; `spec_reviews.findings` (`-1` = not counted) is written by `FinishSpecReview` with the count of findings in `result`, at the first finish only. Rows are never rewritten by the coach.
- 2026-10-27 (owner, in session: "фиксани" after the plan loop of ask #683): additive, no guard changed. SPECREVIEW-04 gains the exit `owner` — **Show Now** in the stack's Reviewer and author rows (`workbench spec-review reveal --reason owner`); on a first round still queued or running the row becomes a plain review (`LeaveSpecLoop`), the one exit not ending in `loop = 'owner'`. `ask_owner` refuses a plan review while a spec review ask of the same session is open.
