# Meet Join Button + Auto-Record on Join

**Date:** 2026-07-31
**Status:** Approved by owner
**Scope:** Surface a conference link (Google Meet, Zoom, Teams, …) on calendar events and add a Join button that opens the link and auto-starts an event-linked recording.

---

## Current state (verified)

Conference links are not stored at ANY layer today:

- `googleEvent` (`internal/calendar/client.go:145-161`) does not list `hangoutLink` or `conferenceData` — they are never parsed from the Google API response.
- `raw_json` is effectively empty for Google events: `convertEvent` never fills `RawJSON`, and `sync.go:148-151` substitutes `"{}"` — the link cannot be recovered from stored raw JSON.
- `calendar_events` (`internal/db/schema.sql:844-863`) has no conference-link column; `html_link` is the event's Google Calendar page, not the meeting link.
- Swift `CalendarEvent` mirrors the schema 1:1; opening external URLs is an established pattern (`NSWorkspace.shared.open`, 8 call sites, e.g. `WhoToPingView.swift:112-118`).

## Design

### Go: parse + store

1. **API parsing** (`internal/calendar/client.go`): extend `googleEvent` with `hangoutLink string` and `conferenceData` (only `entryPoints[]{entryPointType, uri}` is needed). `convertEvent` computes `ConferenceURL` with priority:
   1. `hangoutLink`;
   2. first `conferenceData.entryPoints` entry with `entryPointType == "video"`;
   3. regex fallback over `location` + `description`.
2. **Regex fallback** lives in a shared helper in `internal/calendar` (exported, used by the Google converter and applied to CalDAV events on their sync path too, so a Zoom link pasted into a CalDAV event's location/description also yields a button). Recognized hosts: `meet.google.com`, `*.zoom.us` (`/j/` and `/my/` links), `teams.microsoft.com`/`teams.live.com`, `webex.com`. First match wins; the helper returns "" when nothing matches. HTML descriptions are matched as-is (URLs appear in href attributes; the regex matches the URL itself, not markup).
3. **Migration** (next free goose number at merge time — parallel branches must renumber on rebase, see the goose crossed-line gotcha): `ALTER TABLE calendar_events ADD COLUMN conference_url TEXT NOT NULL DEFAULT ''`. Mirror in `schema.sql`, regenerate the schema golden snapshot. No new table → `TestAllTablesExist` unchanged.
4. **Sync mapping**: `models.CalendarEvent.ConferenceURL` → DB column in the upsert path (`sync.go:153-171`), both Google and CalDAV syncers.

### Swift: Join button

1. `CalendarEvent` gains `conferenceURL: String` (+ `conferenceLink: URL?` computed, nil when empty).
2. **Event row** (`CalendarEventsView.eventRow`): a "Join" button next to Prepare/Record, shown only when `conferenceLink != nil`. Prominent (accent tint) when `isUpcoming` or `isHappeningNow`, plain otherwise.
3. **Sidebar** (`SidebarView` "Next calendar event" block): the same Join action on the next event when it has a link.
4. **Join action** (single shared helper, e.g. on `MeetingRecorderCenter` or a small `JoinMeetingAction` util):
   - `NSWorkspace.shared.open(conferenceLink)`;
   - if `@AppStorage("calendar.autoRecordOnJoin")` (default `true`) is on AND `meetingRecorderCenter.isBusy == false` → `await center.startRecording(eventID: event.id, title: event.title, config: .fromDefaults())`;
   - if a recording is already running (this or another event) → open the link only, never interrupt or double-start.
5. **Settings**: "Auto-record on join" toggle in the Transcription settings section.

## Error handling

- Malformed URL in the DB → `conferenceLink` is nil → no button; never a crash.
- Recording start failure after opening the link follows the existing `startRecording` error surface (RecordingIndicatorView shows the failure); the link still opens first — joining the meeting must never be blocked by recorder problems.

## Testing

- Go: unit tests for the link-extraction helper (hangoutLink priority, video entry point, each regex host, description-with-HTML case, no-link → ""); sync test asserting `conference_url` lands in the DB; migration up/down.
- Swift: `CalendarEvent.conferenceLink` decoding test (empty → nil); Join-action test for the "already recording → open only" branch.

## Out of scope

- Auto-joining meetings without user action.
- Per-provider deep links (zoommtg://) — plain https URLs open the right app via the browser handoff anyway.
