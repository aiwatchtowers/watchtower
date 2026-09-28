---
type: bug
title: "Tracks: a partially failed batch set still advances the incremental watermark past the failed batches' digests"
status: done
priority: med
tags: [tracks, watermark, partial-failure, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/tracks/pipeline.go:326-338 (plus :175-189, internal/db/pipeline_runs.go:200-212)
**Confidence:** high

Decision 10 made `RunForWindow` return an error only when all batches fail or the run was cancelled. With N>1 batches where at least one succeeds and one fails (a timeout, or unparseable JSON on one batch), it returns nil and the run is recorded `done`. The next run's `lastTracksStartedAt` (MAX `started_at` of done runs) then fetches only digests with `created_at > started_at`, so the failed batch's digests are never offered to track extraction again. The wave-2 principle "partial failure ≠ success" is not applied at batch granularity here. Fix: record failed batches' digest ids, or keep the watermark at the previous run's start whenever any batch failed. Retrying succeeded batches is cheap because of fingerprint/existing_id dedup.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»

**Resolution:** Fixed at digest granularity, keeping decision 10's "a partial failure stays a success" (the watermark still advances past the processed digests; `TestRunForWindow_PartialBatchFailureStaysSuccess` unchanged). Migration `00078` adds `track_retry_digests`: `RunForWindow` puts the digests of every failed batch there (`SettleTrackRetryDigests`), every later run re-offers them next to its new digests (`GetTrackRetryDigests`), a digest leaves the set once its batch succeeds (or it is filtered out before batching), and one whose batch has failed `maxBatchRetryAttempts` = 3 times is given up on with a log line, so a deterministically failing batch is not re-sent forever. An interrupted run charges nothing and only clears what its succeeded batches covered. Pinned by `TestRunForWindow_PartialFailureReoffersFailedBatchDigests` (16 channels, two batches), `TestRunForWindow_RetryGivesUpAfterMaxAttempts`, and `TestRunForWindow_ShutdownIsNotChargedToRetrySet` (between batches and mid-call).
Review follow-ups (same branch): a failed batch is charged in full only when at least one batch in its run succeeded. In a run where every batch failed, which may be an outage, nothing new joins the set, and a digest that is already owed is charged at most once per UTC day (`last_charged_day`). Each UTC day an outage touches therefore costs an owed digest one attempt, and a digest that fails even on its own still gives up within about 2 days of entry. Pinned by `TestRunForWindow_FullyFailedRunsKeepRetryDigests` and `TestRunForWindow_OwedDigestAloneGivesUpOverUTCDays` (injected clock).
Digests owed from earlier runs are batched separately from the window's fresh digests, so an owed digest that keeps failing cannot fail the fresh batch of its channel. Whenever a fresh batch succeeds, the owed digest's failure is charged in full. Pinned by `TestRunForWindow_PoisonRetryDigestDoesNotTakeFreshDigestDown`.
