# Secretary Memory — Slice C: Chat Relevant-Memory Unification — Design Spec

> Date: 2026-07-22. Status: direction CONFIRMED by the owner (2026-07-22). Third of four planned slices in the memory-retrieval redesign brainstormed 2026-07-18 (Slice A: importance-score foundation, shipped; Slice B: unified retrieval ranking on the Go side, shipped; Slice D: meta-layer + navigation — not yet designed).
> Background: Slice B's design spec named this slice's remit as "Swift/chat's own `relevantMemory` query" — the one piece of memory retrieval that lives entirely in the SwiftUI Desktop app, reading the shared SQLite mirror directly via GRDB rather than through Go's MCP `memory_recall` tool. Today only `SituationChatViewModel` (the Discuss chat for a `situation`) has this: a `relevantMemory` method that looks up entities and beliefs by raw Slack channel/user-id alias, ranked by `ORDER BY title` and `ORDER BY confidence DESC` respectively — no `importance_score` involved at all, even though that column has existed since Slice A and Go's equivalent (`RetrieveBySubject`) has used it since Slice B. Target/Track chat (`TargetChatViewModel`) and Meeting chat (`MeetingChatViewModel`) have no memory lookup whatsoever today — an asymmetry with Phase 5 slice 2, which already generalized the *write* side (owner statements becoming belief evidence via `chat_ingest.go`'s `targetSubjects`/`trackSubjects`) to target/track chats, but never the *read* side.

## Concept

Generalize Discuss's existing direct-SQL `relevantMemory` mechanism into one shared Swift function usable by all three chat types, upgrade its ranking to use `importance_score` (mirroring Go's `RetrieveBySubject`), and add a new short-term/recent-episodes section (mirroring Go's `ListShortTierEpisodesForAliases`). Each chat type keeps its own logic for *which* subjects (Slack channel ids / user ids / emails) to look up — that "who/what is this chat about" question is inherently different per context type — but all three funnel into the same ranking-and-render function.

This is a Swift-only, single-consumer feature change: unlike Slice B (which redesigned shared server-side retrieval consumed by multiple existing surfaces, requiring a dark compare-mode to prove no regression), Slice C changes what one local chat feature shows to the one owner using it. There is no separate "legacy consumer" to protect, so no compare-mode infrastructure is needed here — the design is evaluated by direct owner review of the chat's own output, not by a shadow-diff mechanism.

## Design

### 1. Shared memory-context builder

New file `WatchtowerDesktop/Sources/Services/Memory/RelevantMemory.swift`, extracted from `SituationChatViewModel.swift`'s current `relevantMemory(memberSignals:dbPool:)` (lines 420-468) and `memorySection`/`cap4KB` (lines 369-402, 472-482), generalized to:

```swift
struct MemoryContextResult {
    let entityLines: [String]
    let beliefLines: [String]
    let recentEpisodeLines: [String]
}

func relevantMemoryContext(subjects: [String], dbPool: DatabasePool) -> MemoryContextResult
func renderMemorySection(hotMap: String, context: MemoryContextResult) -> String  // assembles + applies cap4KB
```

`subjects` replaces today's `memberSignals`-derived `aliasKeys` computation — the caller (each ViewModel) computes its own `subjects: [String]` and passes it in; `relevantMemoryContext` itself is agnostic to where subjects came from. On any query error, log and degrade to an empty `MemoryContextResult` (all three arrays empty) — the existing `relevantMemory`'s never-throw contract, unchanged.

### 2. Ranking and short-term episodes

Two existing queries change their `ORDER BY`; one new query is added. All three keep independent `LIMIT 5` caps (no shared budget) — the existing precedent (`relevantMemory`'s entities and beliefs already each cap independently at 5).

- **Entities** (was `ORDER BY n.title`): `ORDER BY n.importance_score DESC, n.title ASC` — importance primary, title as a deterministic tiebreak for equal (including zero) importance.
- **Beliefs** (was `ORDER BY confidence DESC`): `ORDER BY n.importance_score DESC, n.confidence DESC` — importance primary, confidence as tiebreak; confidence is still rendered in the output line, only the ordering changes.
- **Recent episodes (new)**: mirrors Go's `ListShortTierEpisodesForAliases` (`internal/db/memory.go`) — a derived-table join giving each node its `MAX(ts_unix)` among matching provenance rows, then filtering to short-tier, non-tombstone nodes, ordered by that recency, capped at 5:

```sql
SELECT n.id, n.title
FROM memory_nodes n
JOIN (
    SELECT node_id, MAX(ts_unix) AS max_ts
    FROM memory_provenance
    WHERE sender_id IN (...)
    GROUP BY node_id
) latest ON latest.node_id = n.id
WHERE n.tier = 'short' AND n.status != 'tombstone'
ORDER BY latest.max_ts DESC
LIMIT 5
```

Rendered as a new "Recent activity" subsection after entities and beliefs, e.g. `- <title>` per line — framed model-mediated like the rest of the block (see §4). The final assembled block (hot map + entities + beliefs + recent activity) is still truncated by the existing `cap4KB` as a hard backstop; the three independent `LIMIT 5`s are the primary budget control, `cap4KB` the safety net for pathological cases (very long titles, etc.), unchanged in behavior from today.

### 3. Subject resolution per chat type

Each `*ChatViewModel` gains (or, for Discuss, keeps) its own subject-resolution step feeding the shared builder. All mirror the *relationship* Go's `chatSubjects`/`trackSubjects`/`targetSubjects` (`internal/memory/chat_ingest.go`) already establish for the write side, reimplemented directly in Swift against the same tables (no call into Go) since these are simple, cheap local reads:

- **Situation (Discuss) — unchanged.** `SituationChatViewModel` keeps computing `aliasKeys` from `memberSignals` (channel ids + sender user ids) exactly as today.
- **Target/Track (new).** For a track chat: decode `tracks.channel_ids` (JSON array) + `tracks.participants` (JSON array, take each `.user_id`) + the three scalar columns `assignee_user_id`/`owner_user_id`/`requester_user_id` (skipping nils/empties), plus the literal string `"track:<id>"` (so the track's own mirror entity page, if one exists, can itself surface as a connected entity — mirroring `trackMirrorAlias`'s prepend on the Go write side). For a target chat: the same union across every track where `tracks.linked_target_id = target.id` (`SELECT id FROM tracks WHERE linked_target_id = ?`, the same query Go's `TrackIDsForTarget` uses), plus the literal `"target:<id>"`. A bare target with no linked track yields just its own mirror alias — consistent with the known, accepted limitation already documented for the write side (`chat_ingest.go`'s "a bare target chat maps to nothing" note).
- **Meeting (new).** From the transcript's `event_id` (when set — an ad-hoc recording with no linked event yields no subjects, a clean empty context, not an error), look up `calendar_events.attendees` (JSON array of `EventAttendee`), decode via the existing `CalendarEvent.parsedAttendees`, and collect each attendee's `slackUserID` (when the `calendar_attendee_map` cache has already resolved it) and `email` as subjects.

### 4. Gating and framing

Reuses the existing `memory.surfaces.chat` config flag (`Constants.memorySurfacesChatEnabled()`) rather than introducing a new one — the same precedent Phase 5 slice 2 set for the write side (widening `memory.sources.chats`'s scope instead of minting a per-context-type flag). With the flag off, all three chat types behave exactly as today: Discuss's block stays empty (byte-identical to current behavior), Target/Track and Meeting simply never build a memory block (as now). With the flag on, all three render their (possibly empty) memory context.

New Target/Track and Meeting memory blocks carry the same model-mediated framing label the Discuss block and other memory-derived surfaces already use ("notes the secretary has built from Slack/Jira — model-mediated, verify before acting" or equivalent wording matched to context) — per the project's established convention that vault-derived text is never presented as the owner's own words.

## Non-Goals

- Any Go-side or MCP change. This is entirely a Swift/GRDB change reading the existing, already-shipped schema (`memory_nodes.importance_score`, `memory_provenance.sender_id`, both from Slice A/B).
- Fixing Slice B's known entity-ID/sender-ID mismatch in Go's `RetrieveBySubject` (documented in `docs/inventory/memory.md`'s known-limitations list) — Swift's own subject resolution here is correct by construction (it always passes genuine Slack/email aliases, never an entity id), so this slice does not inherit that bug, but it also does not fix it on the Go side.
- A dark compare-mode or evidence-gated switch, per the Concept section's reasoning — single-consumer local feature, not shared server infrastructure with existing dependents to protect.
- Any new memory node type, meta-layer, or navigation UI — Slice D's remit.
- Changing `SearchMemoryFTS`/`memory_recall`'s advertised-tools bullet in the chat system prompt — that already benefits automatically from Slice B, per Slice B's own Non-Goals.

## Test plan

Following the Swift test conventions already used for `SituationChatViewModel`'s existing memory tests (GRDB `TestDatabase.swift` fixtures, XCTest):

- `relevantMemoryContext`: seeded-fixture tests for each of entities-ranked-by-importance, beliefs-ranked-by-importance (confidence as tiebreak), recent-episodes-ranked-by-recency (including the same-node multi-provenance-row dedup case Go's equivalent test covers), and the empty-subjects / no-match clean-empty-result cases.
- Per-chat subject resolution: one test per chat type confirming the exact subject set built from a seeded track/target/transcript-event fixture (track with channels+participants+scalars; target via one and via two linked tracks; a bare target with no linked track; a transcript with a linked event and attendees; an ad-hoc transcript with no event).
- Gate-off test per chat type: `memory.surfaces.chat` off → the memory block is absent/empty, matching today's Discuss behavior exactly and confirming Target/Track/Meeting stay silent as they are today.
- A byte-identical-when-flag-off regression test for Discuss specifically, since it is the one chat type with pre-existing behavior to preserve.

## Rollout

Lands on its own branch (Slice B's precedent: own branch, own PR, subagent-driven-development execution), based on the current `feature/memory-phase5` tip (Slice B has already merged there; a concurrent, unrelated Jira-source workstream is also landing on the same branch — branch from whichever commit is current at execution time, following Slice A/B's established practice for a shared, actively-developed base branch).
