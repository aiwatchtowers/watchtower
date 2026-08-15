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

1. Discuss chat: `ChatConversationQueries.fetchByContext(db, type: "idea",
   id: String(id))` → if present, `ChatMessageQueries.deleteByConversation` +
   `ChatConversationQueries.delete`. (Note: chat queries live in the app
   target today; the parts `delete` needs move/are made callable from
   WatchtowerCore, or the delete lives at the level where both are visible —
   implementation detail, but the whole delete stays one transaction.)
2. Null out back-references on *other* rows — `similar_to_id`,
   `merged_into_id`, `superseded_by_id` `WHERE ... = id`. These columns carry
   no FK, so without this a deleted merge-survivor leaves dangling links the
   consolidator would follow.
3. `DELETE FROM idea_mentions WHERE idea_id = ?` (explicit, though the FK is
   `ON DELETE CASCADE` — independent of the connection's FK pragma), then
   `DELETE FROM ideas WHERE id = ?`.

**ViewModel:** `IdeasViewModel.deleteIdea(_ idea: Idea)` via the shared
`write` helper; the existing `reconcileSelection()` moves selection to a
neighbour after the reload.

**UI:** a destructive "Delete" button (trash icon) in `IdeaDetailPane`'s
action bar, available for **every kind and every status**, guarded by a
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
  entry's kind and selects it, so the new entry is visible immediately.
- Empty state: per-segment (an empty Notes segment must not claim
  "No ideas yet" while ideas exist — text keys off the segment).

### 3. Tests

- `Tests/Core/IdeaQueriesTests.swift` (fast, no ML link):
  - delete removes the row, its mentions, and its chat conversation+messages;
  - unrelated ideas/mentions/chats untouched;
  - back-references on surviving rows are nulled;
  - deleting an idea with no chat is a clean success (degenerate branch).
- `Tests/IdeasViewModelTests.swift`:
  - `deleteIdea` reloads and moves selection off the deleted id;
  - `kindMode` filters both review queue and registry;
  - `createManual` flow switches segment to the created kind and selects it.

## Non-goals

- No CLI/Go delete path (Swift-only writes are the established dual-path
  exception for owner UI actions; the Go side never reads a deleted row's id).
- No undo/tombstone/anti-resurrection table (owner explicitly chose plain
  hard delete).
- No changes to the consolidator, mining, floors, or any IDEA-01..05 guard.
