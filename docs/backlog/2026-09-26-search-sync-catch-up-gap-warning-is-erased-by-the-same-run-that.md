---
type: bug
title: "Search-sync \"catch-up gap\" warning is erased by the same run that writes it"
status: open
priority: med
tags: [slack, sync, observability, data-gap, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go sync/daemon/integrations)
created: 2026-09-26
---

**Where:** internal/sync/search_sync.go:63-71, internal/sync/orchestrator.go:151-174, internal/db/slack_accounts.go:154-163
**Confidence:** high

When the search watermark is more than 30 days old, `recordSearchGap` writes "messages between X and Y were not fetched" to `slack_accounts.error` via `SetSlackAccountError`, then moves the watermark to today. This is the only record of a permanent data gap. Later in the same `Orchestrator.Run`, a successful pass calls `recordAuthResult(ctx, nil)`, and `SetSlackAccountAuthState(id, "ok", "")` clears `error`. The gap message therefore disappears within seconds and never reaches Settings. The guard tests (`TestSyncViaSearch_ClampedGapLogsWarningAndRecordsError`) call `syncViaSearch` directly rather than `Run`, so they miss this. Fix: have the "ok" path leave a gap note alone (e.g. a separate `sync_gap` column, or `recordAuthResult` not clearing `error` when the pass recorded a gap).

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
