# Behavior Inventory — Secretary Dashboard

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/inbox/` (compose/situation-card
> stages), `internal/db/situations.go`, or
> `WatchtowerDesktop/Sources/Views/Dashboard/`, read this file first. Any
> proposed change that would break a guard test or remove a contract
> must be raised as a question before touching code.

**Module:** `internal/inbox/` (compose + situation-card stages) + `internal/db/situations.go` + `WatchtowerDesktop/Sources/Views/Dashboard/`
**Last full audit:** 2026-07-06

## DASH-01 — Situations merge, not duplicate

**Status:** Enforced

**Observable:** When new signals relate to an existing open situation, the composer (`inbox.compose`) merges them into that situation instead of creating a second one — the situation gains the new signal(s), its rank/reason can be updated ("rerank"), and its card is invalidated (`card_status` reset to `none` so a fresh card regenerates next cycle). The dashboard's ranked feed never shows two rows for the same ongoing story.

**Why locked:** Without merge-not-duplicate, one ongoing story (e.g. "release X blocked") forks into multiple situations as new messages arrive, cluttering the ranked feed with near-duplicate entries — the "one narrative unit per situation" premise the whole dashboard is built on breaks.

**Test guards:**
- `internal/inbox/compose_test.go::TestDash01_MergeIntoOpenSituation`

**Locked since:** 2026-07-06

## DASH-02 — AI failure never loses the feed

**Status:** Enforced

**Observable:** When either dashboard AI call — the composer (`inbox.compose`) or situation cards (`inbox.situation_card`) — errors out or returns unparseable JSON, existing situations, their ranks, and their cards are left untouched: no signal is marked composed, no situation is created/merged/reranked, and the compose watermark does not advance. A per-situation card failure marks that one situation `card_status='failed'` (shown in the UI as "Context unavailable — will retry") and the pipeline moves on to the next situation — one bad card does not block cards for the rest of the cycle. Dashboard-phase failures never affect the inbox watermark (`inbox_last_processed_ts`, see INBOX-09 in `inbox-pulse.md`) — compose/cards run after triage has already committed.

**Why locked:** The dashboard replaces the inbox's two-tier feed as the primary surface; if a flaky compose or card call could blank or corrupt open situations, the same "stability beats freshness" promise INBOX-07 protects for per-item cards would be missing for the ranked feed that replaced it.

**Test guards:**
- `internal/inbox/compose_test.go::TestDash02_AIFailureTouchesNothing`
- `internal/inbox/compose_test.go::TestDash02_InvalidJSONTouchesNothing`
- `internal/inbox/compose_test.go::TestDash02_PartialApplyRollsBackEverything`
- `internal/inbox/situation_card_test.go::TestDash02_CardFailureMarksFailedAndContinues`
- `internal/inbox/e2e_test.go::TestDash_E2E_SignalToSituation` (end-to-end happy path: triage → compose → situation-card in one clean `Run`, the baseline this contract protects against regressing)

**Locked since:** 2026-07-06

## DASH-03 — Conversion records links both ways

**Status:** Enforced

**Observable:** Converting a situation into a Target or Track (the "Target"/"Track" buttons on a dashboard card) sets the situation's `status` to `converted` and stamps `converted_target_id` and/or `converted_track_id` with the new record's id. The situation drops out of the open dashboard feed (and out of `openCount`), but its row — title, summary, why-it-matters, chronology, and its linked `situation_signals` — is never deleted, so its history stays reachable by id after conversion; conversion is a link, not a delete.

**Why locked:** "Create target"/"Create track" is meant to graduate a situation into a trackable unit, not archive it into a black hole. Losing the back-link (or deleting the row) would make it impossible to answer "what situation did this target/track come from," and would silently discard the summary/chronology the secretary already generated.

**Test guards:**
- `internal/db/situations_test.go::TestMarkSituationConverted`
- `WatchtowerDesktop/Tests/DashboardViewModelTests.swift::test_DASH_03_conversionRecordsLinks`
- `WatchtowerDesktop/Tests/DashboardViewModelTests.swift::test_DASH_03_conversionRecordsTrackLink`

**Locked since:** 2026-07-06

## DASH-04 — Comment-less feedback never invokes the AI interpreter

**Status:** Enforced

**Observable:** 👍/👎 on a situation without a comment stays local: the Desktop writes rules directly (👎 → `source_mute` user_rule per member-signal channel; 👍 → no-op) and the `watchtower inbox feedback` CLI mirrors the same derivation — neither path makes an AI call. Only a non-empty comment runs the `inbox.situation_learn` learning interpreter, and every rule it derives lands as `source='user_rule'` (protected from implicit overwrite, INBOX-05).

**Why locked:** A bare thumb is a one-bit signal; silently spending an AI call (and potentially minutes of CLI latency) on it would make the cheapest feedback gesture slow and expensive, and rules invented from a bare thumb would be guesses. The interpreter runs only when the user actually said something interpretable.

**Test guards:**
- `internal/inbox/situation_feedback_test.go::TestDash04_CommentlessFeedbackNeverInvokesInterpreter`
- `WatchtowerDesktop/Tests/DashboardViewModelTests.swift::testSubmitFeedbackWithoutCommentDoesNotInvokeCLI`

**Locked since:** 2026-07-07

## DASH-05 — Feed publisher is additive and state-preserving

**Status:** Enforced

**Observable:** The feed publisher (`internal/feed`, `feed_items` index) never deletes feed rows and never resets user state (`hidden_at`, `seen_at`) when re-upserting an item. A situation that closes or converts drops out of the publisher's SELECT but its feed row stays — the wall keeps history; hiding is a user action recorded in `hidden_at`, not a deletion.

**Why locked:** The feed is the app's start screen and doubles as the day's history. If a publish cycle could delete rows or clear hide/seen marks, a routine daemon cycle would silently rewrite what the user already read or hid — the same "stability beats freshness" promise DASH-02 makes for situation content, extended to feed state.

**Test guards:**
- `internal/feed/publish_test.go::TestDash05_RepublishPreservesUserStateAndHistory`

**Locked since:** 2026-07-09

## DASH-06 — Feed publish is AI-free and non-blocking

**Status:** Enforced

**Observable:** `feed.Publish` makes no AI calls (pure SQL upserts; `feed.Pipeline` holds no generator). One failing source (e.g. a missing/corrupt source table) is logged and reported while every other source still publishes, and a feed failure never fails the daemon cycle nor touches the inbox pipeline or its watermarks (INBOX-09) — the publisher runs entirely outside `inbox.Run`.

**Why locked:** The feed indexes content other pipelines already paid AI calls to produce; re-spending model budget to move pointers would be waste, and a flaky feed phase must not be able to block triage/compose or freeze inbox watermarks.

**Test guards:**
- `internal/feed/publish_test.go::TestDash06_SourceFailureDoesNotBlockOthers`

**Locked since:** 2026-07-09

## DASH-07 — Resolution is suggested, never automatic

**Status:** Enforced

**Observable:** The composer's `suggest_resolve` op may only set `situations.suggested_resolution` (a reason string shown in the UI); it never changes `status`. Every transition to done/dismissed remains a user action (or the pre-existing signals-resolved auto-close driven by the user's own replies). A merge folding new material into a situation clears a stale suggestion unless the same pass re-suggests; a bare rerank leaves it intact. Hallucinated ids and empty reasons are skipped like any malformed op, and the whole apply stays inside the DASH-02 transaction.

**Why locked:** "The secretary marks, the user closes" is the trust boundary for third-party closures: a false auto-close would silently bury a live issue, while a stale suggestion surviving fresh activity would misrepresent the secretary's current judgment.

**Test guards:**
- `internal/inbox/compose_test.go::TestDash07_SuggestResolveSetsMarkNeverStatus`
- `internal/inbox/compose_test.go::TestDash07_MergeWithoutResuggestClearsStaleMark`
- `internal/inbox/compose_test.go::TestDash07_RerankAloneKeepsMark`
- `internal/inbox/compose_test.go::TestDash07_SuggestResolveSkipsHallucinatedAndEmptyReason`

**Locked since:** 2026-07-09

## Changelog

- 2026-07-06: file created with 3 contracts (DASH-01..03), all Enforced. Introduced by the secretary dashboard feature (spec `docs/superpowers/specs/2026-07-06-secretary-dashboard-design.md`), which composes inbox signals plus target/track updates into ranked `situations`, replacing the inbox's two-tier "Needs action"/"FYI" feed as the app's start screen. See `docs/inventory/inbox-pulse.md`'s 2026-07-06 changelog entry for how INBOX-01/07/09 relate to this new surface.
- 2026-07-09: added DASH-05/06 (feed publisher contracts). Introduced by the feed dashboard feature (spec `docs/superpowers/specs/2026-07-09-feed-dashboard-design.md`), which turns the Dashboard into a chronological social-wall feed (`feed_items` index) mixing situations with meetings, briefings, recaps, and day plans.
- 2026-07-09: added DASH-07 (suggested resolution). Introduced by the thread-follow + suggested-resolution feature (spec docs/superpowers/specs/2026-07-09-resolution-suggestion-design.md), together with the thread-fold composed_at reset that keeps situations live.
