---
type: bug
title: "Day-plan/briefing calendar read: yesterday's all-day events leak into today, and the day is UTC, not local"
status: done
priority: med
tags: [dayplan, briefing, calendar, timezone, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/db/calendar.go:197-200 (consumed by internal/dayplan/gather.go:137-143, internal/briefing/pipeline.go:536-539)
**Confidence:** high

`GetCalendarEventsForDate(date)` queries `end_time >= "<date>T00:00:00Z" AND start_time <= "<date>T23:59:59Z"`. Google all-day events are stored with an exclusive end at next-day `00:00:00Z` (internal/calendar/client.go:287-300). So yesterday's all-day event (OOO, holiday, offsite) matches today: `end_time == today 00:00Z` satisfies `>=`. It then shows up in today's briefing calendar block and in the day-plan prompt's CALENDAR section. Separately, `date` is a local `YYYY-MM-DD` (`time.Now().Format`) but the window is the UTC day. For a UTC-5 owner, today's meetings after 19:00 local are dropped and the previous evening's meetings are included. `syncCalendarItems` and `aiToTimeblock`'s overlap check then work from the wrong event set too. Fix: build the window from local midnight converted to UTC, and use `end_time > from` for exclusive ends.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»

**Resolution:** `db.GetCalendarEventsForDate(date, loc)` now takes the location the date is in (both callers pass `time.Local`, matching how they derive the date). Timed events match by overlap with [local midnight, next local midnight) converted to UTC, with exclusive bounds; all-day events (stored as UTC midnight with an exclusive end) match by their own date, so yesterday's all-day event, ending exactly at today's midnight, no longer leaks in, and a negative-offset zone no longer drops late-evening meetings. The briefing's calendar section also reads the briefing's own date instead of always today, and logs a read error instead of swallowing it. Pinned by `internal/db/calendar_test.go::TestGetCalendarEventsForDate_LocalDayAndAllDayBoundaries` (Los Angeles / Tokyo / UTC subtests) and `internal/briefing/calendar_date_test.go::TestGatherCalendar_ReadsTheBriefingDate`.
