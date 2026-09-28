---
type: bug
title: "Ollama streaming chat swallows mid-stream errors and truncated streams"
status: done
priority: med
tags: [ollama, streaming, silent-failure, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/ollama/client.go:133-165 (streamSSE), :55-64 (chatResponse)
**Confidence:** med

OpenAI-compatible servers (Ollama, vLLM, LM Studio) report failures after a 200 status as an SSE `data: {"error":{...}}` line (e.g. model OOM / context overflow while generating). `chatResponse` has no `error` field, so the line unmarshals to zero choices and is `continue`d; the stream then ends and `streamSSE` returns with no error. Likewise a connection closed before `data: [DONE]` (server crash/restart) ends the scan cleanly with `scanner.Err() == nil`. Scenario: the Desktop chat on the Ollama provider shows an empty or half answer followed by a normal `done` event, indistinguishable from a real reply. Fix: decode an `error` object and send it to errCh; treat EOF without `[DONE]` (and without a `finish_reason`) as an error.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»

**Resolution:** `chatResponse` gained an `Error *chatError` field (the OpenAI-compatible inline error object) and `chatChoice` a `FinishReason` field. `streamSSE` now returns an error immediately on an `{"error":{...}}` SSE line (via a new bounded/rune-safe `formatChatError`, capped at 1024 bytes like the sibling non-streaming HTTP-error-body reads in this same file) instead of silently `continue`-ing past it, and tracks whether `[DONE]` or any chunk's `finish_reason` was ever seen — an EOF with neither (connection closed early) now also surfaces as an error instead of a clean, silently truncated stream. `QuerySync` and the digest `Generator.Generate` (both decode the same `chatResponse` shape) gained the same inline-error check ahead of their existing "no choices" fallback, so a 200 response carrying only an error object reports that error instead of a generic and less actionable "no choices"/"empty result". Pinned by `TestStreamSSE_InlineErrorObjectSurfacesAsError`, `TestStreamSSE_ConnectionClosedBeforeDoneIsAnError`, `TestQuerySync_InlineErrorObjectSurfacesAsError`, and `TestGenerator_ErrorPaths`'s new inline-error case (all fail on pre-fix code, verified by reverting `internal/ollama/client.go` and re-running), plus `TestStreamSSE_FinishReasonWithoutLiteralDoneIsNotAnError` pinning the degenerate clean-exit case (no literal `[DONE]`, stream ends right after a `finish_reason` chunk) as still not an error.
