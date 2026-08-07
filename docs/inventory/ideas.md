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

**Observable:** A consolidator run (`internal/ideas.Consolidate`, prompt `ideas.consolidate`) advances the `workspace` floors (`ideas_digest_floor`, `ideas_stream_digest_floor`, `ideas_transcript_floor`) only when the whole run applied cleanly. An AI generator error, malformed/unparseable JSON, or a mid-apply error advances no floor and writes no row — stage-1 material (fresh `digest_topics`, `stream_digests`, `meeting_transcripts` rows) is never consumed without being applied. When the input cap (`ideas.max_prompt_chars`) truncates a run, floors advance only past the rows actually included in that truncated input, so the carried-over remainder is picked up by the next run. A run with zero new material is a clean no-op (degenerate case, no floor movement, no AI call). The same contract applies one level up, per stage-1 source: the Gmail (`ideas.digest_email`) and Jira (`ideas.digest_jira`) pre-digest passes advance their own per-account floors (`google_accounts.ideas_email_floor`, `jira_accounts.ideas_jira_floor`) only after a successful `stream_digests` write.

**Why locked:** The consolidator is the only place ideas/decisions get created from raw material; if a floor could advance on a failed or partial run, that cycle's candidates would be silently lost — the exact "nothing gets lost" promise this feature exists to deliver would break on its own error path.

**Test guards:**
- `internal/ideas/consolidate_test.go::TestConsolidate_GeneratorError_NothingWritten`
- `internal/ideas/consolidate_test.go::TestConsolidate_MalformedJSON_NothingWritten`
- `internal/ideas/consolidate_test.go::TestConsolidate_MaxPromptChars_TruncatesToWholeUnits`
- `internal/ideas/consolidate_test.go::TestConsolidate_NoNewMaterial_CleanNoOp`
- `internal/ideas/email_digest_test.go::TestRunEmailDigests_GeneratorError_NoRowFloorUnchanged`
- `internal/ideas/email_digest_test.go::TestRunEmailDigests_NoNewMessages_CleanNoOp`
- `internal/ideas/jira_digest_test.go::TestRunJiraDigests_GeneratorError_NoRowFloorUnchanged`
- `internal/ideas/jira_digest_test.go::TestRunJiraDigests_NoChangedIssues_CleanNoOp`

**Locked since:** 2026-08-07

## IDEA-02 — No invented provenance

**Status:** Enforced

**Observable:** Every mention `ref` the consolidator emits is validated against the refs actually present in that run's stage-1 input (Slack `<channel_id>|<ts>`, meeting transcript id, Gmail `<account_id>:<thread_id>`, Jira issue key). A ref that does not resolve is dropped; if an op loses all of its mentions this way, the whole op is discarded and a `refs_rejected` counter increments — nothing invented is ever persisted. The same validation applies one level up: the Gmail and Jira stage-1 passes reject a hallucinated ref before it ever reaches `stream_digests`.

**Why locked:** This is the MEM-13 pattern applied to ideas — an idea whose only evidence is a model-invented Slack timestamp or Jira key would be unverifiable and would corrupt the chronology the whole registry is built around.

**Test guards:**
- `internal/ideas/consolidate_test.go::TestConsolidate_InventedRef_PartiallyDropped`
- `internal/ideas/consolidate_test.go::TestConsolidate_InventedRef_AllDropped_OpDiscarded`
- `internal/ideas/email_digest_test.go::TestRunEmailDigests_HallucinatedRef_Dropped`
- `internal/ideas/jira_digest_test.go::TestRunJiraDigests_HallucinatedRef_Dropped`

**Locked since:** 2026-08-07

## IDEA-03 — Links, not deletes

**Status:** Enforced

**Observable:** Converting an idea to a Target (`converted_target_id`) and merging one item into another (`merged_into_id`) both keep the original `ideas` row — status changes to `converted`/`merged`, but the row, its `idea_mentions`, and any Discuss chat stay in place. Mentions keep accruing on a converted/merged/superseded/reversed item afterwards (a repeat mention of a merged item lands as a mention row on the original, not a resurrected duplicate). Neither Go nor Swift ever cascade-deletes mentions or chat on a status transition.

**Why locked:** The registry's chronology and the target/track/situation history it feeds are the point of mining ideas in the first place; a delete-on-convert or delete-on-merge would discard exactly the provenance trail the owner triaged.

**Test guards:**
- `internal/ideas/consolidate_test.go::TestConsolidate_AttachMention_MergedIdea_LandsOnTarget`
- `WatchtowerDesktop/Tests/IdeaQueriesTests.swift::testMergeReparentsMentionsAndFollowsLink`
- `WatchtowerDesktop/Tests/IdeaQueriesTests.swift::testMarkConvertedSetsStatusAndTargetLink`

**Locked since:** 2026-08-07

## IDEA-04 — Resurfacing respects the verdict

**Status:** Enforced

**Observable:** When the consolidator attaches a repeat mention to an item whose status is `not_now`, `dropped`, or `rejected`, it inserts the mention row and sets `needs_review=1` with a `review_reason` ("brought up again in #channel") — but never changes `status`. The item surfaces in the Desktop "For review" section, but only an explicit owner action (Approve/Activate/etc., which clears `needs_review`) moves it out of its verdict status.

**Why locked:** A repeat mention silently reversing the owner's earlier "not now" or "rejected" call would make triage decisions non-sticky — the owner would have to re-litigate the same idea every time it comes up again, defeating the point of triaging it once.

**Test guards:**
- `internal/ideas/consolidate_test.go::TestConsolidate_AttachMention_RejectedIdea_NeedsReview`
- `internal/db/ideas_test.go::TestIdeas_SetIdeaNeedsReviewTx`
- `WatchtowerDesktop/Tests/IdeaQueriesTests.swift::testSetStatusClearsNeedsReview`

**Locked since:** 2026-08-07

## Changelog

- 2026-08-07: file created with 4 contracts (IDEA-01..04), all Enforced. Introduced by the Ideas & Decisions Registry feature (spec `docs/superpowers/specs/2026-08-07-ideas-registry-design.md`), a two-stage pipeline that mines ideas/decisions/notes out of Slack, meeting transcripts, Gmail, and Jira (incl. comments) into a triaged registry with its own Desktop tab.
