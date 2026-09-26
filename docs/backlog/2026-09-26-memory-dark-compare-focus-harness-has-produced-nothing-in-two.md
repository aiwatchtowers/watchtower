---
type: question
title: "Memory dark compare/focus harness has produced nothing in two months"
status: open
priority: med
tags: [memory, dark-flags, dead-code, config, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track usage analysis & dead functionality
created: 2026-09-26
---

**Where:** internal/config/config.go:326-355,499-507; internal/memory/digest_compare.go; internal/memory/retrieve_compare.go; internal/memory/focus.go; cmd/memory.go (digest-compare, retrieve-compare)
**Confidence:** high

On the one install that runs memory (semantic + chat/briefing/reflection surfaces on):
`memory_digest_shadow` has 296 rows all from 2026-07-17..07-20 (one manual compare, never repeated);
`memory_retrieve_shadow` 0 rows ever (three `memory.retrieve.*_compare` flags); `memory_focus_matches` 0 rows
(`memory.focus.enabled`). `memory.semantic.preferences` can no longer do anything: its OWNER ACTIONS block
renders `act:` refs + `memory_engagement`, whose only feeder (action ingest) was removed 2026-09-14
(engagement table frozen at 24 rows) — flipping it on is a guaranteed no-op. That is 6 dark flags, two CLI
commands and three tables/side-tables with no validation plan. Owner call per item: schedule the
hand-review the digest-compare slice was gated on, or delete the harness (and fold `semantic.preferences`
into the already-open "re-feed engagement or demolish" decision).

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
