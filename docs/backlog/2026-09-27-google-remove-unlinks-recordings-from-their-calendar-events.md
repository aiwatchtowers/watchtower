---
type: bug
title: "google remove unlinks recordings from their calendar events"
status: open
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
