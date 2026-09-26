---
type: bug
title: "Tracks: a partially failed batch set still advances the incremental watermark past the failed batches' digests"
status: open
priority: med
tags: [tracks, watermark, partial-failure, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/tracks/pipeline.go:326-338 (plus :175-189, internal/db/pipeline_runs.go:200-212)
**Confidence:** high

Decision 10 made `RunForWindow` return an error only when all batches fail or the run was cancelled. With N>1 batches where at least one succeeds and one fails (a timeout, or unparseable JSON on one batch), it returns nil and the run is recorded `done`. The next run's `lastTracksStartedAt` (MAX `started_at` of done runs) then fetches only digests with `created_at > started_at`, so the failed batch's digests are never offered to track extraction again. The wave-2 principle "partial failure ≠ success" is not applied at batch granularity here. Fix: record failed batches' digest ids, or keep the watermark at the previous run's start whenever any batch failed. Retrying succeeded batches is cheap because of fingerprint/existing_id dedup.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
