# Inbox demolition — the inbox becomes Catch-Up's silent feeder

**Date:** 2026-09-14
**Status:** design, owner-approved in session (sections 1–4 explicitly; 5–7 written with the defaults stated inline)
**Resolves:** audit decision 3 (`docs/audit/2026-09-13-feature-audit/README.md`), findings H1/H2/M4/L1/L4 of `inbox-strip-catchup.md`, and §10 of the Wave 2 spec (`2026-09-06-reaction-commands-wave2-inbox-action-strip-design.md`), which deferred exactly this demolition.

---

## 1. Decision

The owner answered the parked product question in one sitting:

| Job the "Inbox" once did | Owner's verdict | Consequence |
|---|---|---|
| (1) "Addressed to me" — mentions/DMs/replies/mail as a screen | Not needed; Slack and Gmail already do this | No per-item inbox screen. The *detection* survives only because Catch-Up reads it. |
| (2) "What is going on that matters" — AI triage of the stream, situations, situation cards | Not needed; was never fed (empty `secretary_profile`, 0 `inbox_feedback` rows) and duplicates Digests / Tracks / Catch-Up | Deleted, together with its data writers and its dead Desktop surfaces. |
| (3) "Awaiting my decision" — agent proposals + reminders (the action strip) | Keep | Unchanged. It is what the sidebar "Inbox" tab already shows. |
| Catch-Up — "I was away, catch me up fast" | **Valued** | Stays the customer. Its `needs_you` area keeps reading `inbox_items`. |

So `internal/inbox` shrinks to **mechanical detection + auto-resolve**, with zero AI calls, and everything that *thought* is removed rather than gated — the audit's lesson is that a dark gate over dead UI is silent loss, not a decision.

Live numbers that framed the call (workspace `whitebit`, 7 days to 2026-09-14): `phaseInbox` ran 86 times, 1.43 M tokens (second only to digests), ~62 s per cycle; 2 873 pending `inbox_items` nobody could see (1 838 older than 30 days, 1 611 of them triage-minted `stream` rows); situations 26 open / 487 stale / 73 done, none minted since 2026-09-06; Catch-Up had three recaps stuck in `building` since 2026-09-11 (a separate bug, not this spec).

## 2. Scope

**In:** the Go pipeline cut, the data migration, the dead Desktop code, the memory/MCP/dev-pack readers of the frozen tables, config + Feature Manager + inventory/doc updates.

**Out (deliberately):** the Catch-Up `building` hang (own fix, own PR); the `reaction` auto-resolve one-token bug (M3, still an Enforced-INBOX-02 owner call); Catch-Up's visibility being tied to `slack-digests` (L3); strip card rendering (M1/M2); re-feeding Memory's interaction ingest from Catch-Up 👍/👎 (§5.3 flags it).

---

## 3. Go backend

### 3.1 `internal/inbox` — what stays

| File | Role after this spec |
|---|---|
| `pipeline.go` | `Run`: dedup → `detectAll` → `autoResolveByRules` → `runArchiveAndUnsnooze` (minus `UnsnoozeExpiredSituations`) → watermark. `decideWatermark` loses its triage arms: a detector error freezes `inbox_last_processed_ts`, otherwise it advances (INBOX-09 keeps its meaning). `RunFastDetection` is deleted. |
| `calendar_detector.go`, `gmail_detector.go`, `imap_detector.go`, `jira_detector.go`, the Slack trigger detection inside `pipeline.go` | Unchanged. |
| `watchtower_detector.go` | Keeps `briefing_ready`; the `decision_made` / dispute branch is deleted (§5.3). |
| `classifier.go` | `DefaultItemClass` — every trigger item is `actionable`/`medium`; with triage gone this is the only class writer. |
| `backfill.go` | Unchanged (`inbox backfill-mentions`). |

Zero `Generate` calls remain in the package; the `TestTierForSource_EveryGenerateCallIsTagged` scan simply sees fewer sites.

### 3.2 `internal/inbox` — what goes

`triage.go`, `learner.go` (`RunImplicitLearner` learned from dismissals in a UI that no longer exists), `compose.go`, `situation_card.go`, `situation_feedback.go`, `feedback.go` (`SubmitFeedback` has no non-test caller), `brief.go` + `user_preferences.go` (existed only to build the triage/compose prompts), and every test file paired with them. `internal/feed` is deleted whole (it published `feed_items` for the dead Dashboard timeline).

`style_sample.go` **moves, not dies**: `workspace.style_profile` is read by `internal/meeting/followup.go`, so the generator relocates to `cmd/profile.go` as `watchtower profile style-sample` (was `inbox style-sample`); the prompt id `inbox.style_sample` is kept as a stable identifier (the `secretary_profile` precedent).

### 3.3 Daemon

- `phaseFastInbox` deleted — its purpose was "surface DMs in the UI immediately"; there is no such UI. `d.inboxPipe.RunFastDetection` goes with it.
- `phaseInbox` stays, gated by `inbox.enabled`, still wrapped in `trackedPipelineRun("inbox", …)` so it shows in Pipeline Progress; it now costs seconds and no tokens.
- `phaseUnsnooze` (`UnsnoozeExpiredInboxItems` + `NotifyDueTargets`) unchanged.
- `phaseFeed` and `SetFeedPipeline` deleted.

### 3.4 Consumers of `inbox_items` (all untouched in code)

Catch-Up `ListCatchupInbox` (`needs_you`), briefing `GetInboxItemsForBriefing`, meeting prep `GetInboxItems` (attendee context), custom tracks `GetScanActivity*`, Slack sync's pending-item reaction refresh, channel stats, `NotifyDueTargets` (writer), the target-close cascade (writer, INBOX-02). What changes is only what they see: no more `stream` rows, no AI-assigned `priority`/`ai_reason` — trigger rows keep their defaults.

One bug folded in because it is in the same query family: `GetInboxItemsForBriefing` filters `status='pending'` but not `archived_at IS NULL`, so the briefing's top-20 includes actionable rows `ArchiveStaleActionable` retired 14+ days ago. Add the predicate (wave 2 already did this for `GetInboxItems`).

### 3.5 CLI

`watchtower inbox`: keep `list`/`show`/`resolve`/`dismiss`/`snooze`/`task`/`generate`/`backfill-mentions`; delete `feedback <situation-id>`; `style-sample` moves to `profile`. `generate` no longer calls the feed publisher. `watchtower situations` (+ `show`) and `watchtower feed` are deleted.

### 3.6 Prompts

Migration deregisters `inbox.triage`, `inbox.compose`, `inbox.situation_card`, `inbox.situation_learn` prompt rows (the 00012 precedent) and the store drops their defaults. `inbox.style_sample` stays.

---

## 4. Data & migration (one goose migration, next free number)

| Object | Action | Why |
|---|---|---|
| `inbox_items` | keep, schema unchanged | Live feeder. `item_class`/`priority`/`ai_reason` columns stay (nothing writes non-defaults any more; recreating the table to drop them buys nothing). |
| `situations`, `situation_signals` | keep, **frozen** history; `UPDATE situations SET status='stale' WHERE status='open'` | No writer remains; `converted_target_id`/`converted_track_id` links and `targets.source_type='situation'` rows stay valid. |
| `situation_feedback`, `inbox_feedback`, `feed_items` | `DROP TABLE` | Only readers were the dead Dashboard and memory's interaction ingest (§5.3). `inbox_feedback` has 0 rows on the live install. |
| `inbox_learned_rules` | keep | Cross-pipeline rule store: digest/tracks/briefing/catchup inject `ListLearnedRulesByPipeline`, `catchup feedback` writes rules. Existing `source='implicit'` rows stay inert. |
| `inbox_items` `decision_made` rows | `UPDATE … SET status='resolved'` where `trigger_type='decision_made' AND status='pending'` | Their only renderer was the Dashboard (1 row live). |
| `workspace.secretary_profile`, `workspace.style_profile` | keep | Profile tab (live), Catch-Up compose, idea chat, meeting follow-up. |
| `workspace.compose_last_run_ts`, `workspace.memory_last_situation_feedback_id`, `memory_dispute_flags` | keep, unread | Not worth a DROP COLUMN's migration risk; documented as vestigial in `schema.sql` comments. |

Mirror into `internal/db/schema.sql`, `TestAllTablesExist`, the schema golden, and the Swift fixture `Tests/Support/TestDatabase+Schema.swift` (the `TestDatabase.swift` vs `schema.sql` drift lesson).

---

## 5. Readers of the frozen tables

### 5.1 Situations CLI / agent read tools / dev pack

`internal/tools/situations.go` (`list_situations`, `get_situation`) and its registration in `readtools.go` are deleted: handing a coding agent a table frozen on 2026-09-06 as "what is going on" is audit L4. The dev-pack skill `watchtower-whats-changed` is built entirely on those two tools and is removed from `internal/devpack/skills/`; the installer already handles "shipped file no longer in the pack" (`integrate status` reports it, `integrate remove` deletes only marker-carrying files). A "what changed" skill over Catch-Up would need Catch-Up exposed as a read tool first — a follow-up, not this spec. AGENT-01's and dev-surface's mentions of the two tools are removed.

### 5.2 Memory — situations

- `ingest.go` situations-ingest (episode nodes aliased `situation:<id>`) is deleted: the source dried up on 2026-09-06 and will never produce a row again. Existing vault nodes remain valid history.
- `mirror_ingest.go`'s `ConvertedSituationIDs` cross-link and `chat_ingest.go`'s `situationSubjects` stay as read-only readers of the frozen table (historic links, no cost). `chatContextTypes` keeps `"situation"` so the frozen Discuss conversations remain ingestible history under MEM-09 unchanged.

### 5.3 Memory — interaction ingest and disputes

`runInteractionIngest` (`action_ingest.go`) has exactly three sources — (A) `inbox_feedback`, (A2) `feedback(entity_type='situation')`, (B) terminal situation verdicts — and every one of them dies here. The step and its `memory.sources.actions` toggle are therefore removed (registry sub-toggle, `cmd/features.go` case, `cmd/config.go` allowlist, config default). Kept in place: the `owner-action` rank and its MEM-15 non-protecting rule, the `act:` provenance scheme, `memory_engagement` + `RetentionInputs.Engagement`, and the 5D OWNER ACTIONS block — they starve rather than break (an empty staged set renders no block), and removing belief-math surface area is a memory-owned decision under MEM-06..08/12/15 that this spec does not take. **Owner call recorded for the memory inventory:** the only owner-verdict signal left in the product is Catch-Up's per-topic 👍/👎; re-feeding engagement from it is a candidate follow-up, otherwise the rank/scheme/aggregate are the next demolition.

Disputes (`memory.surfaces.disputes`, dark): memory sets `memory_dispute_flags`, the inbox `watchtower` detector minted `decision_made` items, the Dashboard rendered them. The detector branch and the toggle (registry sub-toggle, `cmd/features.go`, `cmd/config.go`, config default, `Pipeline.cfg.Memory.Surfaces.Disputes` read) are removed; the flag writers in the belief pass and `reflect.go` are **not** touched (belief math under MEM-06..08). MEM-10 is reworded: memory only sets the flags; no surface reads them today.

---

## 6. Config, Feature Manager, onboarding

Removed keys: `inbox.max_triage_messages`, `inbox.max_awareness_cards`, `inbox.situations.enabled`, `dashboard.stale_after_days`, `dashboard.max_compose_signals`, `feed.enabled`, `feed.meeting_lead_minutes`, `memory.surfaces.disputes`, `memory.sources.actions`. Kept: `inbox.enabled`, `inbox.max_items_per_run`, `inbox.initial_lookback_days`. `config.Load` uses a non-strict `viper.Unmarshal`, so stale keys in an existing `config.yaml` are ignored; `cmd/config.go`'s settable-key allowlist drops them so `config set` refuses them going forward.

Feature registry (`internal/features/registry.go`):
- `dashboard` and `feed` entries deleted (both describe the dead surface; neither id is referenced outside the registry and its tests).
- `secretary-inbox` keeps its **id** (stable identifier: `features enable secretary-inbox`, the onboarding first-contact latch) but is re-described: `Title: "Attention detection"`, description "Detects mentions, DMs, thread replies and mail addressed to you and closes them when you answer in the source — no AI. Feeds Catch-Up and the daily Briefing.", `Cost: CostNone`, no `SubToggles`, `FeedsInto: ["briefing"]`, tagline/benefits rewritten to match. Its fast-forward hook keeps only `SetInboxLastProcessedTS` (drops `SetComposeLastRunTS`).
- `memory` loses the `sources.actions` and `surfaces.disputes` sub-toggles.
- `FeatureSplashView` and Settings → Features render from the registry; no Swift hardcodes the removed ids (verified by grep).

---

## 7. Desktop

Deleted (all unreachable — `InboxFeedView` has zero call sites since Wave 2):
`Views/Inbox/InboxFeedView.swift`, `InboxCardView.swift`, `InboxFeedbackSheet.swift`; `Views/Dashboard/` entirely (`DashboardView`, `FeedRow`, `FeedFilterBar`, `FeedDetailPanes`, `SituationRow`, `SituationReviewPane`, `SituationDiscussSection`); `ViewModels/InboxViewModel`, `DashboardViewModel`, `FeedViewModel`, `SituationChatViewModel`; `Database/Queries/FeedItemQueries`, `Models/FeedItem`; `WatchtowerCore/.../InboxFeedbackQueries`, `Models/InboxFeedback`; `WatchtowerCore/Services/DashboardGenerateService`; `TargetPrefillBuilder.fromSituation` / `.fromInbox` (no callers); the matching tests (`InboxTests`, `InboxViewModelTests`, `DashboardViewModelTests`, `FeedViewModelTests`, `FeedItemQueriesTests`, `SituationChat*Tests`, the feedback-queries tests).

`AppState` drops `dashboardViewModel`/`feedViewModel` construction and storage. `SidebarCountsViewModel` drops `inboxPendingCount`, `inboxHighPriorityCount`, `situationsCount` (none has a sidebar consumer) and removes `"situations"` from the `ValueObservation` table list; `"inbox_items"` stays observed only if a remaining consumer needs it — with the three fields gone none does, so it goes too. `inboxStripCount` is the keeper.

Kept, live: `ActionStripView` with its Actions / Learned / Profile segments; `InboxLearnedRulesView`/VM/Queries; `SecretaryProfileView`/VM/Queries; `InboxQueries` (Catch-Up `[inbox#id]` ref resolution, `TrackEventQueries` permalink lookup, `ChannelStatsQueries`); `SituationQueries` shrinks to what `FeedItemQueries`' removal leaves needed — expected to be nothing but the `Situation` model for historical `targets.source_type='situation'` rendering; delete the rest.

Sidebar label stays **"Inbox"** (default taken in session; renaming to "Actions" is a one-line follow-up if the owner wants it). The `.inbox` destination id is unchanged.

`Tests/Support/TestDatabase+Schema.swift` drops the three tables in lockstep with §4.

---

## 8. Contracts & documentation

`docs/inventory/inbox-pulse.md`:
- **Retired** (with a dated changelog entry naming this spec): INBOX-01 (two-tier triage), INBOX-03 (stream surfacing), INBOX-04 (gradual learning), INBOX-06 (user rules outrank implicit — moot with no implicit writer), INBOX-07 (triage failure leaves state untouched).
- **Kept**: INBOX-02 (auto-resolve on reply/reaction/close — the reason detection survives), INBOX-09 (detector failure never advances the watermark; reworded to drop the triage arms).
- **Reworded**: INBOX-05 becomes the cross-pipeline learned-rules manager contract — the Learned tab on the action strip is the visible, editable store of `inbox_learned_rules` that digest/tracks/briefing/catchup consume.

`docs/inventory/dashboard.md`: DASH-01..07 retired wholesale; the file becomes a tombstone pointing at this spec (situations table frozen, read-only history). Its guard tests die with `internal/inbox`'s deleted files and `internal/feed` (`TestDash05_*`, `TestDash06_*`) — no guard is relaxed, they are removed together with the behaviour they guarded, which is the approved demolition, not a weakening.

Other inventory touch-ups: `memory.md` (MEM-05 rewording — no inbox tables left to read except `inbox_items`, which memory never touched; MEM-10 rewording per §5.3; the interaction-ingest paragraph marked removed with the owner call from §5.3), `agent-actions.md` (AGENT-01 no longer lists the situations read tools), `dev-surface.md` (three skills, not four), `reaction-commands.md` (STRIP-01..03 text that says the strip "replaced" the Dashboard now says the Dashboard is gone), `features.md` (FEAT contract line about situations never being deleted stays true — they are not deleted), `catchup.md` (note that `needs_you` sees trigger rows only), `README.md` module table.

`CLAUDE.md`: the "Assistant Inbox + Dashboard" section is replaced by a short "Attention detection (inbox feeder)" section; the Reaction Commands Wave 2 bullet about `inbox.situations.enabled` is replaced by a pointer here. `docs/app-guide.md` loses the Dashboard walkthrough.

---

## 9. Testing

- Go: every `internal/inbox` test for surviving behaviour stays green unchanged (detectors, auto-resolve, watermark, backfill). `decideWatermark` tests lose their triage cases. New: a `GetInboxItemsForBriefing` test pinning `archived_at IS NULL`. Migration test: the frozen-situations UPDATE and the three drops; `TestAllTablesExist` and the golden regenerated. `internal/memory` tests for the removed interaction ingest and situations ingest are deleted; `TestMemory05_*`/`TestMemory10_*` are reworded to the surviving reads, not relaxed.
- The tier property scan and `TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces` are updated for the removed read tools.
- Swift: `make test-swift FILTER=` per touched class; Core-level tests (`SidebarCountsViewModelTests`, `CatchUpQueriesTests`, `TrackEventQueriesTests`, `TargetQueriesStatusCascadeTests`, `DatabaseManagerTests`) adjusted for the dropped tables and fields.
- Gate before the PR: full `make test`, `make test-swift`, `make lint-all`.

## 10. Delivery

One feature branch, landed as **two stacked PRs** so neither diff crosses the ~6k-line mark where codex review dies (see the PR #125 review-wave lesson):

1. **Go + migration + docs** — §3–6, §8, §9 Go half. The Swift fixture schema change rides here too, because the Go migration drops tables the fixture mirrors.
2. **Desktop** — §7 and its tests.

Each PR goes through `local-review`; the demolition is the approved change, so a reviewer flagging "guard test removed" is answered by this spec, not by restoring the test.

## 11. Owner calls recorded

- style-sample lives under `watchtower profile` (session default, §3.2).
- `situation_feedback`/`inbox_feedback`/`feed_items` are dropped, not left empty (session default, §4).
- `watchtower-whats-changed` is removed rather than left on frozen data (§5.1).
- Sidebar label stays "Inbox" (§7).
- Memory's `owner-action` rank / `act:` scheme / `memory_engagement` are left starving, with the re-feed-from-Catch-Up follow-up flagged (§5.3) — the one item here that still needs an explicit yes/no later.
