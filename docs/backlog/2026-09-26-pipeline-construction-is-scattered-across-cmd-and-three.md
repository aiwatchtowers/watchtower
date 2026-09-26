---
type: chore
title: "Pipeline construction is scattered across cmd/, and three property scans exist only to catch its wiring holes"
status: open
priority: high
tags: [cmd, wiring, composition-root, prompts, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track architecture
created: 2026-09-26
---

**Where:** cmd/sync.go:771 (wireSlackSyncers) + :842/:924/:991/:1038, cmd/memory.go:198, cmd/ideas.go:80, cmd/reaction_commands.go:63, cmd/prompt_store_scan_test.go, cmd/jira_key_detector_wiring_test.go
**Confidence:** high

Each pipeline is constructed independently at every CLI command and again for the daemon: `prompts.New(` appears 40 times in non-test cmd/, `SetPromptStore(` 35 times, `meeting.New(` 8, `digest.New(` 5, `tracks.New(`/`targets.New(`/`inbox.New(` 4 each. The daemon wiring alone is spread over 9 `wire*` functions in 4 files. The cost has already been paid: the wave-5 prompt-store incident (SetPromptStore never called for briefing/digest/tracks/guide, then 7 more holes on CLI paths) and the Jira sub-logger holes were both "one construction site forgot a setter". They are now held off by `go/parser` property scans rather than by construction. Direction: add one per-pipeline constructor in `internal/app` (or `cmd/pipelines.go`), e.g. `newDigestPipeline(deps)`, that applies the prompt store, logger and generator in one place. Daemon wiring and every CLI command call it. Migrate one pipeline at a time. Once none is left, the scans shrink to "no bare `x.New(` outside the factory".

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
