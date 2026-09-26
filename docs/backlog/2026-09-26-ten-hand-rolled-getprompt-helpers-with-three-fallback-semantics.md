---
type: chore
title: "Ten hand-rolled getPrompt helpers with three fallback semantics; three AI prompts bypass the prompt store"
status: open
priority: med
tags: [prompts, go, duplication, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track architecture
created: 2026-09-26
---

**Where:** internal/{guide,memory,targets,digest,briefing,tracks,reactioncmd,ideas,catchup}/pipeline.go getPrompt; internal/meeting/recap.go:130-138; internal/digest/prompt.go:3-192; internal/targets/nextstep.go:47; internal/inbox/style_sample.go:14; internal/catchup/prompt.go:176
**Confidence:** high

`func (p *Pipeline) getPrompt` is re-implemented in 9 packages, and `meeting` has its own per-prompt variant. There are three different fallbacks: a local compiled const (digest, targets, guide), `prompts.Defaults[id]` (meeting), or nothing. `internal/digest/prompt.go` still keeps 5 full prompt consts that duplicate `prompts/defaults.go`. They have already drifted (the compiled copies lack the `ideas` array; see the digest compiled-fallback finding), and unlike `targets` (`internal/targets/prompt_store_test.go`) nothing pins them, and that drift is exactly what killed Slack idea mining until wave 5. Separately, `targets.next_step`, `inbox.style_sample` and `catchup.learn` send AI calls with system prompts that are not registered in `prompts` at all, so Settings → Prompts cannot tune them. Direction: add one `prompts.Resolve(store, id) (tmpl, version)` that falls back to `prompts.Defaults` (the meeting shape), delete the per-package consts and helpers, and register the three missing prompts, with version bumps where the text changes.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
