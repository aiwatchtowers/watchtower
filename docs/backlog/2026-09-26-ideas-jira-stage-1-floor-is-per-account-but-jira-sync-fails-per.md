---
type: bug
title: "Ideas Jira stage-1 floor is per account, but Jira sync fails per project"
status: done
priority: med
tags: [ideas, watermark, IDEA-01, jira, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/ideas/jira_digest.go:365-416 (plus internal/jira/sync.go:124-142, internal/db/ideas.go:947)
**Confidence:** med

`ideas_jira_floor` is a single `updated_at` cursor for the whole account (`ListJiraIssuesUpdatedSince(accountID, floor, …)`). `jira.Syncer.Sync` syncs project by project, logs and skips a failing project, and returns nil. Scenario: project A syncs and project B fails this cycle. The ideas pass mines A and advances the floor to A's newest `updated_at`. Next cycle B catches up, but its issues edited during the gap have `updated_at` below the floor and are never mined. That breaks IDEA-01's "floor only past consumed material" in practice. Memory's `runJiraIngest` likely shares the shape but is outside this part's scope. Fix: clamp the floor to the oldest per-project `jira_sync_state.last_synced_at` of the account, or keep the floor per project.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»

**Resolution:** `runJiraDigestAccount` clamps its upper bound to the oldest `last_synced_at` (minus the sync's 2-minute overlap) among the account's selected-board projects whose latest sync attempt failed (`db.OldestFailingJiraProjectSync`, `clampToFailingJiraProject`), so the account-wide floor never passes a failing project's backlog. Never-synced, unselected and over-7-day-failing projects do not hold the floor (the last is logged), so a dead board cannot stall mining forever. Pinned by `internal/ideas/jira_failing_project_test.go` (`TestIdeas01_JiraFloorHeldBackByFailingProject`, `…NothingMineable_CleanNoOp`, `…Exemptions`). Memory's `runJiraIngest` has the same account-wide cursor shape and is not changed here.
