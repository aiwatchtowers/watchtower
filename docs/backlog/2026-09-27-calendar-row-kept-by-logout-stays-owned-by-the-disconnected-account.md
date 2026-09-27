---
type: bug
title: "A calendar row kept by logout stays owned by the disconnected account"
status: open
priority: low
tags: [calendar, google, multi-account, review-2026-09-27]
context: codex finding on fix/backlog-wave1 (calendar logout scoped purge), deferred as a design call
created: 2026-09-27
---

**Where:** internal/db/calendar.go (ClearGoogleAccountCalendarData, UpsertCalendar's sticky account_id CASE)
**Confidence:** high

The scoped `calendar logout` purge keeps a calendar row when one of its events is referenced by a
recording or recap (the FK forces it). That row keeps `account_id = A`, and `UpsertCalendar` never
reassigns a non-NULL owner, so if account B shares the same calendar id, B can never select or sync it
again. Narrow: needs a shared calendar AND a recorded meeting on it. Options: clear `account_id` and
`is_selected` on kept rows (lets B claim it, but the row then looks like a CalDAV/ICS row to anything
keying on NULL), or let UpsertCalendar hand off ownership when the current owner is disconnected, or
document it. Owner design call.

> Original note: «так там два больших фичи влилось. Пройдись еще разок, дополнии беклог и давай его начинать закрывать»
