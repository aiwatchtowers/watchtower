---
type: bug
title: "Owner's own resolving comment re-mints a jira_assigned item"
status: open
priority: med
tags: [inbox, jira, INBOX-02, idempotency, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/inbox/jira_detector.go:76-97 (plus internal/inbox/pipeline.go:693-751)
**Confidence:** med

INBOX-02 resolves a pending `jira_assigned` item when the owner comments on the issue. That comment also bumps the issue's `updated_at` to a value T. On the next cycle, the issue matches `updated_at > since` whenever T falls inside the 30-minute watermark buffer, which is likely because Jira syncs right before the inbox. Neither dedup check blocks it: `jiraInboxExists(key, T)` is false, and `jiraPendingExists` is false because the old item is resolved. So a fresh pending item is created. It won't auto-resolve, because the owner's latest comment is older than the new item's `created_at`. Answering in the source brings the item back. Fix: skip an issue whose newest change is the owner's own comment, or dedup against a recently resolved item whose `updated_at` is at or before the resolving comment.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
