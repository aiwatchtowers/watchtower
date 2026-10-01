---
type: bug
title: "A calendar row kept by logout stays owned by the disconnected account"
status: done
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

Resolution: the "clear the owner" option, chosen as the default pending an owner call. `calendar logout`
(`ClearGoogleAccountCalendarData`) and `google remove` now share `purgeGoogleAccountCalendarsTx`
(internal/db/calendar.go), which keeps a calendar row only for its recorded/recapped events and
detaches it (`account_id = NULL`, `is_selected = 0`). `UpsertCalendar` already claims a NULL-owner row;
a claim now also takes the incoming `is_selected`, as a fresh insert would, so a second account sharing
the calendar id selects and syncs it on its next pass. A no-account (CalDAV/ICS) upsert and a row owned
by a connected account are unchanged. Pinned by `TestUpsertCalendar_ClaimsCalendarKeptByLogout` and the
updated `TestClearGoogleAccountCalendarData`. Known side effect: until claimed, a detached Google row is
listed with the CalDAV/ICS calendars in Settings (the Desktop groups by `account_id IS NULL`).
