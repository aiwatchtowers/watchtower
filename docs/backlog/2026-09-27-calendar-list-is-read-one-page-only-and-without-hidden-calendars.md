---
type: question
title: "Calendar list is read one page only and without hidden calendars"
status: open
priority: low
tags: [calendar, google, pagination, review-2026-09-27]
context: debate-review of fix/backlog-wave2 — the deselect-unlisted-calendars pass was dropped because of this
created: 2026-09-27
---

**Where:** internal/calendar/client.go (FetchCalendars, googleCalendarList has no NextPageToken)
**Confidence:** high

`FetchCalendars` makes a single `calendarList.list` call: no `pageToken` loop, no `showHidden`. Anything
that treats that list as complete is wrong past the first page (default 100 entries) and for calendars the
owner hid in Google. Wave 2 therefore dropped the planned "deselect calendars no longer listed" pass;
calendars that disappear are now only skipped per cycle via the 404/410 path (and log every cycle).
Owner call: should a calendar hidden in Google still sync if selected in Watchtower? Then page the list
to the end (with or without `showHidden`) before any cleanup that relies on it, and prefer a read-time
filter over writing `is_selected` (a deselect must never override the owner's own choice and must undo
itself when the calendar comes back).

> Original note: «так там два больших фичи влилось. Пройдись еще разок, дополнии беклог и давай его начинать закрывать»
