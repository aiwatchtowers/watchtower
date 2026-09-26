---
type: bug
title: "Ollama streaming chat swallows mid-stream errors and truncated streams"
status: open
priority: med
tags: [ollama, streaming, silent-failure, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/ollama/client.go:133-165 (streamSSE), :55-64 (chatResponse)
**Confidence:** med

OpenAI-compatible servers (Ollama, vLLM, LM Studio) report failures after a 200 status as an SSE `data: {"error":{...}}` line (e.g. model OOM / context overflow while generating). `chatResponse` has no `error` field, so the line unmarshals to zero choices and is `continue`d; the stream then ends and `streamSSE` returns with no error. Likewise a connection closed before `data: [DONE]` (server crash/restart) ends the scan cleanly with `scanner.Err() == nil`. Scenario: the Desktop chat on the Ollama provider shows an empty or half answer followed by a normal `done` event, indistinguishable from a real reply. Fix: decode an `error` object and send it to errCh; treat EOF without `[DONE]` (and without a `finish_reason`) as an error.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
