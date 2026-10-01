---
type: bug
title: "google remove unlinks recordings from their calendar events"
status: done
priority: med
tags: [calendar, google, recordings, deletion, review-2026-09-27]
context: noticed while fixing calendar logout's unscoped purge (fix/backlog-wave1)
created: 2026-09-27
---

**Where:** internal/db/google_accounts.go (`DeleteGoogleAccount`)
**Confidence:** high

`google remove <id>` deletes the account row, and the cascade removes the account's calendars and events
without the recording guard that `DeleteStaleCalendarEvents` (and now `ClearGoogleAccountCalendarData`)
applies. `meeting_transcripts.event_id` is `ON DELETE SET NULL`, so every recording and recap tied to that
account's events silently loses its event link: title, attendees and the recap's event context are gone
for good. `google remove` is destructive by design, but the recordings are owner data that outlive
events by contract. Fix direction: before the row delete, detach the account's calendars from
`account_id` or keep referenced events (the `NOT EXISTS` guard), or at least warn in the CLI/Desktop
confirm dialog that N recordings will lose their event link.

> Original note: «так там два больших фичи влилось. Пройдись еще разок, дополнии беклог и давай его начинать закрывать»

Resolution: `DeleteGoogleAccount` now runs `purgeGoogleAccountCalendarsTx` (internal/db/calendar.go)
before the account row delete: events referenced by `meeting_transcripts`/`meeting_recaps` are spared
with the same `NOT EXISTS` guard as `DeleteStaleCalendarEvents`, and the calendar row still holding
such an event is kept but detached (`account_id = NULL`, `is_selected = 0`), which also keeps the
`calendar_calendars.account_id` foreign key valid once the account row is gone. Everything else is
deleted as before. Pinned by `TestGoogleAccount_DeleteGoogleAccount_SparesRecordedEvents`. The CalDAV/ICS
sibling (`DeleteCalendarAccount`) still deletes unconditionally; left as a follow-up.
