---
type: bug
title: "People \"Connections\" view and meeting-prep read tables that nothing has written since People v2"
status: open
priority: med
tags: [people, desktop, meeting-prep, dead-code, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track usage analysis & dead functionality
created: 2026-09-26
---

**Where:** WatchtowerDesktop/Sources/ViewModels/PeopleViewModel.swift:90,127; WatchtowerDesktop/Sources/Views/People/ConnectionsView.swift:5; internal/meeting/pipeline.go:294; internal/db/user_analyses.go (1093 lines)
**Confidence:** high

`user_interactions`, `user_analyses` and `period_summaries` have 0 rows on the live install and no
production writer: `UpsertUserAnalysis`, `UpsertUserInteractions`, `UpsertPeriodSummary`,
`ComputeUserInteractions`, `GetUserAnalysesForWindow`, `DeleteUserAnalysesOlderThan`,
`ActiveUsersInWindow` have zero non-test callers (the writers died with the v1 people pipeline). Yet the
People tab's `ConnectionsView` is fed from `InteractionQueries.fetchForUser` (always empty — a visible, dead
UI section), and meeting prep's attendee block still calls `GetLatestUserAnalysis` (always nil) right after
reading the same fields from `people_cards`. Also `CLAUDE.md` still names "the reactions_to/from pairs in
user_analyses" as a live reactions consumer. Recommendation: either feed Connections from people_cards /
`digest_participants` or remove the section; delete the dead DB functions, the `GetLatestUserAnalysis`
branch in meeting prep, and (via migration) the three tables.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
