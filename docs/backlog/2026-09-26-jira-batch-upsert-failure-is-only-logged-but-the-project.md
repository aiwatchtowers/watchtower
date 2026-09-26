---
type: bug
title: "Jira batch-upsert failure is only logged, but the project watermark still advances past the lost issues"
status: open
priority: med
tags: [jira, watermark, partial-failure, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go sync/daemon/integrations)
created: 2026-09-26
---

**Where:** internal/jira/sync.go:448-452 (writer loop), internal/jira/sync.go:147-151 (watermark), internal/jira/sync.go:384
**Confidence:** high

In `syncWithJQL`, an `UpsertJiraIssueBatch` error is only logged (`batch upsert error`). The page's keys still go into `changedKeys` and into `written`, and the function returns nil. `Sync` then stamps `UpdateJiraSyncState(now)` for the project. Every issue in the failed batch (up to 100) is permanently missing from `jira_issues` until someone edits it in Jira again, because the next incremental JQL only asks for `updated >= -Nm`. `InitialLoad` has the same shape. A realistic trigger is a transient `SQLITE_BUSY` while the Desktop holds a write. Fix: make an upsert failure abort the project pass so the watermark is not written (the gmail/imap "stalled" pattern), and don't count unwritten keys as changed.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
