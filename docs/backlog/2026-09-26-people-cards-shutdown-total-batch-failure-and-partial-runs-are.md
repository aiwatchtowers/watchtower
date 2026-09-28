---
type: bug
title: "People cards: shutdown, total batch failure and partial runs are all recorded as success and locked in for the window"
status: done
priority: med
tags: [guide, partial-failure, ctx-cancel, throttle, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/guide/pipeline.go:170-178, 244-257, 309, 389-398 (plus internal/daemon/daemon.go:1024-1037)
**Confidence:** high

`RunForWindow` returns `(completed, nil)` in every case after stats are computed. On `ctx.Err()` it just `break`s. When a batch AI call fails, it writes `insufficient_data` cards for the whole batch. `completed` counts users whether or not their card was stored. The daemon therefore stamps `lastPeople` (24 h throttle) and records a `done` run on a shutdown or an AI outage. Next time, the `GetPeopleCardsForWindow` "window already has N cards, skipping" check also treats any card at all, including fallback `insufficient_data` cards, as a completed window. Scenario: an AI provider blip during the people phase leaves every low-data user with an "insufficient data" card, and no retry happens until the window rolls over. A daemon stop halfway through leaves the remaining users without cards for that window. Fix: return an error when cancelled or when zero cards were produced by AI, and do not count fallback cards as window completion.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»

**Resolution:** `guide.RunForWindow` now counts AI-produced cards separately from fallbacks and returns an error when the run was cancelled (wrapping `ctx.Err()`, so it is not blamed on the AI) or when every user fell back (skipping the team summary over fallback cards); a partial run stays a success. The "window already has cards" skip is per user and ignores `insufficient_data` cards (only ever written as a fallback), so a rerun of the same window re-sends just the users still without an AI card. Because a failed run no longer stamps the 24 h throttle, `phasePeopleCards` gained the day-plan/briefing attempt budget (`people_attempts.txt`, `maxDailyAIAttempts` = 3/day, local date); a shutdown is never charged. Pinned by `internal/guide/partial_failure_test.go` (two-user fixtures: fallback cards do not complete the window, a rerun covers only the fallen-back user, shutdown is reported as a cancellation), the updated `TestPipeline_BatchFallback`, and `internal/daemon/daemon_people_backoff_test.go` (budget spent after three failures with one give-up line, shutdown not charged, survives restart, resets next day). `TestPipeline_SkipsExistingWindow`'s mock now returns a batch-shaped reply: it had only passed through a fallback card.
