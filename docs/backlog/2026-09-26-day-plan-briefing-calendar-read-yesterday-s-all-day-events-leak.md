---
type: bug
title: "Day-plan/briefing calendar read: yesterday's all-day events leak into today, and the day is UTC, not local"
status: open
priority: med
tags: [dayplan, briefing, calendar, timezone, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/db/calendar.go:197-200 (consumed by internal/dayplan/gather.go:137-143, internal/briefing/pipeline.go:536-539)
**Confidence:** high

`GetCalendarEventsForDate(date)` queries `end_time >= "<date>T00:00:00Z" AND start_time <= "<date>T23:59:59Z"`. Google all-day events are stored with an exclusive end at next-day `00:00:00Z` (internal/calendar/client.go:287-300). So yesterday's all-day event (OOO, holiday, offsite) matches today: `end_time == today 00:00Z` satisfies `>=`. It then shows up in today's briefing calendar block and in the day-plan prompt's CALENDAR section. Separately, `date` is a local `YYYY-MM-DD` (`time.Now().Format`) but the window is the UTC day. For a UTC-5 owner, today's meetings after 19:00 local are dropped and the previous evening's meetings are included. `syncCalendarItems` and `aiToTimeblock`'s overlap check then work from the wrong event set too. Fix: build the window from local midnight converted to UTC, and use `end_time > from` for exclusive ends.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
