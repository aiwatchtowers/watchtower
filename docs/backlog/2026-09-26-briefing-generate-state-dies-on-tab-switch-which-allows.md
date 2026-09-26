---
type: bug
title: "Briefing \"Generate\" state dies on tab switch, which allows duplicate concurrent strong-tier runs"
status: open
priority: med
tags: [swift, async-state-survives-navigation, briefing, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Swift Desktop)
created: 2026-09-26
---

**Where:** WatchtowerDesktop/Sources/Views/Briefings/BriefingsListView.swift:7,25-41,250; ViewModels/BriefingViewModel.swift:14,117-131; App/Navigation.swift:215-216
**Confidence:** high

`BriefingViewModel` (which owns `isGenerating`/`generateError`) lives in the view's `@State`, and `Navigation.detailView`'s `switch` destroys `BriefingsListView` on every tab change. Scenario: click Generate (`briefing generate`, a strong-tier call taking tens of seconds), switch to another tab, then come back. A fresh VM shows `isGenerating = false` with Generate enabled, and a second click starts a parallel `briefing generate` for the same date: two AI calls and a racing upsert. Any error from the first run is lost with the old VM. This violates review-rules "Lifecycle & state" [1/6] (Day Plan already does it right: `AppState.dayPlanViewModel`). Fix: hold the VM (or at least the generate state) on `AppState`, and test start → navigate → return.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
