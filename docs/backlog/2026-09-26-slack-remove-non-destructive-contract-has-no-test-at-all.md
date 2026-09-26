---
type: chore
title: "slack remove non-destructive contract has no test at all"
status: open
priority: med
tags: [test-coverage, deletion, multi-account, slack, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track test coverage (Go)
created: 2026-09-26
---

**Where:** cmd/slack.go:355 (runSlackRemove 0%), cmd/slack.go:379 (removeSlackAccount 0%), cmd/slack.go:174 (rollbackSlackAccount 0%)
**Confidence:** high

CLAUDE.md makes `slack remove` deliberately non-destructive: the token file is deleted, the row becomes `status='removed'`/`enabled=0`, and channels, messages, digests, tracks and memory are kept. That is a documented departure from `google remove`'s cascade. None of `runSlackRemove`, `removeSlackAccount` or the add-failure `rollbackSlackAccount` is executed by any test (cmd profile 0%). By contrast, `removeGoogleAccount` is at 85.7% and `removeJiraAccount` at 60%. A refactor that routes Slack removal through a cascading delete, or forgets the token-file delete, would pass CI. Suggested fix: a cmd test that seeds messages and a digest under `"2:..."`, runs remove, and asserts that the data rows are intact, the token file is gone, and the row is `removed`/disabled.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
