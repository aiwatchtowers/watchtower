---
type: bug
title: "ai.limitedWriter returns a short count, turning a successful claude run into \"short write\""
status: open
priority: med
tags: [ai, subprocess, error-handling, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/ai/client.go:573-584 (used at :393 and :490)
**Confidence:** high

When a single stderr write crosses the 64 KB cap, `Write` truncates `p` and returns `n < len(p)` with a nil error. `os/exec` copies stderr with `io.Copy`, which converts that into `io.ErrShortWrite`, stops draining (and closes) the stderr pipe, and `cmd.Wait` returns "short write" even though the process exited 0. Verified with an overlay test: a child that writes 3 bytes then 70000 bytes to stderr and exits 0 yields `err=short write` from `cmd.Output()`. Consequences: `QuerySync` discards a good answer ("claude CLI error: short write"), `Query` emits an error event after a complete streamed answer, and the child may get EPIPE on later stderr writes. The sibling copies in internal/codex/generator.go:165-180 and internal/digest/generator.go:26-40 correctly return `len(p)`. Fix: return the original length when truncating (same as codex).

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
