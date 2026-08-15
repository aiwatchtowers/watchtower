# Ideas Tab: Owner Delete + Ideas/Notes Split — Design

**Date:** 2026-08-15
**Status:** Approved by owner (chat, 2026-08-15)
**Scope:** Desktop only (Swift). No Go changes, no migrations.

## Problem

Two owner requests for the Ideas tab (post decisions-split, PR #101):

1. There is no way to delete an idea or a note. The closest action is "Drop",
   which only flips status and keeps the row visible in the registry.
2. Ideas (`kind='idea'`) and notes (`kind='note'`) are rendered in one mixed
   list; the owner wants them separated.

## Decisions (owner-approved)

- **Hard delete.** Transactional removal of the `ideas` row, its
  `idea_mentions`, and its Discuss chat — the `MeetingTranscriptQueries.delete`
  precedent. The accepted, documented limitation: a *mined* idea whose mentions
  are deleted loses its IDEA-05 dedup anchor, so a later consolidator pass or
  backfill over the same material can legitimately re-mint it. Owner-created
  entries have no minable refs and delete cleanly.
- **Segmented control** `Ideas | Notes` at the top of the list panel (the
  Calendar `Events | Recordings` precedent), replacing the Kind filter picker.

## Design

### 1. Delete

**`IdeaQueries.delete(_ db: Database, id: Int)`** (WatchtowerCore), one
transaction (callers wrap in `dbPool.write`):

1. Collect the doomed set: the id plus everything merged into it,
   transitively, via a recursive CTE over `merged_into_id` (`UNION`, not
   `UNION ALL`, so a merge cycle terminates). The seed id is returned whether
   or not the row exists, which makes deleting an unknown id a clean no-op.
2. For every doomed id: its Discuss chat
   (`ChatConversationQueries.fetchByContext(db, type: "idea", id: String(id))`
   → if present, delete its `chat_messages` then the conversation — chat
   queries live in the app target, so the message delete is mirrored inline in
   WatchtowerCore), then `DELETE FROM idea_mentions WHERE idea_id = ?`
   (explicit, though the FK is `ON DELETE CASCADE` — independent of the
   connection's FK pragma), then `DELETE FROM ideas WHERE id = ?`.
3. Null out back-references on the *survivors* — `similar_to_id` and
   `superseded_by_id` `WHERE ... IN (doomed)`. Neither carries an FK, so
   without this a survivor keeps a dangling link. `merged_into_id` needs no
   pass: every row that could carry one into the chain is itself doomed.

**Why the cascade** (decided in review round 1): a merged row's mentions were
re-parented onto the survivor at merge time (IDEA-03), so what it leaves
behind is a provenance-less husk whose only content is the `merged_into_id`
redirect the Go consolidator follows exactly one hop
(`applyAttachMentionOp`). Nulling that pointer instead — or deleting the
survivor and leaving the husk — makes the redirect fail to resolve, and the
consolidator then lands the repeat mention on the husk itself: a dead
`status='merged'` row the owner can no longer see in either segment. Deleting
the chain whole is the only outcome with no dangling state.

**ViewModel:** `IdeasViewModel.deleteIdea(_ idea: Idea)` via the shared
`write` helper; the existing `reconcileSelection()` moves selection to a
neighbour after the reload.

**UI:** a destructive "Delete" button (trash icon) in `IdeaDetailPane`'s
action bar, available for **every status**, idea or note alike, guarded by a
`confirmationDialog` stating that the entry, its mentions, and its chat are
removed permanently.

**Inventory:** a changelog entry in `docs/inventory/ideas.md`: owner-initiated
hard delete is deliberately outside IDEA-03 (which governs convert/merge
transitions, both unchanged); possible re-minting after delete is an
owner-accepted limitation of IDEA-05's ref-level dedup. No contract wording
changes, no guard tests weakened.

### 2. Ideas / Notes split

- `IdeasViewModel.kindMode: String` (`"idea"` default, `"note"`), lives on the
  VM (AppState-owned) so it survives navigation.
- A segmented `Picker` above the filter bar switches the mode; the Kind
  filter picker is removed. Status picker and search stay as-is.
- `fetchList` receives `kind: kindMode`. `fetchForReview`/`countForReview`
  split: the **review queue is filtered by the active segment** —
  `fetchForReview(db, kind:)` — so a flagged note shows up under Notes rather
  than mixing into Ideas (and is still reachable, keeping IDEA-04's
  clearability intact). The sidebar badge (`countForReview`) stays global
  (proposed + flagged across both kinds).
- `IdeaCreateSheet`: after creating, the VM switches `kindMode` to the created
  entry's kind, clears `statusFilter`/`searchText`, and selects it — the entry
  is born `active`, so an owner's "Proposed" filter or stale search would
  otherwise swallow it and the create would look like it silently failed.
  (A decision created from the Decisions ledger, which shares this VM, leaves
  the Ideas tab exactly as it was — there is no decision segment.)
- Segment labels carry their own review-queue count ("Ideas (3)") via
  `IdeaQueries.reviewCountsByKind`, so a queue waiting in the other segment is
  visible without switching to it.
- Empty state: per-segment (an empty Notes segment must not claim
  "No ideas yet" while ideas exist — text keys off the segment), and
  filter-aware ("No matching notes" when a status filter or search is what
  emptied the list, since that is a different problem with a different fix).
- **Merge candidates are same-kind.** The pool is what the active segment
  loaded, so note↔idea merges are retired by the split — deliberate: merging
  across kinds was never meaningful, and the merge sheet now refuses to
  preselect a `similar_to_id` hint that isn't in the eligible pool rather than
  arming Merge against a target the owner cannot see.

### 3. Tests

- `Tests/Core/IdeaQueriesTests.swift` (fast, no ML link):
  - delete removes the row, its mentions, and its chat conversation+messages;
  - unrelated ideas/mentions/chats untouched;
  - the merged chain cascades (one child, and transitively C→B→A), chats and
    mentions included;
  - back-references on surviving rows are nulled, including one pointing at a
    cascaded child rather than the id the owner clicked;
  - deleting an idea with no chat, and deleting an unknown id, are clean
    successes (degenerate branches);
  - `fetchForReview` filters by kind while `countForReview` stays global;
  - `reviewCountsByKind` counts each segment separately.
- `Tests/IdeasViewModelTests.swift`:
  - `deleteIdea` reloads and moves selection off the deleted id, and takes
    merged children with it;
  - `kindMode` filters both review queue and registry, and exposes the
    per-segment review counts;
  - `createManual` switches segment to the created kind, clears the browse
    filters, and selects it — in both directions, and not for a decision.

## Non-goals

- No CLI/Go delete path (Swift-only writes are the established dual-path
  exception for owner UI actions; the Go side never reads a deleted row's id).
- No undo/tombstone/anti-resurrection table (owner explicitly chose plain
  hard delete).
- No cross-kind merge. Retired by the split (see §2) rather than preserved
  through a second candidate query.
- No changes to the consolidator, mining, floors, or any IDEA-01..05 guard.
