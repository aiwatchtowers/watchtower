---
type: chore
title: "Daemon phases are a hand-ordered call list; throttle and budget persistence is copy-pasted 7 times"
status: open
priority: med
tags: [daemon, structure, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track architecture
created: 2026-09-26
---

**Where:** internal/daemon/daemon.go:375 (runSync), :79-116 (struct), :1434-1720 (marker helpers)
**Confidence:** high

`runSync` hard-codes 21 phases. Their ordering constraints ("before auto extraction so folds land", "after all analysis phases", reaction commands right after Slack sync) exist only as comments, and the struct holds 16 pipeline/syncer fields plus 20 `Set*` injectors. Persisted state is copy-pasted: the last-run markers (`last_people.txt`, `last_ideas.txt`, `last_streams.txt`, `last_briefing.txt`) each have their own path/load/save triple, and the 3/day attempt budgets (day plan, briefing, rollup) each have path/load/record/exhausted, with the log-once line re-implemented per copy. Wave 5 already had to add a "third copy of the day-plan/briefing shape". Direction: introduce a small `phase` descriptor (`name`, `enabled(cfg)`, `due(now)`, `run(ctx)`, optional `throttle`/`budget` backed by one generic `markerFile`/`attemptBudget` type), then express `runSync` as an ordered slice with an explicit `after:` list checked in a unit test. Migrate the marker phases first, because they are the pure-duplication part.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
