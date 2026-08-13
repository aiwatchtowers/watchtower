# Behavior Inventory — Catch-up

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/catchup/`, the catch-up parts of
> `internal/db/` (`MarkDigestRead` decision cascade, `catchup_*` stores), or
> `WatchtowerDesktop/Sources/{Views,ViewModels,Database/Queries}/CatchUp*`,
> read this file first. Any proposed change that would break a guard test or
> remove a contract must be raised as a question before touching code.

**Module:** `internal/catchup/` + `WatchtowerDesktop/Sources/.../CatchUp*` + the catch-up slices of `internal/db/`
**Last full audit:** 2026-06-22

**What it is.** Catch-up is an on-demand "what did I miss" review. It gathers the operator's currently-**unread** items across exactly four sources — digests, tracks, inbox, briefings — extracts cross-source **themes** one per round in a sequential peel-off pass (light model; claimed items leave the pool, the loop stops when the model returns `{"done":true}`, removing the old 3–8 ceiling), then writes each theme a narrative (per-theme expand pass dispatched concurrently as themes are peeled). Pool items the model judges noise on a clean exit are marked read; on an error or safety-cap exit the leftover stays unread. The operator reviews themes one at a time; per-theme 👍/👎 + free-text comment trains every upstream pipeline via learned rules. There is no "decisions" source area — decisions ride along inside their parent digest.

**Two implementations, one behavior.** The acknowledge/feedback logic exists **twice**: Go (`Pipeline.Acknowledge`, used by CLI `catchup ack`) and Swift (`CatchUpQueries.acknowledge`, used by the Desktop "Done" button, which writes the shared DB directly and never calls Go). Every contract below that mentions acknowledge must hold on **both** paths; guard lists pair the Go and Swift tests deliberately.

## CATCHUP-01 — Review once via catch-up, stay read everywhere

**Status:** Enforced

**Observable:** When I mark a catch-up theme reviewed ("Done"), every source item the theme captured is marked read in its own surface — and I never see it resurface as unread there. Specifically the cascade covers **exactly the theme's snapshot refs** (digests, tracks, inbox, briefings) and, for each referenced digest, **its decisions too** (so the Decisions feed — which counts unread as `total − COUNT(decision_reads)` — does not strand decisions I already saw via catch-up). The cascade is best-effort and idempotent: re-acking never double-counts, never duplicates `decision_reads` rows, and items that arrived after the snapshot are left untouched. The session's `reviewed_count` increments only on the first transition into `reviewed`.

**Why locked:** Catch-up's entire promise is "see it once here, you're done." If acknowledging a theme left its digests/decisions/tracks/inbox unread in their own feeds, the operator would have to re-clear everything twice and the badges would lie — the surface stops being a catch-up and becomes extra work. The decisions half of the cascade is the easy one to forget because decisions are not a gathered source area; this contract pins it.

**Test guards:**
- `internal/catchup/pipeline_test.go::TestCatchup14_AcknowledgeMarksDigestDecisionsRead`
- `internal/catchup/pipeline_test.go::TestCatchup24_AcknowledgeReviewedCountIsIdempotent`
- `internal/db/digests_test.go::TestMarkDigestRead_CascadeDecisions`
- `internal/db/digests_test.go::TestMarkDigestRead_NoDecisionsIsNoop`
- `WatchtowerDesktop/Tests/Core/CatchUpQueriesTests.swift::testAcknowledgeCascadesMarkReadAndFlipsReviewState`
- `WatchtowerDesktop/Tests/Core/CatchUpQueriesTests.swift::testAcknowledgeMarksDigestDecisionsRead`
- `WatchtowerDesktop/Tests/Core/CatchUpQueriesTests.swift::testAcknowledgeReviewedCountIsIdempotent`

**Locked since:** 2026-06-22

## CATCHUP-02 — Catch-up speaks my configured language

**Status:** Enforced

**Observable:** Every operator-facing catch-up AI call — theme titles (peel), narratives + suggested actions (expand) — comes back in the workspace's configured `digest.language` (default Russian), regardless of the language of the underlying Slack/Jira content. The system prompt always carries a `prompts.Directive(...)`; it is never omitted, which would let the model silently default to English. The guard asserts the **peel** prompt specifically carries the directive.

**Why locked:** The operator picked a response language once; a surface that randomly answers in English breaks the product's "reads in my language" promise and is jarring exactly when the source material is mixed-language. This regressed once (titles RU, narratives EN) precisely because the prompt constants shipped without a directive.

**Test guards:**
- `internal/catchup/pipeline_test.go::TestCatchup13_PromptsCarryLanguageDirective`

**Locked since:** 2026-06-22

## CATCHUP-03 — One bad theme never sinks the run

**Status:** Enforced

**Observable:** The per-theme expand pass fans out independently. If one theme's AI call errors or returns unparseable JSON, that row is marked `gen_state='failed'` and logged, and **every other theme still expands and persists**. A single failure never aborts the batch or blanks the session; the CLI/UI surface the failed count by reading `gen_state`.

**Why locked:** Expand is N independent AI calls; with no isolation a single flaky call would throw away the whole catch-up the operator was waiting on. Partial results beat all-or-nothing on a review surface.

**Test guards:**
- `internal/catchup/pipeline_test.go::TestCatchup21_PerThemeExpandFailureDoesNotFailRun`

**Locked since:** 2026-06-22

## Changelog

- 2026-06-25: outline pass replaced by a sequential peel-off loop (one theme per round until the model returns `{"done":true}`); removed the 3–8 theme ceiling and raised gather caps (150/80/120/20). New source tag `catchup.peel` routed to the light model tier on both providers. CATCHUP-02 guard extended to cover the new `peelSystemPrompt`. New behaviour: pool items the model judges noise on a clean/done exit are marked read (reusing the `MarkXRead` primitives, so the digest-decision cascade still holds); on an error/safety-cap exit the leftover stays unread. `Acknowledge` refactored to share a `markAreaRead` helper — behaviour unchanged. Contracts CATCHUP-01/03 unchanged.
- 2026-06-22: file created with 3 contracts (CATCHUP-01..03), all Enforced. CATCHUP-01 added alongside the fix that made acknowledge cascade digest **decisions** read on both the Go (`MarkDigestRead`) and Swift (`CatchUpQueries.acknowledge`) paths — previously digests were marked read but their decisions stayed stuck in the Decisions feed's unread count. CATCHUP-02 records the language-directive invariant after the outline/expand prompts shipped without one and generated English on a Russian workspace.
