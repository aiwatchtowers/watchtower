# Behavior Inventory — Ideas & Decisions Registry

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/ideas/` (stage-1 pre-digests +
> the consolidator), `internal/db/ideas.go`, `internal/jira/sync.go`
> (bounded comment sync), or `WatchtowerDesktop/Sources/Views/Ideas/` /
> `WatchtowerDesktop/Sources/Database/Queries/IdeaQueries.swift`, read this
> file first. Any proposed change that would break a guard test or remove
> a contract must be raised as a question before touching code.

**Module:** `internal/ideas/` (stage-1 pre-digests + consolidator) + `internal/db/ideas.go` + `WatchtowerDesktop/Sources/Views/Ideas/`, `WatchtowerDesktop/Sources/Database/Queries/IdeaQueries.swift`
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

**Why locked:** This is the MEM-13 pattern applied to ideas — an idea whose only evidence is a model-invented Slack timestamp or Jira key would be unverifiable and would corrupt the chronology the whole registry is built around.

**Test guards:**
- `internal/ideas/consolidate_test.go::TestIdeas02_InventedRefPartiallyDropped`
- `internal/ideas/consolidate_test.go::TestIdeas02_InventedRefAllDroppedOpDiscarded`
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
- `WatchtowerDesktop/Tests/IdeaQueriesTests.swift::testIdeas03_MergeReparentsMentionsAndFollowsLink`
- `WatchtowerDesktop/Tests/IdeaQueriesTests.swift::testIdeas03_MarkConvertedSetsStatusAndTargetLink`
- `WatchtowerDesktop/Tests/IdeaQueriesTests.swift::testIdeas03_MarkConvertedKeepsMentionsAndChat`

**Locked since:** 2026-08-07

## IDEA-04 — Resurfacing respects the verdict

**Status:** Enforced

**Observable:** When the consolidator attaches a repeat mention to an item whose status is `not_now`, `dropped`, or `rejected`, it inserts the mention row and sets `needs_review=1` with a `review_reason` ("brought up again in #channel") — but never changes `status`. The item surfaces in the Desktop "For review" section, but only an explicit owner action moves it out of its verdict status.

The flag must always be *clearable*: every Swift owner action — `setStatus`, `snooze`, `merge`, `supersede`, `markConverted` — clears `needs_review`/`review_reason` in the same write, and the detail pane offers at least one such action for every status a resurfacing can flag (including `rejected` and `dropped`, which get "Activate" alongside "Merge"). An idea that could be flagged but not unflagged would sit in the review queue forever.

**Why locked:** A repeat mention silently reversing the owner's earlier "not now" or "rejected" call would make triage decisions non-sticky — the owner would have to re-litigate the same idea every time it comes up again, defeating the point of triaging it once. The clearability half is the same contract from the other side: a flag with no way out turns the review queue into a graveyard.

**Test guards:**
- `internal/ideas/consolidate_test.go::TestIdeas04_AttachMentionRejectedIdeaNeedsReview`
- `internal/db/ideas_test.go::TestIdeas04_SetIdeaNeedsReviewTx`
- `WatchtowerDesktop/Tests/IdeaQueriesTests.swift::testIdeas04_SetStatusClearsNeedsReview`
- `WatchtowerDesktop/Tests/IdeaQueriesTests.swift::testIdeas04_EveryOwnerActionClearsNeedsReview`
- `WatchtowerDesktop/Tests/IdeasViewModelTests.swift::testIdeas04_ResurfacedRejectedIdeaLeavesReviewQueueViaActivate`

**Locked since:** 2026-08-07

## IDEA-05 — Re-mining idempotency (ref-level dedup)

**Status:** Enforced

**Observable:** Re-mining any already-mined material never duplicates registry state. Mechanically: (1) an `attach_mention` whose ref already exists on the target idea inserts nothing; (2) a `new_idea`/`new_decision` op whose mention refs ALL already exist anywhere in `idea_mentions` creates nothing (the material was already mined — `mentions_deduped` counts it); a partially-known op keeps only its unknown refs. The check runs inside the apply transaction against `idea_mentions.ref` + source.

The check is a single indexed lookup per mention (`db.IdeaMentionRefsKnownTx`, backed by `idx_idea_mentions_ref ON idea_mentions(source, ref)`, migration 00051) inside `applyConsolidateOps` — it protects the everyday pipeline too, not only the backfill re-mining path that motivated it, since floor manipulation of any kind can no longer double-mint. `mentionsDeduped` is threaded up through `applyConsolidateOps`'s return and surfaced on the consolidator's log line next to `refs_rejected`.

**IDEA-05 x IDEA-04:** when an `attach_mention` is dropped because its ref is already recorded on the target idea, `needs_review` must NOT be set even if the target's status is `not_now`/`dropped`/`rejected` — a deduped attach carries no new evidence, so it must not resurface a verdict the owner already made. IDEA-04's needs_review flag is reserved for a mention that actually lands.

**Why locked:** The backfill feature (spec `docs/superpowers/specs/2026-08-08-ideas-backfill-design.md`) deliberately re-mines material the ordinary pipeline may have already seen — a lowered floor, a re-run over an overlapping window, or a retried cycle after a crash. Without ref-level dedup, any of those would silently double-mint ideas/decisions or duplicate mentions, corrupting the registry's chronology and counts.

**Test guards:**
- `internal/ideas/consolidate_test.go::TestIdeas05_RerunSameWindow_NoDuplicates`
- `internal/ideas/consolidate_test.go::TestIdeas05_AttachKnownRef_InsertsNothing`
- `internal/ideas/consolidate_test.go::TestIdeas05_PartiallyKnownNewIdea_KeepsUnknownRefsOnly`

**Locked since:** 2026-08-08

## Changelog

- 2026-08-08: the Jira stage-1 pre-digest pass now normalizes `stream_digests.period_from`/`period_to` to RFC3339 UTC at the write site (`internal/ideas/jira_digest.go`'s `normalizeJiraStreamPeriod`), instead of storing Jira's raw offset format verbatim — `ideas_jira_floor` itself is unaffected and stays in Jira's dotted-ms format, since it is compared only against `jira_issues.updated_at`. Rows written before this change may still carry a raw Jira offset in `period_from`/`period_to`; the worst case for such a legacy row is one incorrect coverage/window skip, never data loss.
- 2026-08-08: added IDEA-05 (re-mining idempotency, ref-level dedup), Enforced. Introduced by the Ideas Backfill feature (spec `docs/superpowers/specs/2026-08-08-ideas-backfill-design.md`) ahead of the backfill engine itself, so the ordinary consolidator pipeline is already protected against double-minting before backfill starts re-mining old windows.
- 2026-08-07: file created with 4 contracts (IDEA-01..04), all Enforced. Introduced by the Ideas & Decisions Registry feature (spec `docs/superpowers/specs/2026-08-07-ideas-registry-design.md`), a two-stage pipeline that mines ideas/decisions/notes out of Slack, meeting transcripts, Gmail, and Jira (incl. comments) into a triaged registry with its own Desktop tab.
