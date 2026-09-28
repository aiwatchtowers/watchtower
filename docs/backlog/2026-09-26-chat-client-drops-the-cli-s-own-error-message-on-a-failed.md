---
type: bug
title: "Chat client drops the CLI's own error message on a failed claude run"
status: done
priority: med
tags: [ai, chat, error-handling, claude, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/ai/client.go:455-457 (Query), internal/ai/client.go:492-495 (QuerySync), internal/ai/client.go:596-606 (classifyError)
**Confidence:** high

The repo's own batch generator documents that the claude CLI "reports an API or usage failure as an ordinary result envelope on stdout and exits 1" (internal/digest/generator.go:284-291), and parses that envelope for the message. The chat client does not: `Query` ignores the `is_error`/`result` fields of the stream-json `result` event (`streamEvent` has no `IsError` field), and on the non-zero exit `classifyError` looks only at stderr, which is empty in this case. `QuerySync` discards `output` entirely on `cmd.Output()` error. Scenario: an expired login, exhausted credit, or an unknown model name in the Desktop chat or `watchtower ask` -> the user sees only "claude CLI failed with exit code 1", with the actionable reason ("Invalid API key · Please run /login") thrown away. Fix: in Query, remember the last `result` event (is_error + result) and use it for the error when Wait fails (or when it is `is_error` with exit 0); in QuerySync, reuse the digest generator's envelope-first parse on ExitError.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»

**Resolution:** `QuerySync` now parses `cmd.Output()`'s stdout on a non-zero exit before falling back to `classifyError`, using the CLI's own `is_error`/`result`/`subtype` envelope fields when present (mirroring `internal/digest/generator.go`'s already-reviewed `errorEnvelopeMessage` pattern) — added a `cliResponse.Subtype` field and a shared `envelopeMessage` helper (bounded at 4096 bytes, rune-safe truncation) to carry the message. `Query`'s streaming loop now remembers the last `"result"` event (added `streamEvent.IsError`) and surfaces its message both when `cmd.Wait()` fails and when the CLI flags `is_error` while still exiting 0. Pinned by `TestQuerySync_ExitErrorSurfacesEnvelopeMessage`, `TestQuerySync_CleanExitIsErrorSurfacesEnvelopeMessage`, `TestQuery_StreamingExitErrorSurfacesEnvelopeMessage`, `TestQuery_StreamingCleanExitIsErrorSurfacesEnvelopeMessage` (all fail on pre-fix code, verified by reverting `internal/ai/client.go` and re-running), plus degenerate-exit counterparts (`TestQuerySync_ExitErrorFallsBackWhenOutputUnparsable`, `TestQuery_StreamingExitErrorFallsBackWhenNoResultEvent`) that keep the plain stderr-based path working when there is no envelope to parse, and `TestEnvelopeMessage_*` unit tests for the truncation helper.
