---
type: bug
title: "Jira write tools re-resolve the account at Apply time, not at Propose time"
status: open
priority: med
tags: [tools, agent-actions, jira, multi-account, external, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/tools/jira.go:159-170, internal/tools/jira.go:177-188, internal/tools/jira_board.go:113, internal/tools/jira_board.go:131, internal/tools/registry.go:284-293
**Confidence:** high

`create_jira_issue` and `connect_jira_board` accept `account_id` omitted or 0 ("the single enabled account"). `Validate` resolves it and checks `projectSynced` against that account at propose time, but the row stores the raw args with 0. `Execute` runs `ResolveJiraAccount(d, 0)` again when the owner clicks Approve, and it does not re-check `projectSynced`. Scenario A: a proposal is pending with one site connected, then the owner connects a second site before approving. Apply fails with "several Jira sites are connected — pass account_id", and every Retry fails the same way, because nothing can edit the args. Scenario B: site A is disabled and site B is enabled in between. The issue is filed on site B in whatever project shares the key, and that project was never validated. This is an External write landing on the wrong site. Fix: have Validate/Propose pin the resolved `account_id` into the stored `args_json` (or re-run `Validate` inside `Apply` before `Execute` and fail with a clear message).

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
