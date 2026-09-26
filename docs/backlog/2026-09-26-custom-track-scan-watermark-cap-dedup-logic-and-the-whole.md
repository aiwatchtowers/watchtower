---
type: chore
title: "Custom-track scan: watermark/cap/dedup logic and the whole backfill path are untested"
status: open
priority: high
tags: [test-coverage, watermark, customtracks, ai-cost, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track test coverage (Go)
created: 2026-09-26
---

**Where:** internal/customtracks/pipeline.go:130 (runOne 20.3%), internal/customtracks/pipeline.go:249 (gatherBackfillActivity 0%), internal/customtracks/pipeline.go:70 (Run 0%), internal/db/track_events.go:198 (GetScanActivity 28.3%), internal/db/track_events.go:288,338 (GetScanActivityTitles/ByIDs 0%)
**Confidence:** high

The only scan test is `TestScanEmptyActivityAdvancesWatermarkNoAICall`. No test anywhere calls `GetScanActivity` with data, and `CappedAt` is never asserted. None of these paths runs in any test: the per-source cap moving the watermark to `CappedAt` instead of now, the boundary-second tie-drain queries (whose comment says a lost tie is "skipped forever"), the insert-failure freeze (`insertFailed` → watermark not advanced), exact-summary dedup, and the entire two-stage history backfill (shortlist chunking, `maxCandidates` cutoff, id routing by kind). Any of these could regress with the suite still green. Two examples: dropping the tie-drain silently loses inbox items batch-inserted in one second, and swapping `next` back to `now` loses the overflow past the cap. Suggested fix: table tests in `internal/db` for `GetScanActivity` (cap hit per source, ties at the boundary, min across sources) and a `runOne` test with a fake generator covering cap, insert failure and parse failure.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
