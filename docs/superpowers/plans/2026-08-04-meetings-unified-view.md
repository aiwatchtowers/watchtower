# Meetings Unified View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge the Calendar tab's Events|Recordings split into one master-detail "Meetings" screen where recordings live inside their meeting and an ad-hoc recording is a meeting without an event.

**Architecture:** A pure `MeetingListBuilder` merges the existing `CalendarViewModel.dailyEvents` window with the existing `fetchRecordingList` projection into day sections of `MeetingListEntry` (event-backed or recording-backed). A new `MeetingDetailView` renders the right pane: event header + prep swap-in + recordings selector + the existing embedded `RecordingDetailView`. `CalendarEventsView` loses `CalendarMode` and drives everything off one `MeetingSelection`.

**Tech Stack:** SwiftUI (macOS 14+), GRDB, XCTest. Swift only — no Go, no DB schema changes.

**Spec:** `docs/superpowers/specs/2026-08-04-meetings-unified-view-design.md` (owner-approved).

## Global Constraints

- English-only repo content (code, comments, tests, commits).
- Perf guard: the list path must never select `transcript_text`/`summary_json`/`segments_json`/`speakers_json`/`chapters_json` — `fetchRecordingList` stays the only recordings input (its `snippet` is already capped at 200 chars).
- `RecordingDetailView`, its tabs, and everything below it (transcript/notes/chat internals, recorder center) are UNCHANGED. It is embedded via its existing init: `RecordingDetailView(transcriptID:onDeleted:onChanged:onOpenEvent:)`; requires `AppState` in the SwiftUI environment.
- `MeetingPrepDetailView(eventID:viewModel:userNotes:onClose:)` is reused UNCHANGED (pane-swap, not inline embedding — avoids nested-ScrollView collapse, the `SituationDiscussInputBar` house gotcha).
- Record affordance must not render for ended events (`event.endDate < Date()`).
- Do not weaken, rename, or split guard tests. Existing test files being replaced must have their real assertions migrated, not dropped.
- Verification discipline: `cd WatchtowerDesktop && swift build > <scratchpad>/build.log 2>&1; echo "exit=$?"` — check real exit codes, never pipe through `tail`. Focused `swift test --filter` while iterating; full relevant targets before commit.
- Update `docs/app-guide.md` (house rule — it is injected into the chat system prompt).

## Reference shapes (read-only context for all tasks)

- `DayEvents` (`Sources/ViewModels/CalendarViewModel.swift:4-8`): `{ id: Date, label: String, events: [CalendarEvent] }`; `dailyEvents: [DayEvents]` is ascending, −`historyDays`..+7d.
- `RecordingListItem` (`Sources/Models/RecordingListItem.swift:8-21`): `id: Int64, eventID: String?, eventTitle: String?, title: String, durationSec: Int, langStats: String, createdAt: String, hasRecap: Bool, hasNotes: Bool, snippet: String`.
- `CalendarEvent` has `startDate: Date`, `endDate: Date`, `isAllDay`, `conferenceLink`, `parsedAttendees`, `plainDescription`, `htmlLink`.
- Current wiring to replace: `CalendarEventsView.swift:43-119` (mode Picker, `eventsSplitView`, `openLinkedEvent`), `:437-442` (EventRecordingsSection deep link), `:371` (row record button), `:374-377` (inline expansion), `:385-445` (`eventDetail`).

---

### Task 1: MeetingList model + MeetingListBuilder (pure) + tests

**Files:**
- Create: `WatchtowerDesktop/Sources/Models/MeetingList.swift`
- Modify: `WatchtowerDesktop/Sources/Models/RecordingListItem.swift` (add `createdDate` computed)
- Test: `WatchtowerDesktop/Tests/MeetingListBuilderTests.swift`

**Interfaces:**
- Consumes: `DayEvents`, `CalendarEvent`, `RecordingListItem` (existing).
- Produces (Tasks 2-3 rely on these exact names):

```swift
enum MeetingSelection: Hashable {
    case event(String)      // calendar_events.id
    case recording(Int64)   // meeting_transcripts.id (ad-hoc / pruned-event)
}

struct MeetingListEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case event(CalendarEvent, recordings: [RecordingListItem])
        case recording(RecordingListItem)
    }
    let kind: Kind
    var id: MeetingSelection      // .event(event.id) / .recording(item.id)
    var sortDate: Date            // event.startDate / item.createdDate ?? .distantPast
    var recordingCount: Int       // recordings.count / 1
}

struct MeetingDaySection: Identifiable, Equatable {
    let id: Date                  // startOfDay
    let label: String
    let entries: [MeetingListEntry]
}

enum MeetingListBuilder {
    /// days: CalendarViewModel.dailyEvents (ascending). recordings: full
    /// fetchRecordingList output (any order). Output ordering: sections with
    /// id >= startOfDay(now) first, ascending ("upcoming"), then sections
    /// with id < startOfDay(now) descending ("past"). Entries inside a
    /// section ascending by sortDate for today/future days, descending for
    /// past days.
    static func build(days: [DayEvents], recordings: [RecordingListItem],
                      now: Date, calendar: Calendar) -> [MeetingDaySection]
    /// Longest recording wins (the real one beats a 1-second test blip);
    /// ties broken by newest createdAt. Nil for empty input.
    static func defaultRecordingID(_ recordings: [RecordingListItem]) -> Int64?
}
```

Build rules (implement exactly):
1. Index recordings by `eventID`. A recording folds into an event entry iff its `eventID` matches an event present in `days`. Folded recordings sorted by `createdDate` ascending.
2. Every remaining recording (nil `eventID`, or event not in `days` — pruned/out-of-window) becomes a standalone `.recording` entry in the section for `calendar.startOfDay(for: createdDate)`. A recording with unparseable `createdAt` goes to the OLDEST existing past section (never dropped, never crashes).
3. Sections come from the union of event days and recording-only days. Event days keep their existing `DayEvents.label`. Recording-only days get labels from the same style: "Today"/"Yesterday" via `calendar.isDateInToday/isDateInYesterday`, else `Date.FormatStyle` matching the builder test fixtures (`.dateTime.weekday(.abbreviated).month(.abbreviated).day()` — e.g. "Thu, Jul 31").
4. An event with zero recordings is still an entry (`recordings: []`).
5. `createdDate` on `RecordingListItem`: computed property parsing `createdAt` with an ISO8601 formatter matching how the CLI writes it (`strftime('%Y-%m-%dT%H:%M:%SZ','now')` — i.e. `ISO8601DateFormatter` default options); returns `Date?`.

- [ ] **Step 1: Write the failing tests** (`MeetingListBuilderTests.swift`) — real fixtures, no mocks. Cover, as separate test methods:
  1. `testFoldsRecordingsIntoMatchingEvent` — 1 day, 1 event, 2 recordings with its eventID → one `.event` entry, `recordingCount == 2`, folded ascending.
  2. `testAdHocRecordingBecomesStandaloneEntry` — recording with `eventID == nil` → `.recording` entry in its own day section.
  3. `testPrunedEventRecordingDegradesToStandalone` — recording with an eventID matching NO event in `days` → standalone `.recording` entry.
  4. `testOrderingUpcomingAscendingThenPastDescending` — days [-2d, -1d, today, +1d] → section order [today, +1d, -1d, -2d]; entries inside today/future ascending, inside past descending.
  5. `testRecordingOnlyDayBeyondCalendarWindow` — recording 30 days old (no event day exists there) → new past section appended with correct label and position (descending past order).
  6. `testEventWithoutRecordingsKeptWithZeroCount`.
  7. `testDefaultRecordingIDPicksLongest` — durations [1, 984] → 984's id; tie → newest `createdAt`; empty → nil.
  8. `testUnparseableCreatedAtLandsInOldestPastSection`.
  Build fixture helpers locally in the test file (`makeEvent(id:start:)`, `makeRecording(id:eventID:createdAt:duration:)`) with a fixed `now` and `Calendar` (UTC, fixed timeZone — no date-bombs: derive all fixture dates relative to the fixed `now`, never hardcoded calendar dates that age).
- [ ] **Step 2: Run to verify failure:** `cd WatchtowerDesktop && swift test --filter MeetingListBuilderTests` → compile error (types not defined). Record output.
- [ ] **Step 3: Implement `MeetingList.swift` + `createdDate`** per the interface block above. Pure functions, no I/O, no `Date()` calls inside the builder (always the `now` parameter).
- [ ] **Step 4: Run to verify pass:** same filter, all green, output pristine.
- [ ] **Step 5: Commit** `feat(desktop): meeting list model + builder for unified meetings view`

### Task 2: MeetingDetailView + list row components

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Calendar/MeetingDetailView.swift`
- Create: `WatchtowerDesktop/Sources/Views/Calendar/MeetingRecordingRow.swift`
- Test: `WatchtowerDesktop/Tests/MeetingDetailViewTests.swift`

**Interfaces:**
- Consumes from Task 1: `MeetingSelection`, `MeetingListEntry`, `MeetingListBuilder.defaultRecordingID`.
- Consumes existing: `RecordingDetailView(transcriptID:onDeleted:onChanged:onOpenEvent:)`, `MeetingPrepDetailView(eventID:viewModel:userNotes:onClose:)`, `CalendarQueries.EventLink`, `TranscriptFormatting`, `TranscriptLangBadges`, `JoinMeetingAction` (see current `joinButton`, `CalendarEventsView.swift:215` area), `appState.meetingRecorderCenter` record affordance logic (`recordButton`, `CalendarEventsView.swift:189-213` — lift this logic, do not duplicate its center-state conditions; move the helper here or into a shared extension so ONE copy exists).
- Produces (Task 3 relies on):

```swift
struct MeetingDetailView: View {
    let entry: MeetingListEntry          // resolved by the list screen
    @Bindable var prepVM: MeetingPrepViewModel
    @Binding var userNotes: String
    let onDeleted: () -> Void            // recording deleted → list reload
    let onChanged: () -> Void            // recording linked/renamed → list reload
    let onOpenEvent: (CalendarQueries.EventLink) -> Void
}

struct MeetingRecordingRow: View {       // list row for a .recording entry
    let item: RecordingListItem
    let isSelected: Bool
}
```

Structure of `MeetingDetailView` (implement exactly this composition):
- `@State private var showPrep = false`, `@State private var selectedRecordingID: Int64?`.
- `.event(let event, let recordings)` case:
  - When `showPrep`: render `MeetingPrepDetailView(eventID: event.id, viewModel: prepVM, userNotes: $userNotes, onClose: { showPrep = false })` as the WHOLE pane (pane-swap; prep view is unchanged and owns its own scrolling).
  - Otherwise a `VStack(spacing: 0)`:
    1. Header block (fixed, not scrolling): title (`.title3.semibold`), time range + duration (reuse `event.formattedTimeRange`/`durationText`), attendee count + attendees inside a collapsed `DisclosureGroup` (migrate rows + `responseIcon`/`responseColor` helpers from `CalendarEventsView.swift:399-416, 449-465`), `plainDescription` with `.lineLimit(3)`, and an `HStack` of buttons: "Prepare" (`showPrep = true` + `prepVM.generate(eventID:)` — mirror current behavior at `CalendarEventsView.swift:354-359`), Join (only when `event.conferenceLink != nil`), Record (ONLY when `event.endDate > Date()` — the lifted record-button helper), "Open in Google Calendar" link.
    2. Recordings selector: nothing when `recordings.isEmpty` (show a one-line secondary "No recordings" caption); when `recordings.count > 1`, a horizontal row of compact selectable chips (start time via `TranscriptFormatting.formattedDate`, duration via `formatDuration`); single recording → no selector chrome.
    3. When a recording is selected (`selectedRecordingID`, initialized in `.onAppear`/`.onChange(of: entry.id)` to `MeetingListBuilder.defaultRecordingID(recordings)`): `RecordingDetailView(transcriptID:onDeleted:onChanged:onOpenEvent:)` filling remaining space (it owns its scrolling). No recordings → `Spacer()`.
- `.recording(let item)` case: `RecordingDetailView(transcriptID: item.id, ...)` directly, full pane.

`MeetingRecordingRow`: waveform icon + `item.title` + `formattedDate(createdAt)` + `formatDuration(durationSec)` + `TranscriptLangBadges(langStatsJSON:)` + recap/notes dots (`hasRecap`/`hasNotes`), selected-state background — visual weight matching `CalendarEventRow`.

- [ ] **Step 1: Write failing tests** (`MeetingDetailViewTests.swift`). View-logic level, following the house pattern in `RecordingsViewTests.swift`/`CalendarEventRowViewTests.swift` (instantiate views/inspect logic, not snapshotting): (a) record affordance hidden for an ended event and visible for a future one — test the extracted gating helper directly (e.g. `MeetingDetailView.showsRecordButton(for:now:)`, a pure static you MUST create for this); (b) initial `selectedRecordingID` equals `defaultRecordingID` of the entry's recordings; (c) `.recording` entry renders detail for exactly `item.id` (assert via the same pure resolution helper, e.g. `MeetingDetailView.embeddedTranscriptID(...)`).
- [ ] **Step 2: Run to verify failure:** `swift test --filter MeetingDetailViewTests` → compile error.
- [ ] **Step 3: Implement both files** per the composition above. Keep every migrated snippet (attendee rows, record/join buttons) a MOVE, not a copy — Task 3 deletes the originals; note in the report which originals become dead.
- [ ] **Step 4: Run to verify pass**, plus `swift build` exit 0 (originals still present — expect an unused-warning-free build; duplication is temporary until Task 3 deletes them).
- [ ] **Step 5: Commit** `feat(desktop): meeting detail pane with embedded recording view`

### Task 3: Rewire CalendarEventsView, delete the Recordings tab, update tests + app guide

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Calendar/CalendarEventsView.swift` (major), `WatchtowerDesktop/Sources/Views/Calendar/CalendarEventRow.swift` (badge), `docs/app-guide.md`
- Delete: `RecordingsView.swift`, `RecordingsListView.swift`, `EventRecordingsSection.swift`, `Tests/CalendarModeTests.swift`
- Test: update `Tests/RecordingsViewTests.swift` → rename `MeetingsScreenTests.swift` (migrate list-reload/selection assertions to the new wiring), update `Tests/RecordingsListViewTests.swift` → fold real assertions into `MeetingsScreenTests.swift` and delete the file, update `Tests/EventRecordingsSectionTests.swift` → delete (contract replaced by Task 1 fold tests + selector), update `Tests/CalendarEventRowViewTests.swift` (badge; row Record removal).

**Interfaces:**
- Consumes: everything Tasks 1-2 produce.
- Produces: none (terminal task).

Rewiring spec for `CalendarEventsView`:
1. State becomes: `selectedMeeting: MeetingSelection?`, `recordings: [RecordingListItem]`, `sections: [MeetingDaySection]`, plus surviving `meetingPrepVM`, `userNotes`, `expandedAllDayDates`, `scrollTargetEventID`, sheet flags. DELETE `mode`, `selectedRecordingID`, `expandedEventID`, `selectedEventID`.
2. `body`: drop the Picker; always render the split view: master `meetingsList` (min 300 / ideal 350) + detail `MeetingDetailView(entry:...)` when `selectedMeeting` resolves to an entry in `sections` (resolution helper `entry(for: MeetingSelection) -> MeetingListEntry?`), `.id(entry.id)` + the existing slide transition.
3. Recordings load: `loadRecordings()` via `MeetingTranscriptQueries.fetchRecordingList` on `.onAppear` and `.onChange(of: appState.meetingRecorderCenter.savedTick)` (mirror the deleted `RecordingsView.swift` — same off-main read pattern, savedTick contract comment included).
4. Sections rebuild: `sections = MeetingListBuilder.build(days: vm.dailyEvents, recordings: recordings, now: Date(), calendar: .current)` — recompute in `.onChange` of both inputs.
5. `meetingsList`: `ForEach(sections)` → day header (existing style) + entries: `.event` → `CalendarEventRow(event:recordingCount:)` (add badge param: `"N rec"` caption badge when > 0; REMOVE the row-level record/prepare buttons — they live in the detail now; keep the row Join button for rows whose event has a conference link and hasn't ended); `.recording` → `MeetingRecordingRow`. Row tap sets `selectedMeeting = entry.id`. Keep `scrollToToday` (first section is today — scroll to top of past boundary works as before via section ids) and `scrollTargetEventID` mechanics (`.id(event.id)` anchors stay).
6. `openLinkedEvent` (recording→event): body becomes `ensureVisible` + all-day expansion (unchanged) + `selectedMeeting = .event(link.id)` + `scrollTargetEventID = link.id`. No mode, no expandedEventID.
7. Delete `eventsSplitView`/`eventsList` merge leftovers, `eventDetail`, `recordButton`/`joinButton` originals (moved in Task 2 — keep exactly one copy at the new location; `UpcomingMeetingBannerView` has its own Join/Record, untouched), `responseIcon`/`responseColor` originals, the `EventRecordingsSection` usage, and the three deleted files + `CalendarMode` enum.
8. `docs/app-guide.md`: replace the Events|Recordings description with the unified Meetings screen (list merge rule, detail composition, ad-hoc = meeting without event, record hidden on past meetings).

- [ ] **Step 1: Update/write failing tests first** — `MeetingsScreenTests.swift`: (a) `entry(for:)` resolution across `.event`/`.recording`; (b) savedTick-driven reload contract migrated from `RecordingsViewTests`; (c) `CalendarEventRowViewTests`: badge renders for `recordingCount > 0`, row has no record affordance anymore (assert the accessibility/label absence the way the existing row tests assert presence). Delete `CalendarModeTests.swift`, `EventRecordingsSectionTests.swift` in the same commit as their subjects.
- [ ] **Step 2: Run to verify failure:** `swift test --filter 'MeetingsScreenTests|CalendarEventRowViewTests'` → compile/assert failures.
- [ ] **Step 3: Implement the rewiring + deletions** per spec above.
- [ ] **Step 4: Full verification:** `swift build` exit 0; `swift test` (FULL suite — this task touches shared wiring) exit 0; `swiftlint lint --quiet` clean on changed files if installed.
- [ ] **Step 5: Update `docs/app-guide.md`**, re-run nothing (docs).
- [ ] **Step 6: Commit** `feat(desktop): unified meetings screen replaces Events|Recordings split`

---

## Self-review notes

- Spec coverage: Decisions 1-5 → Tasks 1 (list/order/fold), 2 (detail, selector, record gate), 3 (one screen, deletions, deep links, app-guide). Deleted-components list fully mirrored in Task 3. Testing section mirrored across tasks. Non-goals respected (no Go changes anywhere).
- Type consistency: `MeetingSelection`/`MeetingListEntry`/`MeetingDaySection`/`defaultRecordingID` names identical across tasks; `MeetingDetailView` init consumed by Task 3 matches Task 2's Produces block.
- The two pure helpers Task 2's tests need (`showsRecordButton(for:now:)`, `embeddedTranscriptID`) are explicitly required by Step 1 so the implementer cannot skip testability.
