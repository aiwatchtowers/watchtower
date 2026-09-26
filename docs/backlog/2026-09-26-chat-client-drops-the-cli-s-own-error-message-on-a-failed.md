---
type: bug
title: "Chat client drops the CLI's own error message on a failed claude run"
status: open
priority: med
tags: [ai, chat, error-handling, claude, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/ai/client.go:455-457 (Query), internal/ai/client.go:492-495 (QuerySync), internal/ai/client.go:596-606 (classifyError)
**Confidence:** high

The repo's own batch generator documents that the claude CLI "reports an API or usage failure as an ordinary result envelope on stdout and exits 1" (internal/digest/generator.go:284-291), and parses that envelope for the message. The chat client does not: `Query` ignores the `is_error`/`result` fields of the stream-json `result` event (`streamEvent` has no `IsError` field), and on the non-zero exit `classifyError` looks only at stderr, which is empty in this case. `QuerySync` discards `output` entirely on `cmd.Output()` error. Scenario: an expired login, exhausted credit, or an unknown model name in the Desktop chat or `watchtower ask` -> the user sees only "claude CLI failed with exit code 1", with the actionable reason ("Invalid API key · Please run /login") thrown away. Fix: in Query, remember the last `result` event (is_error + result) and use it for the error when Wait fails (or when it is `is_error` with exit 0); in QuerySync, reuse the digest generator's envelope-first parse on ExitError.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
