# Calendar Now Line + Jump-to-Now — Design

**Date:** 2026-08-04
**Status:** Approved
**Scope:** Desktop only (`WatchtowerDesktop`), Events tab of the Calendar screen. No Go, no DB changes.

## Problem

The Calendar Events list renders ~2 weeks of history plus upcoming days as one
scrollable list. The only "now" indication is the green highlight on a
currently-running event row — when nothing is running, there is no visible
marker of the current time at all. And once the user scrolls away (or opens the
screen on a day buried mid-list), there is no way to get back to "now" short of
manual scrolling; `scrollToToday` fires only on appear.

## Design

### 1. Red now line

A horizontal marker row inside the **Today** day section: red dot + current
time label (e.g. `14:32`) + a red line to the trailing edge — the
Google/Apple Calendar convention.

- **Placement:** among today's *timed* rows, before the first row with
  start > now. Currently-running meetings (started before now, still
  ongoing) stay **above** the line; if every row has started, the line goes
  after the last row. All-day chips are unaffected (line always renders below
  the chip, inside the timed list). A Today section containing only all-day
  events still renders the marker (with its time label) below the all-day chip
  — intended, it keeps the "you are here" mark visible on such days.
  (Post-#71 unified Meetings list: "timed rows" are `MeetingListEntry`s —
  calendar events and standalone recordings alike — ordered by `sortDate`,
  which is what the insertion compares against.)
- **Ticking:** the Today section body is wrapped in
  `TimelineView(.everyMinute)`, so both the time label and the line position
  recompute once a minute with no manual timers.
- **Pure helper:** placement is computed by a pure function
  `nowLineIndex(events:now:) -> Int` (index into the timed-events array where
  the line is inserted), unit-tested with relative dates from `Date()` — no
  hardcoded date bombs. Covered cases: empty list, all events past, all events
  future, an ongoing event, and an event starting exactly at `now`
  (`startDate > now` is the boundary: an event starting at `now` counts as
  started, line goes below it).
- The marker row carries `.id("now-line")` as the scroll anchor.

### 2. Floating "Now" button

A capsule button overlaid near the bottom of the events list, visible **only
when the now line exists and is off-screen**:

- The now-line row publishes its frame in the ScrollView's named coordinate
  space via a preference key. Comparing that frame against the viewport bounds
  yields one of: visible / above viewport / below viewport.
- Off-screen → show a capsule `↑ Now` (marker above) or `↓ Now` (marker
  below), bottom-center overlay. Tap → animated
  `proxy.scrollTo("now-line", anchor: .center)`.
- Visible (or no marker rendered) → no button.

### v1 limitation (accepted)

If today has no events, the Today section does not exist, so neither the line
nor the button renders. Behavior falls back to the existing `scrollToToday`
(lands on the first future day on appear). Synthesizing an empty Today section
was considered and rejected for v1 — it changes list semantics for a rare
case.

## Files

- `WatchtowerDesktop/Sources/Views/Calendar/CalendarEventsView.swift` — marker
  insertion in `daySection`, preference plumbing, overlay button.
- A small dedicated view file for the marker row is acceptable if the view
  grows; otherwise keep it private in `CalendarEventsView.swift`.
- `WatchtowerDesktop/Tests/` — unit tests for `nowLineIndex(events:now:)`.

## Error handling

None required — pure UI over already-loaded data; no I/O, no new failure
modes.
