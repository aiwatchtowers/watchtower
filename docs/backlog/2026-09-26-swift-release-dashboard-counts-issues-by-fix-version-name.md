---
type: bug
title: "Swift release dashboard counts issues by fix-version name across all Jira sites (Go scopes by account)"
status: open
priority: med
tags: [test-coverage, dual-path, jira, multi-account, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track test coverage (Swift Desktop)
created: 2026-09-26
---

**Where:** WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/JiraQueries.swift:891-908,991-1010, WatchtowerDesktop/Sources/WatchtowerCore/Models/JiraRelease.swift:3-24, WatchtowerDesktop/Sources/ViewModels/ReleaseDashboardViewModel.swift:150; Go twin internal/db/jira_dashboards.go:464-500
**Confidence:** high

The Go `GetJiraIssuesByFixVersion`/`GetJiraIssueCountAddedSince` add `account_id = ?`, and the comment explains why: "two connected sites routinely both ship a 'v1.0'". The Swift twins `fetchIssuesByFixVersion(versionName:)` and `fetchScopeChanges(versionName:since:)` have no account (and no project) predicate, and the `JiraRelease` model does not decode `account_id` at all. Example: site A and site B each have a release "1.0" with 10 issues. Each release row in the Desktop Release Dashboard then shows 20 issues, with mixed done/blocked percentages and scope-change counts. `JiraRelease` is also `Identifiable` on the per-site `id` alone, so two sites with the same release id collide in `ForEach`. No Swift test touches `JiraQueries` at all. Fix: add `accountID` to `JiraRelease`, pass `release.accountID` through both queries, and add a two-account fixture test that mirrors the Go test.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
