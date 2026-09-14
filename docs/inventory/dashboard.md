# Behavior Inventory — Dashboard (RETIRED 2026-09-14)

> **This file is a tombstone.** Nothing in it is in force. It is kept so the
> DASH-01..07 ids stay resolvable from code comments, commit messages and other
> inventory files, and so the historical record of what each contract protected
> survives the demolition.

**Retired 2026-09-14 by the inbox demolition** (owner-approved, spec
`docs/superpowers/specs/2026-09-14-inbox-demolition-design.md`, resolving audit
decision 3): the situations composer (`inbox.compose`), situation cards
(`inbox.situation_card`), situation feedback (`inbox.situation_learn`) and the
feed publisher (`internal/feed`, `feed_items`/`feed_state`) were removed rather
than gated — the audit's lesson is that a dark gate over dead UI is silent loss,
not a decision. The Desktop Dashboard view (`Views/Dashboard/`, `InboxFeedView`)
has had zero call sites since Wave 2 and is deleted in the demolition's **Desktop
half**, the second of the two stacked PRs. The `situations` and
`situation_signals` tables **remain** as read-only history: migration 00070 froze
every `open` situation to `stale`, and no writer is left in the codebase —
`internal/db/situations.go` keeps one reader (`ListSituationSignals`), with
`ConvertedSituationIDs` (memory's conversion cross-link) living in
`internal/db/memory.go`. The former `GetSituation`/`ListSituations` readers had
no production callers and were deleted in the final-review fix wave. The
`converted_target_id`/`converted_track_id` links plus
`targets.source_type='situation'` rows stay valid so a target or track created
from a situation can still point back at its origin. The guard tests behind
these contracts were deleted **together with the behaviour they guarded** — the
approved demolition, not a weakening; none was relaxed, renamed, or split.

The jobs the Dashboard used to do now live elsewhere: "what happened while I was
away" is **Catch-Up** (`docs/inventory/catchup.md`), "what is waiting on my
decision" is the **inbox action strip** (`docs/inventory/reaction-commands.md`,
STRIP-01..03), and the mechanical detection that fed all of it is
`docs/inventory/inbox-pulse.md` (INBOX-02/05/09 live; 01/03/04/06/07 retired the
same day).

## Historical record — what each contract protected

| Id | What it protected |
|---|---|
| **DASH-01** | Situations merge, not duplicate — new signals related to an open situation were merged into it (rerank + card invalidation) instead of forking a second row for the same story. Guarded by TestDash01_MergeIntoOpenSituation in internal/inbox/compose_test.go. |
| **DASH-02** | AI failure never loses the feed — a failed or unparseable `inbox.compose`/`inbox.situation_card` call left every situation, rank and card untouched and did not advance the compose watermark; a single bad card marked that one situation `card_status='failed'` and the cycle continued. Guarded by the TestDash02_* family in internal/inbox/compose_test.go and internal/inbox/situation_card_test.go, plus the end-to-end TestDash_E2E_SignalToSituation in internal/inbox/e2e_test.go. |
| **DASH-03** | Conversion records links both ways — converting a situation into a Target or Track set `status='converted'` and stamped `converted_target_id`/`converted_track_id`, never deleting the row. Guarded by TestMarkSituationConverted in internal/db/situations_test.go and the test_DASH_03_* pair in WatchtowerDesktop/Tests/DashboardViewModelTests.swift. **This is the one clause with a live remainder:** the stamped links and the frozen rows they point at still exist and are still readable, they are simply never written again. |
| **DASH-04** | Comment-less feedback never invoked the AI interpreter — a bare 👍/👎 on a situation derived rules locally on both the Desktop and CLI paths; only a non-empty comment ran `inbox.situation_learn`. Guarded by TestDash04_CommentlessFeedbackNeverInvokesInterpreter in internal/inbox/situation_feedback_test.go and testSubmitFeedbackWithoutCommentDoesNotInvokeCLI in WatchtowerDesktop/Tests/DashboardViewModelTests.swift. |
| **DASH-05** | Feed publisher was additive and state-preserving — re-publishing never deleted a `feed_items` row nor reset `hidden_at`/`seen_at`. Guarded by TestDash05_RepublishPreservesUserStateAndHistory in internal/feed/publish_test.go. |
| **DASH-06** | Feed publish was AI-free and non-blocking — `feed.Publish` made no AI call, one failing source never blocked the others, and a feed failure never touched the inbox watermark. Guarded by TestDash06_SourceFailureDoesNotBlockOthers in internal/feed/publish_test.go. |
| **DASH-07** | Resolution was suggested, never automatic — the composer's `suggest_resolve` op could only set `situations.suggested_resolution`, never `status`; a merge cleared a stale suggestion unless re-suggested, a bare rerank left it intact. Guarded by the TestDash07_* family in internal/inbox/compose_test.go. |

## Changelog

- 2026-09-14: **file retired wholesale.** DASH-01..07 are no longer in force; the body above is a tombstone. See the inbox-demolition spec for the decision and `docs/inventory/inbox-pulse.md`'s 2026-09-14 entry for the module-level detail.
- 2026-08-19: persona merge (owner decision 2026-08-19): the two-persona concept (secretary/assistant) is collapsed into a single **assistant** — wording-only here; no contract semantics, guard tests, or gates changed. Historical changelog entries keep the old word. See "The assistant & chat contracts" in `docs/review/review-rules.md`.
- 2026-07-06: file created with 3 contracts (DASH-01..03), all Enforced. Introduced by the secretary dashboard feature (spec `docs/superpowers/specs/2026-07-06-secretary-dashboard-design.md`), which composes inbox signals plus target/track updates into ranked `situations`, replacing the inbox's two-tier "Needs action"/"FYI" feed as the app's start screen. See `docs/inventory/inbox-pulse.md`'s 2026-07-06 changelog entry for how INBOX-01/07/09 relate to this new surface.
- 2026-07-09: added DASH-05/06 (feed publisher contracts). Introduced by the feed dashboard feature (spec `docs/superpowers/specs/2026-07-09-feed-dashboard-design.md`), which turns the Dashboard into a chronological social-wall feed (`feed_items` index) mixing situations with meetings, briefings, recaps, and day plans.
- 2026-07-09: added DASH-07 (suggested resolution). Introduced by the thread-follow + suggested-resolution feature (spec docs/superpowers/specs/2026-07-09-resolution-suggestion-design.md), together with the thread-fold composed_at reset that keeps situations live.
