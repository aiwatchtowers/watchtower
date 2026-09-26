---
type: bug
title: "Briefing panics on a nil Usage (HTTP provider without a usage block)"
status: open
priority: high
tags: [briefing, nil-deref, ollama, daemon-crash, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/briefing/pipeline.go:247 (plus internal/ollama/generator.go:85-95)
**Confidence:** high

`RunForDate` guards `usage != nil` when reading the token counts (lines 227-231), then builds the row with `Model: usage.Model` with no guard. `ollama.Generator.Generate` returns `usage == nil` and `err == nil` whenever the OpenAI-compatible server leaves out the `usage` object. Some LM Studio and vLLM builds do this, and so do some proxies. In that case the briefing phase dereferences nil. `internal/daemon` has no `recover()`, so the panic takes down the whole daemon. The Desktop then respawns it, and it crashes again on the next briefing cycle. Every other pipeline in this set guards the same field: digest.go:1746, guide.go:508/764, tracks.go:668, dayplan.go:128. Fix: default `Model` to `"auto"` and set it only inside the existing `if usage != nil` block. Add a test with a fake generator that returns `(text, nil, "", nil)`.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
