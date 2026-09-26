---
type: bug
title: "Settings silently shrinks the calendar sync horizon from 7 to 2 days (sync_days_ahead default drift)"
status: open
priority: med
tags: [swift, config, dual-path, calendar, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Swift Desktop)
created: 2026-09-26
---

**Where:** WatchtowerDesktop/Sources/Services/ConfigService.swift:37,124,224; internal/config/defaults.go:81; Views/Settings/GoogleConnectionDetail.swift:128-138
**Confidence:** high

Go's default is `DefaultCalendarSyncDaysAhead = 7`, but `ConfigService` defaults `calendarSyncDaysAhead` to **2** when the key is absent, and `save()` always writes it. On any install whose config has no `calendar.sync_days_ahead` (the normal case), toggling "Enable calendar sync" in Settings → Google (which calls `saveConfig()` immediately) writes `sync_days_ahead: 2`. From then on the daemon syncs only two days ahead, which starves meeting prep, the warm-engine prewarm, and day-plan conflicts beyond day 2, and nobody chose it. The picker also shows "2 days" selected while the effective value is 7. This is the same bug class the file already documents for `digest.enabled`. Fix: default to 7 on the Swift side, and ideally write the key only when the user touched the picker.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
