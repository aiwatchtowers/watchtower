---
type: bug
title: "Target extraction does not validate level/priority, so one bad value fails the whole CLI batch"
status: open
priority: med
tags: [targets, ai-validation, check-constraint, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/targets/extractor.go:198-208 (plus internal/targets/store.go:77-98, cmd/targets_ai.go:155)
**Confidence:** med

`parseExtractResponse` copies the model's `level` and `priority` as-is. `insertTargetTx` only defaults empty values, while `targets` has `CHECK(level IN (...))` and `CHECK(priority IN ('high','medium','low'))`. A model reply with `"priority":"High"`, `"urgent"`, or `"level":"year"` makes the insert fail. Because `CreateBatch` runs in one transaction, every target the user confirmed in `watchtower targets extract` is rolled back with an opaque CHECK error. Items with empty `text` are also accepted and persisted. Fix: lower-case and whitelist both fields at parse time (fall back to `day`/`medium`, the way `meeting.ExtractDiscussionTopics` normalises priority), and drop empty-text items.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
