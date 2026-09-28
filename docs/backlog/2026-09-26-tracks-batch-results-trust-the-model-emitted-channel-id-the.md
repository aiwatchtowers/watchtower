---
type: bug
title: "Tracks batch results trust the model-emitted channel_id (the digest C1 bug, unfixed here)"
status: done
priority: med
tags: [tracks, ai-validation, namespacing, multi-account, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/tracks/pipeline.go:1014-1018 (plus :877-913, internal/prompts/defaults.go:620-621)
**Confidence:** high

`generateBatchTracks` passes each `cr.ChannelID` from the model straight into `storeTrackItems`, which writes it as `tracks.channel_ids`. The same value then drives `FindRelatedDigestIDs`, `resolveItemDigestIDs` and `FoldSourceRefsIntoTrack`. Nothing checks it against the batch's entries. The `tracks.extract_batch` prompt example shows a bare `"channel_id": "C123ABC"` while the blocks carry namespaced `1:C…` ids. This is the exact shape behind the digest audit's C1 finding, which the digest pipeline fixed with `batchEntryLookup` (pipeline.go:1245-1298). Concrete result: a model that echoes the bare id writes a track with `channel_ids=["C…"]`. Every namespaced reader then misses it (channel filters, TRACKS-06 channel merge, Desktop links), and its related-digest fallback resolves to nothing. An invented id attributes the track to a channel that does not exist. Fix: resolve each result through the same lookup as the digest (exact match, then unique raw id), and drop unknown or ambiguous results.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»

**Resolution:** `generateBatchTracks` now resolves each result's `channel_id` against the batch's own entries (`newBatchChannelResolver`, internal/tracks/pipeline.go): exact namespaced match first, then a raw id exactly one entry carries; an invented id or a raw id two accounts in the batch share is dropped and counted in the log, and the rest of the batch is stored under the entry's namespaced id. Pinned by `TestGenerateBatchTracks_ResolvesModelChannelIDAgainstBatch` (internal/tracks/batch_channel_test.go). The run-window test generators now answer for the first channel their batch prompt carries, since their fixed `C1` answer only landed when C1 happened to share the batch.
