---
type: bug
title: "Catch-Up auto window fails permanently once the last acknowledged recap is more than 31 days old"
status: open
priority: med
tags: [catchup, window, dead-end, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/catchup/window.go:88-102 (plus WatchtowerDesktop/Sources/ViewModels/CatchUpViewModel.swift:31)
**Confidence:** high

Auto mode sets `From` to the last acknowledged `period_to` whenever that is before now, then applies the 31-day cap as a hard rejection ("rejected, not clamped"). After a vacation longer than 31 days, which is exactly the "while I was away" case this feature exists for, the Desktop's default **Auto** window returns `invalid catch-up window: longer than 31 days` on every attempt. The only way out is to pick a preset or custom window and acknowledge it. No test covers auto mode with an old ack: `window_test.go:91` covers only the custom path. Fix: in auto mode, clamp `From` to `now - 31d` and flag the truncation in coverage. Keep the rejection for explicit custom windows.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
