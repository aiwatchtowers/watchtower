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

**Module:** `internal/specreview/` + `internal/db/spec_reviews.go` + `internal/daemon/spec_review_sweep.go` + `cmd/workbench_spec_review.go` + `cmd/workbench_spec_review_launch.go` + `internal/tools/workbench_asks.go` (`doc_type`, launcher)
**Last full audit:** 2026-10-25 (created)
**Owner approval:** spec `docs/superpowers/specs/2026-10-25-spec-review-design.md`; feature note `docs/features/spec-review.md`.

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
launched, is refused (plan near limit), the surface has no launcher, or the
`spec_reviews` queue write fails (it runs after the ask's own transaction has
committed). The review row is then `skipped` with the reason ("launch failed: …",
"plan near limit", "no reviewer on this surface", "could not queue: …"; a queue
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
owner line of the conversation, the owner's answer texts / notes / comment bodies of an
ask (in the asks block or as a conversation ask-answer entry), an owner comment. The
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

## Changelog

- 2026-10-25 (spec review Plan 1): file created with SPECREVIEW-01, 02, 03.
- 2026-10-25 (Plan 1 final review fixes): SPECREVIEW-02 covers a failed queue write (queued after the ask's commit); SPECREVIEW-03 checks the speaker of the owner's words and stores `speaker` on every source.
