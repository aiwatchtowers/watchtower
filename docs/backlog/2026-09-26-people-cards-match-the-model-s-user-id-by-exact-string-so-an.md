---
type: bug
title: "People cards match the model's user_id by exact string, so an echoed bare id turns a batch into fallbacks"
status: open
priority: med
tags: [guide, people, ai-validation, namespacing, cost, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/guide/pipeline.go:273-285, 353-367 (plus :591, internal/prompts/defaults.go:693)
**Confidence:** med

The batch prompt lists users as `user_id: 1:U…`, while the `people.batch` JSON example shows a bare `"user_id": "U123ABC"`. `resultMap` is keyed by the model's `UserID` and looked up by the namespaced `entry.stats.UserID`. When the model echoes the bare form, which is the failure the digest pipeline already observed for channel ids, every user misses. Low-data users then get an `insufficient_data` card even though the model returned a real card. Full-data users each fall back to an individual `processUser` AI call, so one batch call becomes N+1 calls. Fix: resolve results by exact id first, then by a unique raw id (the digest `batchEntryLookup` pattern).

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
