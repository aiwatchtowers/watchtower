---
type: bug
title: "A failed create_jira_issue whose request actually landed is re-sent by Retry (duplicate issue)"
status: open
priority: med
tags: [tools, agent-actions, jira, idempotency, agent-05, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/tools/jira.go:185-196, internal/tools/registry.go:370-404, internal/jira/create.go:111-123
**Confidence:** med

`Apply` accepts a row in `failed` for a retry, and the Desktop offers Retry on failed cards. `create_jira_issue` returns an error, so the row becomes `failed`, in cases where Jira may already have created the issue: the whole-request HTTP timeout fires after the POST was sent, the connection resets while the response is being read, or `json.Unmarshal` of a 201 body fails (`create.go:121-123`, where `io.ReadAll`'s error is also discarded). The owner then retries and gets a second ticket. The AGENT-05 claim prevents two concurrent applies, but not a sequential re-send after an ambiguous outcome. The inventory's own "Why locked" names this exact harm ("a double apply is a duplicate Jira issue"). Fix direction: tag each created issue with an idempotency marker (for example a `watchtower-action-<id>` label, or a JQL lookup on summary + project + created ≥ the row's `created_at`), and check for it before re-sending on a retry of a failed row. Alternatively, record post-send failures as "outcome unknown" and never auto-offer Retry for them. Changing Retry semantics touches AGENT-05, so it needs an owner call.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
