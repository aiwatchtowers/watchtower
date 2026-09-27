---
type: chore
title: "Jira sprint sync re-reads the whole closed-sprint history every cycle"
status: open
priority: low
tags: [jira, api-budget, review-2026-09-27]
context: judge note on fix/backlog-wave1 (sprint pagination)
created: 2026-09-27
---

**Where:** internal/jira/sync.go (fetchBoardSprints, maxSprintPages = 40)
**Confidence:** high

With pagination fixed, each sync reads every closed sprint of every selected board (up to 40 pages per
state per board), because the Agile API lists closed sprints oldest first with no reverse order. Correct,
but the call count grows with board age. Direction: remember the last closed-sprint startAt per board and
start there (re-reading the final page), or only page closed sprints when a stored "active" sprint is
missing from the active listing.

> Original note: «так там два больших фичи влилось. Пройдись еще разок, дополнии беклог и давай его начинать закрывать»
