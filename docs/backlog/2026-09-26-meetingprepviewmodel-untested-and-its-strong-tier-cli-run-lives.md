---
type: chore
title: "MeetingPrepViewModel: untested, and its strong-tier CLI run lives in view-local @State"
status: open
priority: med
tags: [test-coverage, lifecycle, meeting-prep, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track test coverage (Swift Desktop)
created: 2026-09-26
---

**Where:** WatchtowerDesktop/Sources/ViewModels/MeetingPrepViewModel.swift:97-190, Sources/Views/DayPlan/DayPlanView.swift:11,150, Sources/Views/Calendar/CalendarEventsView.swift:27
**Confidence:** high

`meeting-prep <id> --json` runs a strong-tier AI call that takes tens of seconds. Its view model is created as `@State` in two different screens, and DayPlanView even recreates it at line 150. So if the user starts prep and switches tabs, the view model is discarded while the subprocess keeps running, and on return the result is gone. This breaks the review-rules lifecycle rule ("state for an async operation that must survive navigation lives in AppState or an app-wide center; the test must exercise start → navigate away → return"). The view model has zero tests: nothing covers argv (`--force-refresh`, `--user-notes`, the `next` positional), JSON decode failure, or the non-zero-exit stderr surfacing. Fix: host it on AppState (or a `MeetingPrepCenter`) behind `CLIRunnerProtocol`, then add the usual FakeCLIRunner suite.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
