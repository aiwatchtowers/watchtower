---
type: chore
title: "internal/digest doubles as the AI-infrastructure package for 18 importers"
status: open
priority: med
tags: [layering, go, ai, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track architecture
created: 2026-09-26
---

**Where:** internal/digest/pipeline.go:27 (Usage), :39 (Generator), internal/digest/pooled.go:72 (WithSource), internal/digest/models.go:17 (TierForSource), internal/digest/generator.go:87 (StdinThreshold)
**Confidence:** high

The Generator interface, `Usage`, source tagging, tier routing, stdin threshold, `ClaudeGenerator` and the pooled/timeout wrappers all live in the same package as the 2,527-line Slack channel-digest pipeline (the largest Go file). 18 packages import `internal/digest`. Across `cmd` and `internal`, the most-used symbols are `digest.Usage` (121 uses), `digest.Generator` (77), `digest.WithSource` (47), `digest.IdeaCandidate` (41) and `digest.StdinThreshold` (13); only a handful of call sites use the digest pipeline itself. So every AI consumer (memory, ideas, briefing, catchup, reactioncmd, targets, tracks…) depends on the Slack digest domain package, including its `slack` and `sessions` imports. The tier-scan test and the "generator must read `digest.SourceFromContext`" rule show this is really a cross-cutting LLM layer. Direction: move Generator/Usage/WithSource/Tier*/StdinThreshold and the generator decorators into a leaf `internal/llm` package. Leave type aliases in `digest` for one release, then drop them. The rename is mechanical, and the scan tests keep working if they are pointed at the new import path.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
