---
type: bug
title: "Jira board auto-refresh retries the LLM analysis every 15 minutes after a failure; analyzer and field discovery have zero tests"
status: open
priority: med
tags: [ai-cost, attempt-budget, jira, test-coverage, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track test coverage (Go)
created: 2026-09-26
---

**Where:** internal/jira/board_analyzer.go:363-448 (CheckAndRefreshProfiles 0%), internal/jira/board_analyzer.go:214-293 (AnalyzeBoard 0%), internal/jira/fields.go:60-231 (DiscoverFields/ClassifyFields/MapFieldsForBoard 0%), internal/jira/sync.go:188-200, cmd/sync.go:898
**Confidence:** high

The daemon wires every Jira syncer with `SetAutoRefresh(true)`, and `Syncer.Sync` runs `CheckAndRefreshProfiles` on each Jira pass (default `jira.sync_interval_mins` = 15). The 24h cooldown is keyed on `ProfileGeneratedAt`, and only a successful `AnalyzeBoard` writes that field (`UpdateJiraBoardProfile(..., now)`). So when a board's config hash changed and the analysis fails (LLM error, or "LLM returned empty workflow"), the config hash stays different and the cooldown has already elapsed. Every 15-minute pass then re-runs `callLLM`, and possibly `MapFieldsForBoard`/`DiscoverAndClassify` LLM calls, indefinitely. The error is only logged, and the result is folded into `RefreshResult.Error`. None of this code has any test: cooldown skip, override merge (`mergeUserOverrides` 0%), hash-unchanged short-circuit, the failure path. Suggested fix: stamp an attempt time (or a failure counter) on a failed refresh so the cooldown also covers failures, and add fake-client tests for the cooldown and failure paths.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
