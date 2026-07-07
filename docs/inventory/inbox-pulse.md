# Behavior Inventory — Inbox Pulse

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/inbox/` or
> `WatchtowerDesktop/Sources/Views/Inbox/`, read this file first. Any
> proposed change that would break a guard test or remove a contract
> must be raised as a question before touching code.

**Module:** `internal/inbox/` + `WatchtowerDesktop/Sources/Views/Inbox/`
**Last full audit:** 2026-07-06

## INBOX-01 — Two tiers: action vs awareness

**Status:** Enforced

**Observable:** Inbox shows two kinds of signals. **Actionable** ("Needs action") items demand a response and persist until handled. **Ambient** ("FYI") items are awareness-only and fade on their own. The UI distinguishes them visually — expanded cards vs compact rows. Triage (the `inbox.triage` AI call) may only **downgrade** a class (actionable → ambient), never upgrade one; a trigger-created item is never dropped outright even on an `ignore` verdict, it is at most demoted to ambient. Upgrades require explicit user action.

**Why locked:** Without this split, Inbox collapses into a single noisy feed and the "no inbox-zero pressure" promise dies.

**Test guards:**
- `internal/inbox/triage_test.go::TestInbox01_TriggerNeverIgnored`
- `internal/inbox/triage_test.go::TestInbox01_TriageNeverUpgrades`

**Locked since:** 2026-04-27

## INBOX-02 — Inbox understands what I've already answered

**Status:** Enforced

**Observable:** I reply in Slack/DM/thread, comment on a Jira issue, or RSVP a calendar invite — the corresponding inbox item disappears **without my click**. Inbox follows the conversation; I never close the same thing twice.

**Why locked:** This is the basic promise that makes Inbox lower-friction than native Slack/Jira/Calendar notifications. Break it and users stop trusting the feed and revert to the original sources.

**Test guards:**
- `internal/inbox/pipeline_test.go::TestInbox02_AutoResolveSlackOnUserReply`
- `internal/inbox/pipeline_test.go::TestInbox02_AutoResolveJiraOnUserComment`
- `internal/inbox/pipeline_test.go::TestInbox02_AutoResolveCalendarOnUserRSVP`
- `internal/db/targets_remind_test.go::TestInbox02_AutoResolveTargetOnClose`

**Locked since:** 2026-04-27 (target_due family added 2026-05-01)

## INBOX-03 — Surfaces signals that would have been buried in noise

**Status:** Enforced

**Observable:** If 200 messages flow past me in a day and one needed a reaction, Inbox surfaces it. Not "all mentions" — specifically the ones that look like signal in the surrounding volume. Noisy sources (deploy channels, dependabot, chatty Jira projects) do not crowd out high-signal ones.

**Why locked:** Without this, Inbox is just an alias for `@mentions` and adds nothing over native Slack notifications.

**Test guards:**
- `internal/inbox/e2e_test.go::TestInbox03_StreamSignalSurfaced`
- `internal/inbox/triage_test.go::TestTriage_HardMutedStreamCandidateSkipped`
- `internal/inbox/user_preferences_test.go::TestInbox03_UserPrefsRankedByRelevance`

**Locked since:** 2026-04-27 (gap closed 2026-07-06 by full-stream triage, see changelog)

## INBOX-04 — Inbox learns gradually, not by single click

**Status:** Enforced

**Observable:** A single 👎 does not silence a source forever — it is one signal in a pool. Muting / boosting decisions emerge from accumulated evidence (explicit feedback **plus** implicit dismissals, response times, recency). Behavior shifts smoothly over time, like Spotify recommendations, not like a toggle. The exception is the explicit "Never show me this" action, which is a deliberate one-click escape hatch and writes a `source='user_rule'` immediately.

**Why locked:** A single-click kill switch makes users either afraid to give feedback ("I might over-mute") or distrustful when feedback doesn't bite ("I clicked once and nothing changed"). Gradual accumulation is the only model that earns trust at both ends. The escape hatch is an exception kept for cases where the user *really* means it — and is visible in the Learned tab as a manual rule.

**Test guards:**
- `internal/inbox/learner_test.go::TestInbox04_GradualMuteFromAccumulatedDismissals`
- `internal/inbox/learner_test.go::TestInbox04_NoRuleBelowEvidenceThreshold`
- `internal/inbox/learner_test.go::TestInbox04_LearnerAggregatesExplicitWithImplicit`
- `internal/inbox/learner_test.go::TestInbox04_LearnerNoRuleBelowCombinedThreshold`
- `internal/inbox/learner_test.go::TestInbox04_LearnerPositiveBoostFromExplicit`
- `internal/inbox/learner_test.go::TestInbox04_LearnerNeverShowExcludedFromPool`
- `internal/inbox/feedback_test.go::TestInbox04_NeverShowStillInstantHardMute`
- `internal/inbox/feedback_test.go::TestInbox04_SourceNoiseDoesNotCreateRule`
- `internal/inbox/feedback_test.go::TestInbox04_WrongClassChangesItemButNotRule`
- `internal/inbox/feedback_test.go::TestInbox04_WrongPriorityDoesNotCreateRule`
- `internal/inbox/feedback_test.go::TestInbox04_PositiveFeedbackDoesNotCreateRule`
- `internal/db/schema_contracts_test.go::TestInbox04_NoLegacyExplicitFeedbackTable`

**Locked since:** 2026-04-28

## INBOX-05 — I can see and edit what Inbox has learned about me

**Status:** Enforced

**Observable:** The "Learned" tab inside Inbox shows the system's current model of me — mutes, boosts, manual rules — with weight, source ("learned from 12 dismissals" / "I added this manually"), and an inline remove/edit. I can add a rule, remove a rule, change a weight; changes persist and reflect in subsequent pinned/feed cycles.

**Why locked:** Without visibility, the learning system is a black box and trust collapses. Without editability, users cannot recover from misclassifications — feedback becomes a one-way street.

**Test guards:**
- `WatchtowerDesktop/Tests/InboxLearnedRulesViewModelTests.swift::test_INBOX_05_add_manual_rule`
- `WatchtowerDesktop/Tests/InboxLearnedRulesViewModelTests.swift::test_INBOX_05_remove_rule`
- `WatchtowerDesktop/Tests/InboxLearnedRulesQueriesTests.swift::test_INBOX_05_list_rules_ordered_by_weight`

**Locked since:** 2026-04-27

## INBOX-06 — Manual rules outrank statistics

**Status:** Enforced

**Observable:** Any rule I author by hand in the "Learned" tab (`source='user_rule'`) is never overwritten by the automatic implicit learner. If I say "mute @bob," statistics across the next month do not silently undo me.

**Why locked:** Without this, the "Learned" tab is theatre — the user edits a rule, walks away, and the aggregator overrides them. Explicit user intent must beat statistical aggregates.

**Test guards:**
- `internal/inbox/learner_test.go::TestInbox06_UserRuleProtectedFromImplicitOverwrite`
- `WatchtowerDesktop/Tests/InboxLearnedRulesQueriesTests.swift::test_INBOX_06_manual_rule_overrides_implicit`

**Locked since:** 2026-04-27

## INBOX-07 — AI failure does not lose state

**Status:** Enforced

**Observable:** When either secretary AI call — triage (`inbox.triage`) or cards (`inbox.card`) — errors out or returns unparseable JSON, existing state is preserved untouched until a future cycle succeeds. A triage failure leaves the feed as-is: no item is created, reclassified, or dropped for the untriaged messages, and the failure is reflected in the watermark (see INBOX-09). A per-item card failure marks that item `card_status='failed'` and keeps its raw snippet/reason visible; the pipeline moves on to the next item and retries the failed one next cycle. The feed never blanks out, items do not reshuffle, the user can keep working on whatever they were focused on.

**Why locked:** Inbox is a "pulse" surface. A flapping AI call that periodically blanks the feed would teach the user to distrust the screen. Stability beats freshness when the alternative is chaos.

**Test guards:**
- `internal/inbox/triage_test.go::TestInbox07_InvalidJSONLeavesStateUntouched`
- `internal/inbox/pipeline_test.go::TestInbox07_FeedUntouchedOnTriageError`
- `internal/inbox/card_test.go::TestInbox07_CardFailureMarksFailedAndContinues`
- `internal/inbox/card_test.go::TestRunCards_InvalidJSONMarksFailed`

**Locked since:** 2026-04-27 (extended to triage + cards 2026-07-06, see changelog)

## INBOX-09 — Detection failure never advances the watermark

**Status:** Enforced

**Observable:** The inbox watermark (`inbox_last_processed_ts`) tracks how far detection *and* triage have scanned. When a detector pass fails (Slack sync error, a source detector returning an error), the watermark stays where it was — it never jumps forward on wall-clock time, regardless of how triage fared. The next cycle re-scans the same window, so a mention/DM that arrived during a failed pass is still surfaced once detection recovers. Nothing is silently skipped.

**Partial-advance rule:** When detection is clean but full-stream triage is capped (hit `MaxTriageMessages`) or fails partway through a chunked run, the watermark advances only to the timestamp of the **last fully-triaged message** — never past a message that was never sent to the AI or whose chunk errored. A muted candidate's timestamp may only push the watermark forward if every unmuted candidate at or before it was successfully triaged; a muted message past an untriaged/failed one does not smuggle the watermark forward.

**Why locked:** The watermark only ever moves forward, so any window it skips is lost forever. Advancing it on failure (by wall-clock time, or past an untriaged message) means a transient Slack/detector/triage error permanently drops every mention, DM, or stream signal in that gap — a silent data loss the user cannot detect or recover from. Freezing the watermark on failure, and capping partial advances at the last fully-processed message, trades a cheap re-scan for zero lost signals. A detector error always freezes the watermark even if triage made progress, because detectors and triage scan the same ts window — advancing over triage's progress would still skip whatever the failed detector never saw.

**Test guards:**
- `internal/inbox/pipeline_test.go::TestInbox09_WatermarkFrozenOnDetectorError`
- `internal/inbox/pipeline_test.go::TestInbox09_WatermarkFrozenOnTriageError`
- `internal/inbox/pipeline_test.go::TestInbox09_CappedTriageAdvancesWatermarkPartially`
- `internal/inbox/pipeline_test.go::TestInbox09_DetectorErrorFreezesEvenWhenTriageCapped`
- `internal/inbox/triage_test.go::TestTriage_MutedBeyondFailedChunkDoesNotAdvanceWatermark`

**Locked since:** 2026-07-05 (partial-advance rule added 2026-07-06, see changelog)

## Changelog

- 2026-04-27: file created with 8 contracts (INBOX-01..08). Five are Enforced (01, 02, 05, 06, 07), two are Partial (03, 04), one is Aspirational (08). Tracked gaps recorded inline on Partial/Aspirational entries.
- 2026-04-28: INBOX-04 closed gap — explicit feedback now feeds into evidence pool via learner; never_show stays as one-click escape hatch (source='user_rule'). Migration v72 drops legacy source='explicit_feedback' rules.
- 2026-04-28: INBOX-08 removed by owner — anti re-spam was Aspirational only, never implemented. Decision: not part of the product's behavior set. Re-introduce only if owner asks.
- 2026-05-01: INBOX-02 extended to cover the new `target_due` trigger — closing the underlying target (status → done/dismissed) auto-resolves the inbox item. Migration 00002 adds `target_due` to `inbox_items.trigger_type` and `targets.notified_at`.
- 2026-07-05: INBOX-09 added (owner-approved, audit 2026-07-05 batch 2.3) — the full `Run` now advances `inbox_last_processed_ts` only after a clean detector pass; any detector error freezes the watermark so the skipped window is not lost. `detectAll` returns an aggregated error to gate the advance.
- 2026-07-06: secretary redesign (owner-approved, spec `docs/superpowers/specs/2026-07-05-inbox-secretary-redesign-design.md`) — INBOX-01/07 rewritten for triage+cards, INBOX-03 closed, pinned guards retired. Pinned selection (`pinned_selector.go`, the `inbox_items.pinned` column) is removed entirely, replaced by full-stream triage (`inbox.triage`, cheap tier) classifying every new trigger item plus ordinary channel traffic, and secretary cards (`inbox.card`, strong tier) generating why-it-matters/thread-digest/draft-reply write-ups for actionable items. INBOX-09 extended with the partial-advance rule for capped/partially-failed triage runs.
