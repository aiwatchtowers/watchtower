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

**Observable:** Every signal still carries one of two classes. **Actionable** items demand a response and persist until handled. **Ambient** items are awareness-only and fade on their own. Triage (the `inbox.triage` AI call) may only **downgrade** a class (actionable → ambient), never upgrade one; a trigger-created item is never dropped outright even on an `ignore` verdict, it is at most demoted to ambient. Upgrades require explicit user action. Both classes still feed the composer (`inbox.compose`, see `docs/inventory/dashboard.md`) that clusters signals into situations. What changed is presentation only: the dashboard no longer shows two visual sections ("Needs action" expanded cards vs "FYI" compact rows) — it surfaces action/ambient signals through a single secretary-ranked situation feed instead, with the class informing rank/priority rather than which section an item lands in.

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
- `WatchtowerDesktop/Tests/Core/InboxLearnedRulesQueriesTests.swift::test_INBOX_05_list_rules_ordered_by_weight`

**Locked since:** 2026-04-27

## INBOX-06 — Manual rules outrank statistics

**Status:** Enforced

**Observable:** Any rule I author by hand in the "Learned" tab (`source='user_rule'`) is never overwritten by the automatic implicit learner. If I say "mute @bob," statistics across the next month do not silently undo me.

**Why locked:** Without this, the "Learned" tab is theatre — the user edits a rule, walks away, and the aggregator overrides them. Explicit user intent must beat statistical aggregates.

**Test guards:**
- `internal/inbox/learner_test.go::TestInbox06_UserRuleProtectedFromImplicitOverwrite`
- `WatchtowerDesktop/Tests/Core/InboxLearnedRulesQueriesTests.swift::test_INBOX_06_manual_rule_overrides_implicit`

**Locked since:** 2026-04-27

## INBOX-07 — AI failure does not lose state

**Status:** Enforced

**Observable:** When the secretary's triage AI call (`inbox.triage`) errors out or returns unparseable JSON, existing state is preserved untouched until a future cycle succeeds. No item is created, reclassified, or dropped for the untriaged messages, and the failure is reflected in the watermark (see INBOX-09). The feed never blanks out, items do not reshuffle, the user can keep working on whatever they were focused on. (The equivalent guarantee for the dashboard's compose/situation-card AI calls, which replaced the per-item secretary card stage this contract used to also cover, is DASH-02 in `docs/inventory/dashboard.md`.)

**Why locked:** Inbox is a "pulse" surface. A flapping AI call that periodically blanks the feed would teach the user to distrust the screen. Stability beats freshness when the alternative is chaos.

**Test guards:**
- `internal/inbox/triage_test.go::TestInbox07_InvalidJSONLeavesStateUntouched`
- `internal/inbox/pipeline_test.go::TestInbox07_FeedUntouchedOnTriageError`

**Locked since:** 2026-04-27 (extended to cards 2026-07-05, narrowed back to triage 2026-07-06 when per-item cards were retired, see changelog)

## INBOX-09 — Detection failure never advances the watermark

**Status:** Enforced

**Observable:** The inbox watermark (`inbox_last_processed_ts`) tracks how far detection *and* triage have scanned. When a detector pass fails (Slack sync error, a source detector returning an error), the watermark stays where it was — it never jumps forward on wall-clock time, regardless of how triage fared. The next cycle re-scans the same window, so a mention/DM that arrived during a failed pass is still surfaced once detection recovers. Nothing is silently skipped.

**Partial-advance rule:** When detection is clean but full-stream triage is capped (hit `MaxTriageMessages`) or fails partway through a chunked run, the watermark advances only to the timestamp of the **last fully-triaged message** — never past a message that was never sent to the AI or whose chunk errored. A muted candidate's timestamp may only push the watermark forward if every unmuted candidate at or before it was successfully triaged; a muted message past an untriaged/failed one does not smuggle the watermark forward.

**Why locked:** The watermark only ever moves forward, so any window it skips is lost forever. Advancing it on failure (by wall-clock time, or past an untriaged message) means a transient Slack/detector/triage error permanently drops every mention, DM, or stream signal in that gap — a silent data loss the user cannot detect or recover from. Freezing the watermark on failure, and capping partial advances at the last fully-processed message, trades a cheap re-scan for zero lost signals. A detector error always freezes the watermark even if triage made progress, because detectors and triage scan the same ts window — advancing over triage's progress would still skip whatever the failed detector never saw.

**Multi-account extension (2026-07-30):** `inbox_last_processed_ts` stays a single, workspace-wide cursor — Google multi-account did NOT fork it into one per account. The Gmail detector (`DetectGmailAccounts`) now iterates every connected `google_accounts` row and scans that account's own `gmail_messages` (queried scoped by `account_id`), but every account is checked against the same shared `sinceTime` cursor — one account erroring still freezes the whole workspace watermark like any other detector error, with no per-account carve-out. This is a scope extension of the existing detector-error rule, not a new watermark: `google_accounts.gmail_last_internal_date` (the Gmail API *sync* watermark gating how far `gmail.Syncer` has fetched) is a separate cursor entirely, unrelated to inbox detection. The Gmail inbox `channel_id` also changed shape: it is now `gmail:<accountID>:<threadID>` (previously a bare `<threadID>`), the same discriminator pattern IMAP already uses (`imap:<acct>:...`); the multi-account migration rewrote existing `inbox_items.channel_id` values plus the `channel:`-scoped mute rules and learned-rule references so nothing silently stopped matching.

**Multi-account extension (2026-07-31, Slack — same semantics):** `inbox_last_processed_ts` stays the single, workspace-wide detection cursor for Slack too; multi-Slack did NOT fork it per account. The Slack detector reads `messages` whose `channel_id`/`user_id` are now namespaced `"<accountID>:<rawSlackID>"` strings, so inbox detection inherits account-scoping for free — no special `channel_id` construction (unlike Gmail), no detector signature change, and still the same shared `sinceTime` cursor. Per-Slack-account sync progress lives in a separate cursor entirely — `slack_accounts.search_last_date` (the search-sync watermark, moved off the `workspace` singleton) — unrelated to inbox detection, exactly as `google_accounts.gmail_last_internal_date` is. **Own-message-exclusion widening (extension of the existing filter, not a new contract):** the inbox stream-candidate query already excluded the owner's own messages by a single Slack user id; it now excludes *every* connected account's owner id — `db.ListOwnerSlackUserIDs()` returns all non-empty namespaced `current_user_id`s and feeds `ListStreamCandidatesSince(ownerIDs, ...)`, so a message the owner sent in *any* connected Slack org is suppressed by that org's own `current_user_id` (a direct string compare, since both sides are stored `"<acct>:<Uxxx>"`). This is a per-account widening of the pre-existing single-owner exclusion, not a new behavior class (contrast the Gmail case, where own-message suppression was genuinely new). No contract number changes.

**Test guards:**
- `internal/inbox/pipeline_test.go::TestInbox09_WatermarkFrozenOnDetectorError`
- `internal/inbox/pipeline_test.go::TestInbox09_WatermarkFrozenOnTriageError`
- `internal/inbox/pipeline_test.go::TestInbox09_CappedTriageAdvancesWatermarkPartially`
- `internal/inbox/pipeline_test.go::TestInbox09_DetectorErrorFreezesEvenWhenTriageCapped`
- `internal/inbox/triage_test.go::TestTriage_MutedBeyondFailedChunkDoesNotAdvanceWatermark`

**Locked since:** 2026-07-05 (partial-advance rule added 2026-07-06, see changelog; multi-account detector scoping noted 2026-07-30 for Google and 2026-07-31 for Slack, same semantics)

## Changelog

- 2026-04-27: file created with 8 contracts (INBOX-01..08). Five are Enforced (01, 02, 05, 06, 07), two are Partial (03, 04), one is Aspirational (08). Tracked gaps recorded inline on Partial/Aspirational entries.
- 2026-04-28: INBOX-04 closed gap — explicit feedback now feeds into evidence pool via learner; never_show stays as one-click escape hatch (source='user_rule'). Migration v72 drops legacy source='explicit_feedback' rules.
- 2026-04-28: INBOX-08 removed by owner — anti re-spam was Aspirational only, never implemented. Decision: not part of the product's behavior set. Re-introduce only if owner asks.
- 2026-05-01: INBOX-02 extended to cover the new `target_due` trigger — closing the underlying target (status → done/dismissed) auto-resolves the inbox item. Migration 00002 adds `target_due` to `inbox_items.trigger_type` and `targets.notified_at`.
- 2026-07-05: INBOX-09 added (owner-approved, audit 2026-07-05 batch 2.3) — the full `Run` now advances `inbox_last_processed_ts` only after a clean detector pass; any detector error freezes the watermark so the skipped window is not lost. `detectAll` returns an aggregated error to gate the advance.
- 2026-07-06: secretary redesign (owner-approved, spec `docs/superpowers/specs/2026-07-05-inbox-secretary-redesign-design.md`) — INBOX-01/07 rewritten for triage+cards, INBOX-03 closed, pinned guards retired. Pinned selection (`pinned_selector.go`, the `inbox_items.pinned` column) is removed entirely, replaced by full-stream triage (`inbox.triage`, cheap tier) classifying every new trigger item plus ordinary channel traffic, and secretary cards (`inbox.card`, strong tier) generating why-it-matters/thread-digest/draft-reply write-ups for actionable items. INBOX-09 extended with the partial-advance rule for capped/partially-failed triage runs.
- 2026-07-06: secretary dashboard (owner-approved, spec `docs/superpowers/specs/2026-07-06-secretary-dashboard-design.md`) — INBOX-01's Observable reworded only: action/ambient classes still live on signals, still feed the composer, and triage still only downgrades (guard tests unchanged). The two visual sections ("Needs action"/"FYI") are replaced by the dashboard's single secretary-ranked situation feed — see `docs/inventory/dashboard.md` for the new DASH-01..03 contracts this introduces. Also: INBOX-07 narrowed back to triage only — the per-item secretary card stage (`inbox.card`, `card.go`/`card_test.go`) it used to also cover was retired by migration 00012 (dropped by an earlier commit on this branch, `feat(inbox): compose + situation-card phases replace per-item cards`), and the card-failure-isolation guarantee now lives on DASH-02 for situation cards. This is a stale-reference fix (the guard test files no longer existed), not a weakening of the contract.
- 2026-07-16 (memory Phase-4 dispute surface): the watchtower detector (`detectMemoryDisputes` in `watchtower_detector.go`) now also surfaces the memory pipeline's `dispute_pending` beliefs as ordinary `decision_made` trigger items (`channel_id="memory"`, `message_ts="dispute:<belief_id>"`), behind `memory.surfaces.disputes` (default false, ≤2 per cycle). Each flagged belief's flag is cleared in the SAME transaction that mints its item, so a dispute surfaces exactly once. INBOX-01 (never dropped/upgraded), INBOX-09 (watermark), and DASH-01/02 are structurally untouched — this is an ordinary detector item created before triage, so the standard pipeline (triage → compose → dashboard) owns it. The memory package only sets the flag (`memory_dispute_flags` side table); the inbox package, which legitimately owns `inbox_items`, reads and clears it — see `docs/inventory/memory.md` MEM-10. Guards: `TestWatchtowerDetector_Dispute*`.
- 2026-07-30 (Google multi-account, sub-project 1 of 3): INBOX-09 extended (doc-only, same semantics) — the Gmail detector scans per connected `google_accounts` row (`gmail_messages` filtered by `account_id`) but still shares the single `inbox_last_processed_ts` cursor with every other source; a per-account read scope is not a per-account watermark. Gmail's inbox `channel_id` changed from a bare `<threadID>` to `gmail:<accountID>:<threadID>` (the `imap:<acct>:...` precedent); the migration rewrote existing rows and mute/rule references. Own-message suppression (comparing a message's sender against its source account's own email, so mail the owner sent doesn't mint an inbox item) is NEW behavior shipped alongside this migration, NOT a per-account version of a pre-existing filter — pre-multi-account Gmail detection had no owner-sent-message filter at all (`gmail.account_email`, since retired, was used for identity resolution elsewhere, not detector suppression). Spec-mandated (design §4), owner-confirmed not scope creep — see the SDD ledger for Task 8. No contract number changes.
- 2026-07-31 (Slack multi-account, sub-project 2 of 3): INBOX-09 extended (doc-only, same semantics) — the Slack detector inherits per-account scoping for free because `messages.channel_id`/`user_id` are now namespaced `"<accountID>:<rawSlackID>"` strings (migration 00048); no special `channel_id` construction and no detector signature change, still the single shared `inbox_last_processed_ts` cursor. Per-Slack-account sync progress is a separate cursor (`slack_accounts.search_last_date`, moved off the `workspace` singleton), unrelated to inbox detection. Own-message exclusion is *widened* (not new, contrast the Gmail case): the stream-candidate query already excluded the owner's own Slack messages by one user id; it now excludes every connected account's owner id via `db.ListOwnerSlackUserIDs()` → `ListStreamCandidatesSince(ownerIDs, ...)`, a direct namespaced-string compare. Extension of an existing filter per [[feedback_inventory_no_duplicate_contracts]]; no contract number changes.
- 2026-08-08 (Ideas & Decisions Registry): the dormant `jira_comment_mention` trigger and its INBOX-02 auto-resolve went live. Migration 00050 adds a real `jira_comments` table (bounded per-account comment sync), so `DetectJira`'s comment-mention branch and `autoResolveJira` finally have data to read. Identity resolution is via `jira_user_map` (slack id → Atlassian account id): a Jira `[~mention]` embeds the ATLASSIAN id, not the Slack one, so an unmapped owner is a graceful no-op rather than a miss. The INBOX-02 fixtures were adapted to the real `jira_comments` schema and now write Jira Cloud's own dotted-millisecond timestamp format, exactly as the sync does — **assertions unchanged**. That fixture change exposed a real production bug in `autoResolveJira`: it string-compared `jira_comments.created_at` (Jira format) against `inbox_items.created_at` (RFC3339), where '.' sorts below 'Z', so a comment had to be a whole second newer to register at all and one in the same second never would. Both comparisons now go through `db.FormatJiraTime`/`db.ParseJiraTime`. No contract number changes.
  - **Owner decision needed — feature coupling:** the bounded Jira comment sync is wired only when `ideas.enabled = true` (`cmd/sync.go`'s `SetCommentSyncLimit`). With the ideas registry off, `jira_comments` stays empty, so this INBOX-02 path and the `jira_comment_mention` trigger are silently inert — an inbox behavior gated on an unrelated feature's switch. Flagged, not resolved: whether comment sync should have its own switch (or ride `inbox.enabled`) is the owner's call.
