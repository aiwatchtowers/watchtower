---
type: bug
title: "People cards: shutdown, total batch failure and partial runs are all recorded as success and locked in for the window"
status: open
priority: med
tags: [guide, partial-failure, ctx-cancel, throttle, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/guide/pipeline.go:170-178, 244-257, 309, 389-398 (plus internal/daemon/daemon.go:1024-1037)
**Confidence:** high

`RunForWindow` returns `(completed, nil)` in every case after stats are computed. On `ctx.Err()` it just `break`s. When a batch AI call fails, it writes `insufficient_data` cards for the whole batch. `completed` counts users whether or not their card was stored. The daemon therefore stamps `lastPeople` (24 h throttle) and records a `done` run on a shutdown or an AI outage. Next time, the `GetPeopleCardsForWindow` "window already has N cards, skipping" check also treats any card at all, including fallback `insufficient_data` cards, as a completed window. Scenario: an AI provider blip during the people phase leaves every low-data user with an "insufficient data" card, and no retry happens until the window rolls over. A daemon stop halfway through leaves the remaining users without cards for that window. Fix: return an error when cancelled or when zero cards were produced by AI, and do not count fallback cards as window completion.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
