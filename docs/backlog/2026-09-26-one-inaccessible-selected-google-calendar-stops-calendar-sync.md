---
type: bug
title: "One inaccessible selected Google calendar stops calendar sync for the whole account, and removed calendars are never deselected"
status: open
priority: med
tags: [calendar, sync, partial-failure, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go sync/daemon/integrations)
created: 2026-09-26
---

**Where:** internal/calendar/client.go:201-215, internal/calendar/sync.go:57-137, internal/db/calendar.go:22-35
**Confidence:** high

`FetchEvents` is all-or-nothing across calendars: the first calendar whose `events.list` fails returns an error for the whole account. When a selected calendar becomes inaccessible (a colleague stops sharing it, or a secondary calendar is deleted), events.list returns 404 on every cycle. The account then syncs no events at all, including its primary calendar, and `recordAuthResult` marks it `status='error'`. Nothing repairs this on its own. The calendar-list step only upserts calendars that are still listed and never deselects or deletes rows missing from `calendarList`, so `GetSelectedCalendarIDs` keeps returning the dead id forever. Fix: on a successful `FetchCalendars`, deselect (or delete) this account's calendars that are no longer listed. Also make `FetchEvents` per-calendar tolerant: skip a 404/403 calendar and skip its stale-delete, but still sync the others.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
