---
type: bug
title: "Jira sprint sync reads only the first 50 sprints per state, so a finished sprint stays \"active\" forever"
status: open
priority: high
tags: [jira, sync, pagination, sprints, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go sync/daemon/integrations)
created: 2026-09-26
---

**Where:** internal/jira/sync.go:758-803, internal/jira/models.go:162 (SprintList.IsLast unused), internal/db/jira.go:1098-1100, internal/db/jira.go:349-352
**Confidence:** high

`SyncSprints` makes one request per state (`active`, `closed`) with `maxResults=50` and never looks at `IsLast`/`startAt`. The Agile `board/{id}/sprint` endpoint orders sprints by state, then by backlog position, so for `state=closed` page 1 holds the 50 OLDEST closed sprints. On a board with more than 50 closed sprints (about two years of two-week sprints), the sprint that just ended is not in the `active` response and not in the first `closed` page either. `UpsertJiraSprint` never runs for it again, so its row keeps `state='active'` indefinitely, and each later sprint adds another stale "active" row. `GetJiraActiveSprintStats` then does `ORDER BY start_date LIMIT 1`, which picks the OLDEST stale sprint as "the" active sprint, and `GetJiraActiveSprints` returns all of them. Every sprint-based surface (sprint stats, workload, board context) goes wrong without any error. Fix: paginate until `IsLast`. As a second safeguard, flip any `active` row the `active` response no longer returns (on a clean pass) to `closed`.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
