---
type: question
title: "Memory is about 17k lines behind 18 dark flags and has been frozen since 2026-08-01; the flag matrix is untested"
status: open
priority: med
tags: [memory, config, dead-code, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track architecture
created: 2026-09-26
---

**Where:** internal/config/config.go:476-507, internal/memory/ (12.8k non-test lines + 14.5k test), internal/db/memory*.go (4.4k lines)
**Confidence:** med

`memory.enabled` plus 17 sub-gates (semantic, 6 surfaces, 5 sources, renders, 3 retrieve-compare shadows, focus, preferences) all default to false. The feature audit lists every memory phase as frozen since 2026-08-01, and the only memory input fed by an action (`owner-action` rank/`act:` scheme) now starves. That is about 17k production lines and 16 migrations touching `memory_*`, with CI cost and complexity (8 of the 115 functions with CC>15 are in memory) paid for code that runs on no install by default. Each gate is tested on/off individually, but 2^18 combinations cannot be tested and the realistic "all on" profile has no end-to-end guard apart from the reindex/MEM-14 dumps. This touches MEM-* inventory contracts, so it is an owner call. Question: (a) pick the flags that will ship, collapse the rest into `memory.enabled` and delete the three `retrieve.*_compare` shadows and the `digest_compare` telemetry path once their comparison is decided, or (b) move the subsystem behind a build tag until it is un-frozen.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
