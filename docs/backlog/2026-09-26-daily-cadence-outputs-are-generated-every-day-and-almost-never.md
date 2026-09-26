---
type: question
title: "Daily-cadence outputs are generated every day and almost never opened"
status: open
priority: high
tags: [usage, ai-cost, briefing, tracks, day-plan, digests, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track usage analysis & dead functionality
created: 2026-09-26
---

**Where:** internal/daemon/daemon.go (phaseBriefing, runDayPlanPhase, phaseTracksAndRollups); Desktop read writers BriefingQueries.markRead, TrackQueries.markRead
**Confidence:** high

Read signals are real (Desktop writes `read_at` on open for briefings, tracks, digests), so these numbers
measure use: briefings 27 generated / 1 read in 30 days (last read 2026-09-11); daily rollups 10 / 0 read
(last read 2026-08-27); auto tracks 261 created / 0 read since 2026-08-27 (~1.06M tokens/30d); day plans 27
generated, 1643 day-plan items ever and **all still `pending`** (no item was ever checked off or
reordered-to-done). Channel digests, by contrast, are read (146 of 593 since the 09-12 revival, with
Desktop read bursts on 09-14/09-24). Owner call: keep paying for briefing + day plan + daily rollup +
auto-tracks, merge them into one morning surface, or default some of them off (FEAT flags already exist).

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
