---
type: chore
title: "JiraQueries (1035 LOC) and the Jira dashboard view models have zero tests"
status: open
priority: med
tags: [test-coverage, jira, multi-account, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track test coverage (Swift Desktop)
created: 2026-09-26
---

**Where:** WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/JiraQueries.swift (35 fetch methods), Sources/ViewModels/ProjectMapViewModel.swift (507), ReleaseDashboardViewModel.swift (274), EpicProgressViewModel.swift (130)
**Confidence:** high

No test file references `JiraQueries` or any of these view models. The file contains the heaviest SQL in the app: sprint stats, delivery stats, team workload, stale/blocked issues, epic progress, scope changes. It also contains the composite-PK `fetchBoard(accountID:id:)`, which CLAUDE.md names as the account-scoping guarantee for per-board actions ("account-scoped end to end"). Nothing pins the two-sites-same-board-id case, and the fix-version divergence above slipped through for the same reason. `ProjectMapViewModel.computeStatusBadge`/`buildEpicItem` and `ReleaseDashboardViewModel.buildReleaseItem` are pure `nonisolated static` functions that are cheap to test. Suggest a `JiraQueriesTests` in `Tests/Core` with a two-account fixture (colliding board id, issue key, and release name) plus pure-function tests for the badge and release math.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
