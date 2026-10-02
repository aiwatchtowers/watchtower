---
type: chore
title: "Ten hand-rolled getPrompt helpers with three fallback semantics; three AI prompts bypass the prompt store"
status: done
priority: med
tags: [prompts, go, duplication, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track architecture
created: 2026-09-26
---

**Where:** internal/{guide,memory,targets,digest,briefing,tracks,reactioncmd,ideas,catchup}/pipeline.go getPrompt; internal/meeting/recap.go:130-138; internal/digest/prompt.go:3-192; internal/targets/nextstep.go:47; internal/inbox/style_sample.go:14; internal/catchup/prompt.go:176
**Confidence:** high

`func (p *Pipeline) getPrompt` is re-implemented in 9 packages, and `meeting` has its own per-prompt variant. There are three different fallbacks: a local compiled const (digest, targets, guide), `prompts.Defaults[id]` (meeting), or nothing. `internal/digest/prompt.go` still keeps 5 full prompt consts that duplicate `prompts/defaults.go`. They have already drifted (the compiled copies lack the `ideas` array; see the digest compiled-fallback finding), and unlike `targets` (`internal/targets/prompt_store_test.go`) nothing pins them, and that drift is exactly what killed Slack idea mining until wave 5. Separately, `targets.next_step`, `inbox.style_sample` and `catchup.learn` send AI calls with system prompts that are not registered in `prompts` at all, so Settings → Prompts cannot tune them. Direction: add one `prompts.Resolve(store, id) (tmpl, version)` that falls back to `prompts.Defaults` (the meeting shape), delete the per-package consts and helpers, and register the three missing prompts, with version bumps where the text changes.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»

**Resolution (2026-10-02, branch `fix/prompt-helpers-and-tool-names`):** `prompts.Resolve(store, id, role)` is the one lookup (`internal/prompts/resolve.go`): the store row (role variant first when a role is given), else `prompts.Defaults[id]` at version 0; a failed store read returns the default plus the error for the caller to log. `prompts.WithRoleInstruction` carries the role prepend shared by digest/tracks/people/briefing. Every package helper (digest, guide, tracks, briefing, memory, targets, reactioncmd, ideas, catchup, meeting ×6 loaders → one, dayplan, plus the `cmd/` lookups for chat.title, terminal.title, dictation.clean, tasks.generate/update) now wraps it and only adds its log line; briefing keeps its placeholder-count guard on top. The compiled fallback consts are gone (`internal/digest/prompt.go`, `internal/targets/prompts.go`, the meeting `*PromptFallback` consts, guide's `defaultPeople*Prompt` vars). `targets.next_step`, `inbox.style_sample` and `catchup.learn` are registered at v1 with unchanged text, and `inbox.Pipeline` gained a `SetPromptStore` seam wired at all four `cmd/` construction sites.

Semantics that changed on purpose (each was a bug or an inconsistency): the digest no-store fallback now renders the registry default (the compiled consts had drifted and lacked the `ideas` array); an empty stored template now falls back to the default everywhere (it already did in meeting/dayplan/cmd — elsewhere it would have sent an empty system prompt); a failed store read is logged everywhere (it was silent outside targets/catchup/terminal); day plan's version label reads `default` rather than `stored:0` when the store has no row.
