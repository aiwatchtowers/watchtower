# Target "Watch" Tab — Design

**Date:** 2026-07-04
**Branch:** feature/task-ai-agent (in-place)
**Scope:** Desktop-only (WatchtowerDesktop/, SwiftUI). No Go / CLI / schema / migration changes.
**Status:** Approved design → implementation planning

---

## Problem

A target can have **watches** (custom tracks with `linked_target_id == target.id`) and it may have been created **from** an auto-track (`source_type == "track"`, `source_id == <trackID>`). Today these related tracks are only surfaced as a small "Watches" list I added to the target's Details tab, and there is no unified view of what the watches have found. The user wants a dedicated tab on the target that shows the watches and their activity, and wants that activity usable by the target's Assistant to mutate the target.

## Approved decisions (from brainstorming)

- **Related tracks = explicit links only** (deterministic): watches (`linked_target_id`) + the single origin auto-track the target was promoted from (`source_type == "track"`). No fuzzy similarity, no manual attach.
- **Primary role = activity feed**: a unified timeline merging `track_events` from all of the target's watches, plus the ability for the target Assistant to act on that activity.
- **Approach A**: a dedicated **"Watch"** tab (feed + inline watch management); the existing **Assistant** tab additionally receives the watch activity as context, and feed events have a **"Discuss"** jump into the Assistant. One chat, not two.
- **Desktop-only**: watches, `track_events`, `linked_target_id`, `TargetActionExecutor`, and `TrackScanCenter` already exist; the target Assistant builds its prompt in Swift. So this is entirely SwiftUI + GRDB work.

## Architecture & data

New tab `Tab.watch` ("Watch") in `TargetDetailView`, alongside `Details / Links / Assistant`.

New view model `TargetWatchesViewModel` (`@MainActor @Observable`), constructed with `target`, `DatabaseManager`, the shared `AppState.trackScanCenter`, and a `TargetsViewModel` (used to apply proposed actions to the target). State:

- `watches: [Track]` — custom tracks where `linked_target_id == target.id`.
- `originTrack: Track?` — when `target.sourceType == "track"`, `TrackQueries.fetchByID(Int(target.sourceId))`.
- `events: [TrackEvent]` — merged, newest-first activity across all the target's watches.

Reactivity via two GRDB `ValueObservation`s (started in `start()`, cancelled in `stop()`):

- Watches: `TrackQueries.fetchByLinkedTarget(db, targetID:)` (already exists).
- Feed: a new query
  ```
  TrackEventQueries.fetchForTarget(db, targetID:, limit:) -> [TrackEvent]
  SELECT e.* FROM track_events e
  JOIN tracks t ON t.id = e.track_id
  WHERE t.linked_target_id = ?
  ORDER BY e.created_at DESC, e.id DESC
  LIMIT ?
  ```
  This scopes the feed to exactly this target's watches and is reactive to inserts/deletes (cascade).

No Go, schema, or migration changes — everything reuses existing tables and executors.

## The "Watch" tab UI

`watchTab` (a `@ViewBuilder` in `TargetDetailView`, rendered for `Tab.watch`), or a small dedicated `TargetWatchTabView` taking the VM. Two stacked regions:

**1. Watch management strip (top).** For each watch, a row/chip: name, a **Collecting** toggle (`TrackQueries.setEnabled`), a **Scan** control reusing the range popover from `CustomTrackTimelineView` (Since last check / 7-30-90d / Since created / All history / custom date), an unread-count badge, and **Delete** (confirmed; `TrackQueries.delete`, cascades events). Above/beside the list:
- **＋ Watch** → `CustomTrackManagementSheet(linkedTargetID: target.id)`.
- **Scan all** → runs each enabled watch through `TrackScanCenter` (indicators persist across navigation).
- **Origin track** link (when `originTrack != nil`) → `appState.navigateToTrack(originTrack.id)`.

Scan-in-flight spinners read `appState.trackScanCenter.isRunning(watch.id)`.

**2. Activity feed (below).** The merged `events`, each rendered like the existing `TrackEventRow`: source watch name + summary, expandable detail, source links; when `action_status == "pending"` and `decodedAction != nil`, show **Apply** (mutates *this* target via `TargetActionExecutor`) / **Dismiss**, plus **Discuss**. `markRead` fires on row appearance. Empty state: "No watches yet — add a watch to track activity for this goal." with a ＋Watch button.

**Removal:** the `watchesSection` currently in the Details tab (`detailsTab`) is removed — its role moves here to avoid duplication. Keep the target-detail header **"Watch"** button (opens the same create sheet) for quick access.

### Applying a proposed action to the target

`TargetWatchesViewModel.applyAction(for: TrackEvent)` mirrors `CustomTrackTimelineViewModel.applyAction`: decode the event's `ProposedAction`, re-read a **fresh** copy of the target (`TargetQueries.fetchByID`) to avoid lost updates, apply via `TargetActionExecutor.apply(action, target:viewModel:)`, then `TrackEventQueries.setActionStatus(id:, "applied")`. A missing target row surfaces an error rather than silently marking applied. `dismissAction` sets `"dismissed"`.

## Assistant integration

**Auto-context.** `TargetChatViewModel`'s system-prompt builder appends a `=== WATCH ACTIVITY ===` block listing the recent watch events for the target (summary + any pending proposed action), sourced from `TrackEventQueries.fetchForTarget`. The block is omitted when there are no watch events. This lets the assistant reason over what the watches found and propose target mutations through its existing proposed-action mechanism — no new mutation path.

**"Discuss" jump.** A feed event's **Discuss** button sets `selectedTab = .assistant` and seeds the chat input with the quoted event (summary + a nudge like "How should this change the target?"). Implemented via a new `TargetChatViewModel.seedInput(_ text: String)` that sets the bound input field; `TargetDetailView` (which owns `chatVM` and `selectedTab`) wires the button.

Net effect: the "combine watches + assistant" goal is met without a second chat — one-click apply from the feed for the obvious cases, or Discuss → a conversation already primed with the activity.

## Testing

- `fetchForTarget` returns the target's watch events merged newest-first and excludes events from other targets' watches.
- `applyAction` mutates the target (from a fresh copy) and marks the event `applied`; a deleted target surfaces an error instead of marking applied.
- `dismissAction` sets the event `dismissed` without touching the target.
- The `WATCH ACTIVITY` block appears in the target chat system prompt when watch events exist and is absent when none do.
- `seedInput` places text in the assistant input and the Discuss action selects the Assistant tab.
- Empty state shows when the target has no watches; deleting a watch removes its events from the feed (FK cascade).
- Full `swift build` + `swift test` stay green.

## Out of scope

- Fuzzy/topical "related" auto-tracks and manual track-to-target attachment (explicit links only).
- Any Go/CLI/schema change (the target assistant and all data already exist Swift-side).
- A second embedded chat on the Watch tab (Approach B) — rejected to avoid two chats.
