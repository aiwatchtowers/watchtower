---
type: bug
title: "Codex JSONL parser ignores scanner errors and can return an intermediate message as the answer"
status: open
priority: med
tags: [codex, parsing, silent-failure, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/codex/generator.go:119-156 (parseJSONLOutput; used by Generate :72 and Client.QuerySync client.go:256)
**Confidence:** med

`parseJSONLOutput` scans with a 1 MB max token but never checks `scanner.Err()`. Codex's `item.completed` lines for `command_execution` (carries `aggregated_output`) and `mcp_tool_call` (carries the tool result) can exceed 1 MB; `Scan` then returns false, every later line (including the final `agent_message` and any `turn.failed` error) is silently skipped, and the function returns whatever `agent_message` came earlier — typically the model's pre-tool preamble ("Let me look that up…") — as a successful result. For `ask`/QuerySync that preamble is shown as the answer; for the batch generator it becomes a JSON parse failure downstream attributed to the model. The streaming `Query` (client.go:194) does check `scanner.Err()`, so this is an inconsistency. Fix: check `scanner.Err()` and return it; consider a larger buffer or `bufio.Reader.ReadLine`-style skipping of oversized non-message lines.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
