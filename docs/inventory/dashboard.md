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

## Changelog

- 2026-07-06: file created with 3 contracts (DASH-01..03), all Enforced. Introduced by the secretary dashboard feature (spec `docs/superpowers/specs/2026-07-06-secretary-dashboard-design.md`), which composes inbox signals plus target/track updates into ranked `situations`, replacing the inbox's two-tier "Needs action"/"FYI" feed as the app's start screen. See `docs/inventory/inbox-pulse.md`'s 2026-07-06 changelog entry for how INBOX-01/07/09 relate to this new surface.
