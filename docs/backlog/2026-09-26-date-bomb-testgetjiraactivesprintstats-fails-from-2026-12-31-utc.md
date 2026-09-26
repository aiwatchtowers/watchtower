---
type: chore
title: "Date bomb: TestGetJiraActiveSprintStats fails from 2026-12-31 UTC"
status: open
priority: high
tags: [test-coverage, flaky, date-bomb, jira, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track test coverage (Go)
created: 2026-09-26
---

**Where:** internal/db/jira_test.go:623-658, internal/db/jira.go:1138-1150
**Confidence:** high

The test seeds an active sprint with the hardcoded `EndDate: "2026-12-31"` and asserts `stats.DaysLeft > 0`. `GetJiraActiveSprintStats` computes `math.Ceil(time.Until(endTime).Hours()/24)` against the wall clock, so from 2026-12-31T00:00Z it yields 0 (then negative) and `go test ./internal/db` goes red on every branch, with no code change: CI breaks in about three months. Same class as the recorded "no hardcoded dates in tests" lesson. Suggested fix: seed `EndDate` from `time.Now().AddDate(0,0,14)` in the test. A better fix is to give the function an injectable `now` so `DaysLeft` can be asserted exactly.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
