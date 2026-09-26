---
type: bug
title: "A persistently failing extraction batch freezes the watermark forever and re-extracts (duplicates) every later window on every run"
status: open
priority: med
tags: [memory, watermark, budget, stuck-state, cost, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/memory/pipeline.go:571-623, internal/memory/pipeline.go:886-888, internal/memory/pipeline.go:992-1027 (safeWatermark)
**Confidence:** med

MEM-04 freezes the watermark at the first ts of a failed batch. There is no retry budget or quarantine, so a batch that fails deterministically stays failed forever. Examples: the model keeps returning one zero-ref or cross-channel episode (the whole batch fails, pipeline.go:886), a refusal, or a context overflow on a 1500-message batch. Every run then reloads the same `max_chunk_messages` rows from the frozen watermark and rebuilds the same windows and batches. The failing batch fails again. Every batch after it succeeds again and writes a fresh set of episodes with new ULIDs, but `safeWatermark` can never move past the failed batch's first ts. Result: (a) extraction stalls completely, because rows past the first 2000 are never loaded; (b) duplicate episodes are written every ~cycle. `DedupeEpisodes` only mops these up with semantic on, and at most 20 merges per run; (c) one full batch set of AI calls is spent per cycle, indefinitely. The inventory accepts duplicates from a *one-off* failure. The unbounded repeat is not documented, and it is the same shape wave 4 fixed elsewhere with attempt budgets. Fix: add a per-batch (or per-first-ts) attempt counter. After N failures, split the batch into singletons, and if a singleton window still fails, quarantine it with a skip record and let the watermark pass it.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
