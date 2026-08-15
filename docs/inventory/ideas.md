# Behavior Inventory — Ideas & Decisions Registry

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/ideas/` (stage-1 pre-digests +
> the consolidator), `internal/db/ideas.go`, `internal/jira/sync.go`
> (bounded comment sync), or `WatchtowerDesktop/Sources/Views/Ideas/` /
> `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/IdeaQueries.swift`, read this
> file first. Any proposed change that would break a guard test or remove
> a contract must be raised as a question before touching code.

**Module:** `internal/ideas/` (stage-1 pre-digests + consolidator) + `internal/db/ideas.go` + `WatchtowerDesktop/Sources/Views/Ideas/`, `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/IdeaQueries.swift`
**Last full audit:** 2026-08-07

## IDEA-01 — Floor honesty

**Status:** Enforced

**Observable:** A consolidator run (`internal/ideas.Consolidate`, prompt `ideas.consolidate`) advances the `workspace` floors (`ideas_digest_floor`, `ideas_stream_digest_floor`, `ideas_transcript_floor`) only when the whole run applied cleanly. An AI generator error, malformed/unparseable JSON, a reply missing the `ops` key, a mid-apply error, or a floor write that matches no `workspace` row advances no floor and writes no row — stage-1 material (fresh `digest_topics`, `stream_digests`, `meeting_transcripts` rows) is never consumed without being applied. When the input cap (`ideas.max_prompt_chars`) truncates a run, floors advance only past the rows actually included in that truncated input, so the carried-over remainder is picked up by the next run.

The converse also holds — a floor never *stalls* on material that was genuinely consumed. A run with zero new material is a clean no-op (no floor movement, no AI call), but a run whose units were all inert (empty `stream_digests` rows, stale recap-less transcripts, a unit larger than the whole prompt budget) makes no AI call and still persists its advanced floors, so the same rows are not re-read forever. Source windows are tie-safe at their cap: `ListJiraIssuesUpdatedSince` drains the whole boundary timestamp rather than cutting inside it.

The same contract applies one level up, per stage-1 source: the Gmail (`ideas.digest_email`) and Jira (`ideas.digest_jira`) pre-digest passes advance their own per-account floors (`google_accounts.ideas_email_floor`, `jira_accounts.ideas_jira_floor`) only after a successful `stream_digests` write, and treat a reply missing the `topics` key as a failure.

Floors are seeded at install time: migration 00050 stamps the three `workspace` floors at the current top of each source table, so the registry starts from material mined after it shipped instead of backfilling all of history on the first run. The per-account stage-1 floors self-initialize on their first run instead, since an account connected later has no migration to seed it.

**Why locked:** The consolidator is the only place ideas/decisions get created from raw material; if a floor could advance on a failed or partial run, that cycle's candidates would be silently lost — the exact "nothing gets lost" promise this feature exists to deliver would break on its own error path.

**Test guards:**
- `internal/ideas/consolidate_test.go::TestIdeas01_GeneratorErrorNothingWritten`
- `internal/ideas/consolidate_test.go::TestIdeas01_MalformedJSONNothingWritten`
- `internal/ideas/consolidate_test.go::TestIdeas01_MaxPromptCharsTruncatesToWholeUnits`
- `internal/ideas/consolidate_test.go::TestIdeas01_NoNewMaterialCleanNoOp`
- `internal/ideas/consolidate_floors_test.go::TestIdeas01_ReplyWithoutOpsKey_NothingWritten`
- `internal/ideas/consolidate_floors_test.go::TestIdeas01_EmptyOpsArray_FloorsAdvance`
- `internal/ideas/consolidate_floors_test.go::TestIdeas01_NoWorkspaceRow_ErrorsAndRollsBack`
- `internal/ideas/consolidate_floors_test.go::TestIdeas01_InertStreamDigestRows_FloorAdvancesWithoutAICall`
- `internal/ideas/consolidate_floors_test.go::TestIdeas01_StaleRecaplessTranscripts_FloorAdvancesWithoutAICall`
- `internal/ideas/consolidate_floors_test.go::TestIdeas01_OversizedUnit_SkippedAndFloorAdvances`
- `internal/ideas/consolidate_floors_test.go::TestIdeas01_MidApplyFailure_RollsBackEarlierOps`
- `internal/ideas/consolidate_test.go::TestIdeas01_SecondTopicLookupFails_WholeInputDiscardedNoPartialFloor`
- `internal/ideas/email_digest_test.go::TestIdeas01_EmailGeneratorErrorNoRowFloorUnchanged`
- `internal/ideas/email_digest_test.go::TestIdeas01_EmailNoNewMessagesCleanNoOp`
- `internal/ideas/jira_digest_test.go::TestIdeas01_JiraGeneratorErrorNoRowFloorUnchanged`
- `internal/ideas/jira_digest_test.go::TestIdeas01_JiraNoChangedIssuesCleanNoOp`
- `internal/ideas/stage1_bounds_test.go::TestIdeas01_EmailReplyWithoutTopicsKey_NoRowFloorUnchanged`
- `internal/ideas/stage1_bounds_test.go::TestIdeas01_JiraReplyWithoutTopicsKey_NoRowFloorUnchanged`
- `internal/db/ideas_test.go::TestIdeas01_JiraWindowBoundaryDrainKeepsSameTimestampIssues`
- `internal/db/ideas_test.go::TestIdeas01_JiraWindowIsDeterministicWithinATimestamp`
- `internal/digest/topic_ideas_test.go::TestStoreDigest_EmptyIdeasAndDecisionsPersistAsEmptyArrays`

**Locked since:** 2026-08-07

## IDEA-02 — No invented provenance

**Status:** Enforced

**Observable:** Every mention `ref` the consolidator emits is validated against the refs actually present in that run's stage-1 input (Slack `<channel_id>|<ts>`, `transcript:<id>`, Gmail `gmail:<account_id>:<thread_id>`, Jira issue key). A ref that does not resolve is dropped; if an op loses all of its mentions this way, the whole op is discarded and a `refs_rejected` counter increments — nothing invented is ever persisted. A mention's stored `source` is likewise *derived* from the ref that survived validation, never copied from the model's own `source` token (which is ignored entirely). The same validation applies one level up: the Gmail and Jira stage-1 passes reject a hallucinated ref before it ever reaches `stream_digests`, and a unit dropped for prompt budget is dropped from the valid-ref set too, so nothing can be cited that the model was never shown.

Slack refs get the same treatment at the layer where they are first assembled, because a digest topic's `message_ts` is itself model-emitted: `renderTopicUnit` resolves every idea/decision candidate's ts against a real, non-deleted `messages` row in that channel (one batched existence-only `db.FilterExistingMessageTS` per topic, exact string match — no normalization, no prefix repair, the MEM-13 strict-set precedent) at material-assembly time. An unresolvable candidate is dropped from the rendered unit AND from the run's valid-ref set, so the model is never shown evidence nobody could follow and can never cite it; a topic whose candidates all drop renders empty and is consumed like a candidate-less one (its floor still advances, IDEA-01). The `messages` read failing is an infrastructure error that fails the run — never a verdict that every candidate was invented. Drops are counted and surfaced, not log-only: the pipeline accumulates `slack_refs_dropped`/`refs_rejected` (the `AccumulatedUsage` pattern), and they appear on the `ideas mine` output line, in the backfill envelope, and in the daemon log — so "no Slack ideas this run" and "everything was discarded" are distinguishable to the owner.

The validation has a write-time twin one layer down, so the exact-match gate is satisfiable in the first place: `formatMessages` renders each message's raw Slack ts (`ts=` tag) into the digest prompts — before this, the model only ever saw `HH:MM` and *constructed* every `message_ts` (measured on the production DB: 43 of 3233 decision refs resolved) — and `blankInventedMessageRefs` (internal/digest) blanks any `decisions[].message_ts`/`ideas[].message_ts` not present among the messages actually rendered into that prompt, at digest write time, keeping the item and killing only the fake ref. Historical digest rows written before the renderer fix remain unverifiable and are dropped by the consumer-side check above; `ideas mine --from` can re-mine any window once new digests cover it.

**Why locked:** This is the MEM-13 pattern applied to ideas — an idea whose only evidence is a model-invented Slack timestamp or Jira key would be unverifiable and would corrupt the chronology the whole registry is built around.

**Test guards:**
- `internal/ideas/consolidate_test.go::TestIdeas02_InventedRefPartiallyDropped`
- `internal/ideas/consolidate_test.go::TestIdeas02_InventedRefAllDroppedOpDiscarded`
- `internal/ideas/consolidate_test.go::TestIdeas02_SlackRefMissingFromMessages_NotRenderedNotCitable`
- `internal/ideas/consolidate_test.go::TestIdeas02_SlackRefDeletedMessage_Dropped`
- `internal/ideas/consolidate_test.go::TestIdeas02_SlackRefRealMessage_SurvivesValidation`
- `internal/ideas/consolidate_test.go::TestIdeas02_AllSlackRefsUnverifiable_NoMaterialFloorAdvances`
- `internal/ideas/consolidate_test.go::TestIdeas02_MessageLookupError_FailsRunFloorsUntouched`
- `internal/db/messages_extra_test.go::TestIdeas02_FilterExistingMessageTS_DeletedAndForeignChannelExcluded`
- `internal/ideas/consolidate_floors_test.go::TestIdeas02_TranscriptRef_MentionSourceIsMeeting`
- `internal/ideas/consolidate_floors_test.go::TestIdeas02_ModelSourceToken_Ignored`
- `internal/ideas/email_digest_test.go::TestIdeas02_EmailHallucinatedRefDropped`
- `internal/ideas/jira_digest_test.go::TestIdeas02_JiraHallucinatedRefDropped`
- `internal/ideas/stage1_bounds_test.go::TestRenderEmailBlock_BudgetDropsThreadFromBlockAndTags`
- `internal/ideas/stage1_bounds_test.go::TestRenderJiraBlock_BudgetDropsIssueFromBlockAndTags`

**Locked since:** 2026-08-07

## IDEA-03 — Links, not deletes

**Status:** Enforced

**Observable:** Converting an idea to a Target (`converted_target_id`) and merging one item into another (`merged_into_id`) are both *links*, never deletes — the original `ideas` row survives with its status changed to `converted`/`merged`.

- **Convert** keeps everything on the row: the idea, its `idea_mentions`, and its Discuss chat all stay exactly where they are, plus a `converted_target_id` pointing at the new Target.
- **Merge** re-parents the merged item's `idea_mentions` onto the surviving idea, which becomes their single canonical home, and leaves behind a `merged_into_id` link. Nothing is deleted; the mentions move rather than being duplicated or dropped. The consolidator follows that link, so a later sighting of a merged-away item lands on the survivor instead of resurrecting a duplicate.

Neither Go nor Swift ever cascade-deletes mentions or chat on a status transition.

**Why locked:** The registry's chronology and the target/track/situation history it feeds are the point of mining ideas in the first place; a delete-on-convert or delete-on-merge would discard exactly the provenance trail the owner triaged.

**Test guards:**
- `internal/ideas/consolidate_test.go::TestIdeas03_AttachMentionMergedIdeaLandsOnTarget`
- `WatchtowerDesktop/Tests/Core/IdeaQueriesTests.swift::testIdeas03_MergeReparentsMentionsAndFollowsLink`
- `WatchtowerDesktop/Tests/Core/IdeaQueriesTests.swift::testIdeas03_MarkConvertedSetsStatusAndTargetLink`
- `WatchtowerDesktop/Tests/Core/IdeaQueriesTests.swift::testIdeas03_MarkConvertedKeepsMentionsAndChat`

**Locked since:** 2026-08-07

## IDEA-04 — Resurfacing respects the verdict

**Status:** Enforced

**Observable:** When the consolidator attaches a repeat mention to an item whose status is `not_now`, `dropped`, or `rejected`, it inserts the mention row and sets `needs_review=1` with a `review_reason` ("brought up again in #channel") — but never changes `status`. The item surfaces in the Desktop "For review" section, but only an explicit owner action moves it out of its verdict status.

The flag must always be *clearable*: every Swift owner action — `setStatus`, `snooze`, `merge`, `supersede`, `markConverted` — clears `needs_review`/`review_reason` in the same write, and the detail pane offers at least one such action for every status a resurfacing can flag (including `rejected` and `dropped`, which get "Activate" alongside "Merge"). An idea that could be flagged but not unflagged would sit in the review queue forever.

**Why locked:** A repeat mention silently reversing the owner's earlier "not now" or "rejected" call would make triage decisions non-sticky — the owner would have to re-litigate the same idea every time it comes up again, defeating the point of triaging it once. The clearability half is the same contract from the other side: a flag with no way out turns the review queue into a graveyard.

**Test guards:**
- `internal/ideas/consolidate_test.go::TestIdeas04_AttachMentionRejectedIdeaNeedsReview`
- `internal/db/ideas_test.go::TestIdeas04_SetIdeaNeedsReviewTx`
- `WatchtowerDesktop/Tests/Core/IdeaQueriesTests.swift::testIdeas04_SetStatusClearsNeedsReview`
- `WatchtowerDesktop/Tests/Core/IdeaQueriesTests.swift::testIdeas04_EveryOwnerActionClearsNeedsReview`
- `WatchtowerDesktop/Tests/IdeasViewModelTests.swift::testIdeas04_ResurfacedRejectedIdeaLeavesReviewQueueViaActivate`

**Locked since:** 2026-08-07

## IDEA-05 — Re-mining idempotency (ref-level dedup)

**Status:** Enforced

**Observable:** Re-mining any already-mined material never duplicates registry state. Mechanically: (1) an `attach_mention` whose ref already exists on the target idea inserts nothing; (2) a `new_idea`/`new_decision` op whose mention refs ALL already exist anywhere in `idea_mentions` creates nothing (the material was already mined — `mentions_deduped` counts it); a partially-known op keeps only its unknown refs. The check runs inside the apply transaction against `idea_mentions.ref` + source. "Already exist" for clause (2) means **known before this consolidation pass began** ([OWNER] ruling, 2026-08-08, GB6) — a ref minted by an EARLIER op within the SAME apply pass does not count, so a single message can still mint two distinct new ideas that both happen to cite it: `applyConsolidateOps` tracks refs it has itself inserted this pass and excludes them from the known-set check for every later op in the same pass.

The check is a lookup per mention inside `applyConsolidateOps`, backed by `idx_idea_mentions_ref ON idea_mentions(source, ref)` (migration 00051) — it protects the everyday pipeline too, not only the backfill re-mining path that motivated it, since floor manipulation of any kind can no longer double-mint. Clause (2) (`new_idea`/`new_decision`) uses `db.IdeaMentionRefsKnownTx`, a ref -> idea_id map lookup, since it only needs to know whether a ref is known ANYWHERE. Clause (1) (`attach_mention`, GB5) uses a dedicated `db.IdeaHasMentionRefTx(tx, ideaID, source, ref)` instead of the same map: a ref can legitimately be recorded on more than one idea (a message that separately evidences two already-tracked ideas), and `IdeaMentionRefsKnownTx`'s ref -> idea_id map can only ever report ONE owning idea per ref — whichever a query happened to return last, nondeterministically. The attach path needs a deterministic, target-scoped answer to "does THIS idea already have this ref", which only the dedicated query gives. `mentionsDeduped` is threaded up through `applyConsolidateOps`'s return and surfaced on the consolidator's log line next to `refs_rejected`.

**IDEA-05 x IDEA-04:** when an `attach_mention` is dropped because its ref is already recorded on the target idea, `needs_review` must NOT be set even if the target's status is `not_now`/`dropped`/`rejected` — a deduped attach carries no new evidence, so it must not resurface a verdict the owner already made. IDEA-04's needs_review flag is reserved for a mention that actually lands.

**Why locked:** The backfill feature (spec `docs/superpowers/specs/2026-08-08-ideas-backfill-design.md`) deliberately re-mines material the ordinary pipeline may have already seen — a lowered floor, a re-run over an overlapping window, or a retried cycle after a crash. Without ref-level dedup, any of those would silently double-mint ideas/decisions or duplicate mentions, corrupting the registry's chronology and counts.

**Test guards:**
- `internal/ideas/consolidate_test.go::TestIdeas05_RerunSameWindow_NoDuplicates`
- `internal/ideas/consolidate_test.go::TestIdeas05_AttachKnownRef_InsertsNothing`
- `internal/ideas/consolidate_test.go::TestIdeas05_PartiallyKnownNewIdea_KeepsUnknownRefsOnly`
- `internal/ideas/consolidate_test.go::TestGB5_AttachMention_RefKnownOnDifferentIdea_StillInsertsOnTarget`
- `internal/ideas/consolidate_test.go::TestGB6_TwoNewIdeasShareSameRefInOnePass_BothSurvive`

**Locked since:** 2026-08-08

## Changelog

- 2026-08-15 (Ideas delete + Ideas/Notes split, design `docs/superpowers/specs/2026-08-15-ideas-delete-and-note-split-design.md`): the Desktop Ideas tab gained an owner-initiated hard delete (`IdeaQueries.delete`, Swift-only, one transaction removing the `ideas` row, its `idea_mentions`, and its Discuss chat, and nulling `similar_to_id`/`merged_into_id`/`superseded_by_id` on rows that pointed at it — those three columns carry no foreign key). This is deliberately **outside IDEA-03**, which governs the convert and merge *transitions*: both remain links that keep the row, its mentions, and its chat, and neither their behavior nor their guard tests changed. Deleting a mined idea also removes the `idea_mentions` rows that serve as IDEA-05's dedup anchors, so a later consolidator pass or backfill over the same material can legitimately re-mint it — an owner-accepted limitation of ref-level dedup, not a defect in it; owner-created entries carry no minable refs and delete cleanly. The same change split the tab into `Ideas | Notes` segments: `IdeaQueries.fetchForReview` now takes a `kind`, so the review queue is scoped to the active segment (a flagged note is reviewed under Notes, still reachable, IDEA-04 clearability intact), while the sidebar badge `countForReview` stays global across both kinds.
- 2026-08-12 (Decisions Split + Cross-Source Digests, design `docs/superpowers/specs/2026-08-12-decisions-split-cross-source-digests-design.md`): mined decisions are now born `active` instead of `proposed` (`applyNewIdeaOp` sets `Status: "active"` for `new_decision` ops; migration 00053 flips the existing backlog of `proposed` decisions to `active`). The review queue (Go `CountIdeasForReview`; Swift `IdeaQueries.fetchForReview`/`countForReview` and the `excludingReviewQueue` arm of `fetchList`) now excludes `kind = 'decision'` outright — belt-and-braces, since after the birth-status change a decision should never be `proposed` anyway, but a resurfaced (`needs_review`) decision must still route to the Digests → Decisions ledger, not the Ideas "For review" section. IDEA-01..05 are unchanged mechanically — the consolidator, dedup, and provenance validation that produce decisions are exactly as before, only their landing status changed. Decisions now live as a dated cross-source journal in Digests → Decisions (reading `ideas WHERE kind = 'decision'`); see `docs/app-guide.md` and CLAUDE.md's "Ideas & Decisions Registry" section.
- 2026-08-10 ([OWNER] approved extension of IDEA-02): Slack refs coming out of stage-1 digest topics are no longer trusted verbatim. `digest_topics.ideas`/`decisions` carry a `message_ts` the *digest* model emitted, so it can be hallucinated — the incident that motivated this had a topic citing `1754131080.000000` in channel `1:G01M50YP2AX` where the genuine message was `1785746329.642879` (the model shifted the year), which the consolidator then happily minted a registry item against. `renderTopicUnit` now resolves each candidate's ts against a real, non-deleted `messages` row (one batched existence-only `db.FilterExistingMessageTS` per topic, exact match; `is_deleted = 1` counts as absent in the SQL itself, the `db.MessageExists` precedent) and drops the unverifiable ones from both the rendered unit and the run's valid-ref set. Non-Slack sources are untouched: stream digests are validated at stage 1 and transcript refs are code-constructed. `renderTopicUnit`/`addTopics`/`gatherConsolidateInput` gained an error return so a failed `messages` read fails the run with its floors intact (IDEA-01) instead of degrading into "every candidate is invented". The review of this change (judge-confirmed blocker, production-measured) surfaced that the digest model never SAW a raw ts — `formatMessages` rendered only `HH:MM`, so ~99% of historical `message_ts` are constructed — which would have silently starved the Slack lane through this very validation. Same-day companion fixes: `formatMessages` now renders a `ts=` tag per message, `blankInventedMessageRefs` blanks invented `decisions[]`/`ideas[]` refs at digest write time (item kept, ref killed), and the drop/reject counters are surfaced on every owner-facing path (`ideas mine` line, backfill envelope, daemon log) instead of log-only.
- 2026-08-08 (GB12, [OWNER] confirmed): `ListTranscriptsForIdeasAfter`'s `toISO` bound on `meeting_transcripts.created_at` is intentional and NOT a variant of the GB1 bug — unlike `stream_digests.created_at` (always "now", regardless of the content it summarizes), a transcript's `created_at` genuinely approximates when the meeting itself happened, so bounding a backfill window on it is correct as written. Also documented (code comments only, no behavior change): the Gmail coverage-skip check (`HasStreamDigestCovering`) is largely decorative in practice, since a Gmail `stream_digests` row's `period_from`/`period_to` are the min/max of whatever messages a run actually fetched, not the requested window's exact boundaries — a cost-only miss, never a correctness one (IDEA-05 still protects); and `ListGmailThreadsForExtract`'s boundary-drain now carries the same "no `beforeTS` needed" explanatory sentence its Jira twin (`ListJiraIssuesUpdatedSince`) already had.
- 2026-08-08 (GB7): the backfill lock (spec §5) is now enforced bidirectionally — `phaseIdeas` acquires the SAME `ideas.AcquireBackfillLock` a CLI `ideas mine --from` backfill takes (owner-tagged `"daemon"`, held for the duration of its run, released via defer) instead of only ever checking `BackfillLockFresh` read-only, so a daemon cycle and a CLI backfill now exclude each other both ways, not just CLI-blocks-daemon. `AcquireBackfillLock` gained an `owner` parameter (`"daemon"` / `"CLI backfill"`) so a losing acquire's error names the actual holder ("the daemon is mining right now"). Its release is now ownership-checked — it only removes the lock file if the contents still exactly match what this call wrote — closing a hole where a caller whose lock went stale and was reclaimed by someone else could have its later deferred release blindly delete the new owner's fresh lock. The daemon throttles its skip LOG line (not the skip itself) to once per 10 minutes so a long-running CLI backfill doesn't flood the log on every poll tick.
- 2026-08-08: [OWNER] ruling (GB6) — IDEA-05 clause (2)'s "already exist anywhere in `idea_mentions`" check now excludes refs minted by an earlier op within the SAME apply pass, so two distinct `new_idea`/`new_decision` ops citing the same ref in one consolidate reply both survive instead of the second one being silently discarded as a false dedup hit. Wording updated to "known before this consolidation pass began". Also (GB5) the `attach_mention` dedup check (clause 1) moved off `IdeaMentionRefsKnownTx`'s lossy ref -> idea_id map onto a dedicated target-scoped `db.IdeaHasMentionRefTx`, fixing a latent nondeterminism when the same ref is legitimately recorded on more than one idea.
- 2026-08-08: the Jira stage-1 pre-digest pass now normalizes `stream_digests.period_from`/`period_to` to RFC3339 UTC at the write site (`internal/ideas/jira_digest.go`'s `normalizeJiraStreamPeriod`), instead of storing Jira's raw offset format verbatim — `ideas_jira_floor` itself is unaffected and stays in Jira's dotted-ms format, since it is compared only against `jira_issues.updated_at`. Rows written before this change may still carry a raw Jira offset in `period_from`/`period_to`; the worst case for such a legacy row is one incorrect coverage/window skip, never data loss.
- 2026-08-08: added IDEA-05 (re-mining idempotency, ref-level dedup), Enforced. Introduced by the Ideas Backfill feature (spec `docs/superpowers/specs/2026-08-08-ideas-backfill-design.md`) ahead of the backfill engine itself, so the ordinary consolidator pipeline is already protected against double-minting before backfill starts re-mining old windows.
- 2026-08-07: file created with 4 contracts (IDEA-01..04), all Enforced. Introduced by the Ideas & Decisions Registry feature (spec `docs/superpowers/specs/2026-08-07-ideas-registry-design.md`), a two-stage pipeline that mines ideas/decisions/notes out of Slack, meeting transcripts, Gmail, and Jira (incl. comments) into a triaged registry with its own Desktop tab.
