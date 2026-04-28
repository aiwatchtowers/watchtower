# Behavior Inventory — Tracks

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/tracks/`, `internal/db/tracks.go`,
> or `WatchtowerDesktop/Sources/Views/Tracks/`, read this file first. Any
> proposed change that would break a guard test or remove a contract must
> be raised as a question before touching code.

**Module:** `internal/tracks/` + `internal/db/tracks.go` + `WatchtowerDesktop/Sources/Views/Tracks/`
**Last full audit:** 2026-04-28

## TRACKS-01 — One situation, one track

**Status:** Enforced

**Observable:** The same conversation, decision, or piece of work never appears twice in the tracks list. Re-extracting yesterday's digests doesn't grow the feed by N copies of yesterday. When the same thread surfaces again across cycles or channels, it merges into the existing track instead of creating a new one. Specifically:

- AI may identify an `existing_id` to update — that update sticks (subject to ownership, see TRACKS-05).
- A `[CEX-1234] / CVE-2026-… / MR!4567 / U-id / IP-addr` mentioned in both old and new content fingerprint-matches and merges.
- Russian/English text+context with Jaccard similarity ≥ 0.30 (using a 5-rune pseudo-stem so `инцидент` / `инцидента` / `инциденту` collapse to the same token) merges.
- Digest topics already linked to a track via `source_refs` (`digest_id`+`topic_id`) are stripped from the AI prompt before extraction, so the model can't propose a duplicate from them.

**Why locked:** The whole value of Tracks is "the single line per thing I owe". Without the four-layer dedup the feed doubles every daemon cycle (~every few minutes), the user loses trust in the count, and the read/unread surface becomes meaningless because every read item resurfaces under a new ID. This is the hardest contract to keep alive against AI prompt drift — small wording changes silently break it.

**Test guards:**
- `internal/tracks/pipeline_test.go::TestFindSimilarTrack`
- `internal/tracks/pipeline_test.go::TestTextSimilarityDedupInStoreTrackItems`
- `internal/tracks/pipeline_test.go::TestJaccardSimilarity`
- `internal/tracks/pipeline_test.go::TestTokenizeText`
- `internal/tracks/pipeline_test.go::TestTopicDedupBySourceRefs`
- `internal/db/tracks_test.go::TestFindTracksByFingerprint`

**Locked since:** 2026-04-28

## TRACKS-02 — Silent channels stay silent

**Status:** Enforced

**Observable:** A channel I never engage with — no existing tracks, not starred, no `@me`, no reports/peers in the discussion, no action items — does not produce tracks no matter how many digests it generates. The `scoreChannel` gate returns 0 and the channel is skipped before any AI call.

Scoring (additive, all must be visible to LLM only when score ≥ 1):
- channel has existing tracks: **+3**
- channel is starred in user profile: **+2**
- `@me` mention in `key_messages` or `situations`: **+2**
- a report/peer (per `user_profile.reports/peers`) in topic content: **+1**
- topic has non-empty `action_items`: **+1**

**Why locked:** Without this gate, every chatty channel (announcement feeds, deploy bots, off-topic) produces tracks because the LLM is willing to invent action items from any discussion. The gate is the difference between "tracks for me" and "everything that happened in Slack today" — it's also a major cost lever (skipped channels save a full LLM round-trip).

**Test guards:**
- `internal/tracks/pipeline_test.go::TestScoreChannel`

**Locked since:** 2026-04-28

## TRACKS-03 — "Watching" lane stays narrow

**Status:** Partial

**Observable:** Tracks I'm only watching (ownership=`watching`) are reserved for things that might actually need my eye — not background hum. Specifically `shouldDropTrack` filters them post-AI:
- `ownership=watching` + `priority=low` → always dropped.
- `ownership=watching` + `priority=medium` + `category ∈ {follow_up, discussion}` + empty `blocking` → dropped.
- Anything else (`ownership=mine|delegated`, or watching+high, or watching+medium with a blocking signal) → kept.

**Why locked:** The "watching" lane was added so managers/leads see decisions and blockers in their area without owning every line. Without the filter the LLM tends to widen "watching" into a firehose of every adjacent discussion, which collapses the lane back into noise and managers stop checking it. This contract is what keeps the manager use case viable.

**Tracked gap:** No direct unit test today — the rule lives only in `internal/tracks/pipeline.go::shouldDropTrack`. Integration tests cover storeTrackItems but don't pin the filter table. Need a focused `TestTracks03_WatchingLowAlwaysDropped` / `TestTracks03_WatchingMediumDiscussionDropped` / `TestTracks03_WatchingMediumWithBlockingKept` table test before this can be marked Enforced.

**Test guards (partial):**
- _(none yet — see Tracked gap)_

**Locked since:** 2026-04-28

## TRACKS-04 — Read once, stay read; re-surface only on real change

**Status:** Enforced

**Observable:** When I open a track:
- Its source digests are also marked read (cascade through `related_digest_ids`). I never see a digest light up as unread for content I already saw via its track.
- `has_updates` clears on read.

When the AI re-extracts a track I've already read and there's actually new content:
- `has_updates` flips back to `1` (only if the track was previously marked read — first-time updates on never-read tracks don't artificially flip the flag).

**Why locked:** This is the entire unread-tracking surface. Without the cascade, digests linger in the feed as unread forever after the user reads the surfaced track, and the badge counts diverge from reality. Without the conditional re-surface, every daemon cycle would either flip everything to "updated" (badge spam) or never flip anything (silent drift) — the read-aware re-surface is what makes the badge mean something.

**Test guards:**
- `internal/db/tracks_test.go::TestMarkTrackRead_CascadeDigests`
- `internal/db/tracks_test.go::TestUpsertTrack_Update`
- `internal/db/tracks_test.go::TestMarkTrackRead`
- `internal/db/tracks_test.go::TestSetTrackHasUpdates`
- `internal/tracks/pipeline_test.go::TestMarkTrackRead`

**Locked since:** 2026-04-28

## TRACKS-05 — AI cannot edit a track it doesn't own

**Status:** Partial

**Observable:** When the LLM returns `existing_id: N` to update a track, the pipeline checks `GetTrackAssignee(N) == current_user_id`. Mismatch (or missing track) → the `existing_id` is dropped, the item flows to the create-with-dedup path, and the existing track is untouched. A hallucinated or stale `existing_id` cannot corrupt another user's track or clobber an unrelated thread.

**Why locked:** The existing_id update path bypasses fingerprint/text dedup — it's a direct write. Without the owner gate, a single AI hallucination could rewrite the wrong track's text/priority/ownership, and the user would see "their" track suddenly become someone else's content. In multi-user setups (shared workspace DB, Desktop reading the same SQLite as the daemon) this is also a privacy boundary.

**Tracked gap:** Currently tested only by code-path inspection. Need explicit unit tests: `TestTracks05_ExistingIDOwnerMismatchFallsThroughToCreate` and `TestTracks05_ExistingIDMissingFallsThroughToCreate`. Also worth a test for the "owner matches → update succeeds" happy path with a different user as bystander, to pin the gate exactly.

**Test guards (partial):**
- _(none yet — see Tracked gap)_

**Locked since:** 2026-04-28

## TRACKS-06 — Re-extraction never narrows history

**Status:** Enforced

**Observable:** When a track is updated by extraction, its `channel_ids` and `related_digest_ids` arrays grow — they're merged with the new values placed first, deduped against existing values. A track that originally surfaced in `#backend` and later resurfaces in `#frontend` ends up with both channels recorded; the UI's "Open in Slack" picks the freshest channel (index 0 of merged), but the historical channel is still there for context. Same for digest IDs — the chain back to source content is never trimmed.

**Why locked:** When a thread spans multiple channels (e.g. an incident discussed in `#incidents`, then post-mortemed in `#postmortems`), losing earlier channels on re-extraction would orphan the user from where the conversation actually started. The "Open in Slack" deep-link must remain accurate even when extraction re-runs. Replacing the array (instead of merging) would also retroactively rewrite history, which is hostile in a forensic tool.

**Test guards:**
- `internal/db/tracks_test.go::TestUpdateTrackFromExtraction`
- `internal/db/tracks_test.go::TestMergeJSONArrays`

**Locked since:** 2026-04-28

## TRACKS-07 — Dismiss is final and excludes by default

**Status:** Partial

**Observable:** Dismissing a track removes it from every default list (`GetAllActiveTracks`, `GetTracks` without `IncludeDismissed`), from the Desktop tracks tab, and from the LLM prompt context (`formatExistingTracks` builds from `allActiveTracksRef`, which excludes dismissed). It also no longer appears in any cross-channel/dedup checks — once dismissed, the AI can rediscover the same situation as a fresh track only if the user explicitly restores it (`RestoreTrack`).

`dismissed_at` is the only "negative" state. There is no `done` / `resolved` / `archived` for tracks — dismiss is the single user-driven removal action.

**Why locked:** Dismiss is the user's "I've handled this / I don't care" signal. If dismissed tracks bled back into the prompt context, the AI would propose to recreate them on the next cycle and the dismiss action would feel broken. If they bled into the feed, the user loses the only available cleanup tool. Adding new "negative" statuses (`resolved`, `archived`, etc.) without explicit owner approval splits the cleanup surface and re-introduces the inbox-zero pressure tracks were designed to avoid.

**Tracked gap:** No explicit "dismissed-not-shown" test. Existing tests cover the active path but never assert that a dismissed track is excluded from `GetAllActiveTracks`, `formatExistingTracks`, or the dedup helpers (`FindSimilarTrack`, `FindTracksByFingerprint`). Need: `TestTracks07_DismissedExcludedFromActiveList`, `TestTracks07_DismissedNotInPromptContext`, `TestTracks07_DismissedDoesNotBlockRediscovery`.

**Test guards (partial):**
- `internal/db/tracks_test.go::TestGetAllActiveTracks` (implicit — only inserts active rows)
- `internal/db/tracks_test.go::TestGetTracks_Filters` (implicit — `IncludeDismissed` defaults to false)

**Locked since:** 2026-04-28

## Changelog

- 2026-04-28: file created with 7 contracts (TRACKS-01..07). Four are Enforced (01, 02, 04, 06), three are Partial with explicit tracked gaps (03 watching-lane filter has no unit test, 05 cross-user gate has no unit test, 07 dismissed-exclusion has only implicit tests). Existing tests are referenced under their current names; renaming to `TestTracks0N_…` convention is a follow-up so the four soft-protection layers all engage.
