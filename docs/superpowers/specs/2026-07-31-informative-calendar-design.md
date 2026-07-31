# Informative Calendar: Meeting Reminders, Banner, Countdown, Past Events

**Date:** 2026-07-31
**Status:** Approved by owner
**Scope:** Make the calendar proactive: local push N minutes before a meeting (with Join actions), a stop-recording push when the event ends, a global in-app countdown banner, relative countdowns in the event list, and browsable past events.

Depends on: Meet Join spec (`2026-07-31-meet-join-autorecord-design.md`) for the Join action / `conference_url`; Quick Wins A2 for the recordings section shown on past events. Both soft dependencies — each surface degrades gracefully (no link → reminder without Join button).

---

## Current state (verified)

- `NotificationService` (UNUserNotificationCenter) already exists with permission handling, quiet hours, stable FNV-1a ids, and a settings pane — but every notification is immediate (`trigger: nil`); there are no scheduled triggers and no notification action buttons yet. Delegate is installed (`WatchtowerApp.swift:64`).
- Watcher precedent: `DigestWatcher` (60 s poll loop started from AppState) — the established "DB/state → poll → notify" pattern. Calendar data polls via `CalendarViewModel.startObserving()` (30 s).
- Global overlay precedent: `RecordingIndicatorView` mounted at `WatchtowerApp.swift:71` (`.overlay(alignment: .bottomTrailing)`), state on an `@Observable` center living on AppState; `.environment(appState)` must stay outermost (see project memory on overlay scope).
- Event list shows absolute times only; "time until" exists solely in the sidebar (`SidebarView.swift:93`, `.relative` style). `isUpcoming` = starts within 1 h (`CalendarEvent.swift:124`).
- Sync window: `timeMin = now − 24 h` (`internal/calendar/sync.go:47`); the per-calendar stale-delete then removes anything not re-fetched, so history older than a day disappears from the DB.

## Design

### 1. `MeetingReminderCenter` (new, Swift)

An `@Observable` service on `AppState` (DigestWatcher pattern): a poll loop (30 s) reads upcoming events via `CalendarQueries` and drives all reminder surfaces. All state in-memory; delivered-reminder dedup keyed by `event.id + kind` and reset when the event's start time changes (reschedules re-notify).

Delivery model: notifications fire while the app is running (owner-approved; the app is effectively always running since it keeps the daemon alive). No pre-scheduled `UNCalendarNotificationTrigger`, no helper process.

### 2. Pre-meeting push

- Fires once per event when `start_time − now ≤ N minutes` (setting `calendar.reminderMinutes`, default 5; `0` disables). Skips all-day events and events already started when first observed.
- Content: title = event title, body = "Starts in N min · HH:mm–HH:mm".
- **Notification actions** (new `UNNotificationCategory`, registered next to the existing delegate): "Join" and "Join + Record" when the event has a `conference_url` (both route through the shared Join action; "Join" respects nothing else, "Join + Record" forces recording regardless of the auto-record setting). Without a link the push is plain.
- Respects the existing quiet-hours setting and the master notification toggles; new "Meeting reminders" toggle + minutes stepper in `NotificationSettings`.

### 3. Stop-recording push

- Condition: `meetingRecorderCenter.phase == .recording` with a non-nil `currentEventID`, and that event's `end_time + 2 min grace < now`.
- Push "Meeting ended — still recording" with a "Stop recording" action (calls `stopAndProcess`). Re-fires every 10 minutes while the condition holds (dedup key includes a fire-count window).
- Ad-hoc recordings (no event) are exempt (owner chose event-end trigger only).

### 4. Upcoming-meeting banner (global overlay)

- `UpcomingMeetingBannerView`, mounted in `WatchtowerApp` alongside `RecordingIndicatorView` (separate alignment, e.g. `.top`), driven by `MeetingReminderCenter.bannerEvent`.
- Appears when the next event starts within N minutes (same setting), shows event title + live countdown (`TimelineView(.periodic(by: 1))`, mm:ss), buttons: Join (when link), Record, Dismiss.
- Disappears on dismiss (per-event, remembered), on join/record, or once the event is 5 min past its start. Never overlaps the recording indicator's corner.

### 5. Countdown in the event list

- `CalendarEventRow`: for `isUpcoming` events append a relative suffix ("in 25 min") using `Text(startDate, style: .relative)` next to the absolute range; keep the existing color highlighting.

### 6. Past events (browsable history)

- **Go:** new config `calendar.history_days` (default 14, floor 1). `sync.go`: `timeMin = now − history_days`. The existing stale-delete then naturally retains the same window — no cleanup change needed. Applies to Google and CalDAV syncers alike.
- **Swift:** `CalendarViewModel` loads `[−history, +7 d]` (history days read from the same config via ConfigService, fallback 14). The Events list renders past day sections dimmed (secondary foreground, no upcoming highlight), scrolls to "Today" on appear via `ScrollViewReader`. Past events expand like any other — with the A2 "Recordings" section this makes past meetings workable (recap, transcript, chat).
- First sync after the change backfills 14 days automatically (window widening; no migration needed).

## Error handling

- Notification permission denied → reminder surfaces silently disabled except the in-app banner and list countdown (which need no permission); `NotificationSettings` already surfaces the denied state.
- Event deleted/moved between poll ticks → dedup key mismatch simply produces no or one new reminder; no crashes on missing rows.

## Testing

- Swift: `MeetingReminderCenter` decision logic as pure functions (given events + now + settings → which reminders fire): pre-meeting threshold, dedup, reschedule re-fire, stop-push grace + 10-min repeat, banner visibility window. Degenerate inputs (all-day, already-started, no events) per the "test degenerate clean-exit branches" rule.
- Go: sync window test (event 10 days old survives sync with history_days=14; event 20 days old is not fetched and gets stale-deleted).

## Out of scope

- Menu-bar extra (not selected).
- Notifications while the app is closed.
- Editing calendar events from Watchtower.
