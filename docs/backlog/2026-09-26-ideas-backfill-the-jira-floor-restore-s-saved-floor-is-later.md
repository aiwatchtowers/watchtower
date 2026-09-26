---
type: chore
title: "Ideas backfill: the Jira floor restore's \"saved floor is later than reached\" branch never executes (IDEA-01)"
status: open
priority: med
tags: [test-coverage, watermark, ideas, IDEA-01, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track test coverage (Go)
created: 2026-09-26
---

**Where:** internal/ideas/backfill.go:486-500 (maxJiraFloor 55.6%), internal/ideas/backfill.go:426 (restoreJiraFloors 57.1%)
**Confidence:** high

The block profile shows that in `maxJiraFloor` only the `aok && bok` branch returning `b` (reached) ever runs. `return a` (the saved going-forward floor is later) and both one-side-unparseable branches have a count of 0. A mid-history backfill is exactly the case where stage 1 reaches only the window end, which is older than the saved floor, so `return a` is what stops the daemon re-mining `[to, now]` for Jira (the documented backfill contract). Flipping the comparison, or returning `reached` unconditionally, would pass every test. Suggested fix: a backfill test with a Jira account whose saved floor is newer than the window's `to`, asserting that the floor is restored to the saved value, and a case with an uninitialized ("") saved floor.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
