# Meetings Unified View — Design

**Date:** 2026-08-04
**Status:** Approved by owner (conversation, 2026-08-04)
**Scope:** Swift/Desktop only. No Go, no DB, no schema changes.

## Problem

Meeting content is scattered across two sub-screens of the Calendar tab. The Events list shows prep and an inline expansion; recordings live in a separate Recordings tab reached via deep links; the recap of a meeting is only readable inside a recording's detail. A recording is conceptually part of its meeting, and an ad-hoc recording is conceptually a meeting without a calendar event — the Events|Recordings split is an artifact of implementation history ("Recordings as a tab is a crutch" — owner).

Secondary fix rolled into this work: the per-event Record button currently renders for past events too; it must be hidden once the meeting has ended.

## Decisions (owner-approved)

1. **One screen.** The `CalendarMode` Events|Recordings segmented control dies. The Calendar tab becomes a single master-detail "Meetings" screen.
2. **One list.** Left column: one chronology — upcoming meetings on top (ascending, "Today" anchored like today's scroll behavior), then the past in descending day sections. An ad-hoc recording is a list item of its own, placed at its recording time. An event with recordings is ONE item (badge `N rec`).
3. **Recording content lives inside the meeting.** The right pane is a meeting detail that embeds the existing `RecordingDetailView` (player + Recap/Notes/Transcript/Chat tabs) — no duplicated UI, the Recordings master list is deleted.
4. **Multiple recordings → selector.** The meeting detail shows a compact recordings selector (start time, duration, language badges); the selected recording renders the embedded detail below. A single-recording meeting shows no selector chrome — just the embedded detail.
5. **Record button gated by time.** Hidden when `event.endDate < now`. (Join is already conditional on a conference link.)

## Architecture

### Selection model

`CalendarEventsView`'s `mode` + `expandedEventID` + `selectedEventID` + `selectedRecordingID` collapse into one:

```swift
enum MeetingSelection: Equatable {
    case event(String)        // calendar_events.id
    case recording(Int64)     // ad-hoc / event-pruned transcript id
}
@State var selectedMeeting: MeetingSelection?
```

Within an event-meeting detail, the chosen recording is local state of the detail pane (`selectedRecordingID: Int64?`, defaulting to the meeting's longest recording — the real one wins over 1-second test blips).

### List construction — `MeetingListBuilder` (pure, unit-tested)

Inputs: the existing `CalendarViewModel` events window (−`calendar.history_days`..+7 days, unchanged) and `MeetingTranscriptQueries.fetchRecordingList` rows (all recordings, lightweight projection — the perf guard stays: no heavy blobs).

Merge rules:
- Every event in the window → one `MeetingListItem` (`.event`), annotated with its recordings (count, latest duration) by matching `RecordingListItem.eventID`.
- Every recording whose `eventID` is NULL **or** references an event not present in the fetched window (pruned by sync retention or out of range) → one standalone `.recording` item at its `createdAt`, titled by its stored title. This preserves the current Recordings tab's "all history is reachable" property — past day sections extend beyond the calendar window wherever recordings exist.
- Day sectioning reuses the existing `dailyEvents` day-window logic; recording-only days are appended to the past side.

### Detail pane — `MeetingDetailView`

- **`.event` case:** header (title, time range, attendees disclosure, description, Join / Open-in-Google-Calendar links, Record button when not ended) + the existing event-level affordances currently hosted by `MeetingPrepDetailView` (prep generation, meeting notes, topics, recap generate/paste flows) moved in unchanged + recordings section (selector per Decision 4, embedded `RecordingDetailView` for the selection). `RecordingDetailView` is already host-agnostic (`transcriptID` + 3 closures + `AppState` environment) — it embeds as-is.
- **`.recording` case (ad-hoc):** embedded `RecordingDetailView` directly. Its existing "Link to event…" flow stays; after linking, the item folds into the event on next list rebuild.
- The inline `eventDetail` expansion in the list dies; list rows stay compact (time column, title, badges, Join for upcoming). Row-level Record/Prepare buttons move to the detail header (Record gated per Decision 5).

### Deep links (closed loop stays closed)

- `EventRecordingsSection`'s role (list an event's recordings, jump to one) is fully replaced by the recordings selector inside `MeetingDetailView` — the component and its tab-switching contract are deleted.
- `LinkedEventHeader.onOpenEvent` → `selectedMeeting = .event(id)` + existing `ensureVisible`/scroll logic (`scrollTargetEventID` mechanics reused).
- `UpcomingMeetingBannerView` and `RecordingIndicatorView` have no navigation today — unchanged.

### What is deleted

`CalendarMode`, `RecordingsView`, `RecordingsListView`, `EventRecordingsSection` (the `RecordingListItem` + `fetchRecordingList` projection survives as the builder's input), the segmented Picker, the inline `eventDetail` expansion, `CalendarModeTests`.

## Error handling

No new failure modes: the builder is pure; fetches reuse existing queries with their existing async/error paths (`errorMessage` states). A recording whose transcript row disappears mid-session degrades exactly as `RecordingDetailView` does today.

## Testing

- `MeetingListBuilderTests` (new, pure): event+recording folding, ad-hoc placement, pruned-event degradation to standalone item, day sectioning across the calendar-window boundary, upcoming-vs-past ordering, badge counts, longest-recording default selection.
- Update: `RecordingsViewTests` → meeting-detail embedding equivalents; `EventRecordingsSectionTests` → new selection contract; `CalendarEventRowViewTests` → row without Record button for past events.
- Unchanged: `RecordingDetailViewTests` (the embedded view is untouched), `CalendarViewModelTests` (window logic untouched).
- Manual: run the app (`make app-dev`) for visual verification of both panes.

## Non-goals

- No Go/daemon/retention changes: a past meeting with no recording still ages out of the list with calendar sync retention (today's behavior).
- No change to transcript/notes/chat internals, recorder center, or crash recovery.
- No sidebar rename (the tab keeps its current name/icon).

## Docs

`docs/app-guide.md` must be updated (house rule: it is injected into the chat system prompt).
