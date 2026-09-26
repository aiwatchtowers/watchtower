---
type: bug
title: "Custom-track scan: a failing track re-runs a strong-tier AI call every daemon cycle and is reported as \"done\""
status: open
priority: med
tags: [ai-cost, attempt-budget, silent-failure, customtracks, test-coverage, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track test coverage (Go)
created: 2026-09-26
---

**Where:** internal/customtracks/pipeline.go:70-90, internal/customtracks/pipeline.go:180-187, internal/daemon/daemon.go:1336-1352, internal/digest/models.go:19
**Confidence:** high

`customtrack.run` is not in the light list, so it routes to the strong tier. The daemon calls `phaseCustomTrackScan` every cycle with no throttle. If a track's AI reply fails to parse, or an event insert fails, `runOne` returns before `SetTrackLastRun`, so the next cycle re-sends the same (growing) window to the strong model. Nothing bounds this: there is no per-day attempt budget like `next_step_attempts`, `day_plan_attempts.txt` or `rollup_attempts.txt`. `Pipeline.Run` also logs the per-track error and returns `(total, nil)`, so `trackedPipelineRun("custom_tracks")` records `status='done'` even when every track failed. That is the "partial failure ≠ success" class that wave 2/4 fixed for next-step (`attempted > 0 && done == 0`). Suggested fix: a per-track daily attempt cap (the next-step shape), have `Run` return an error when every attempted track failed, and a guard test for both.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
