---
type: bug
title: "Memory run aborts on an empty git commit — 80% error rate over 30 days"
status: open
priority: med
tags: [memory, vault, pipeline-runs, reliability, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track usage analysis & dead functionality
created: 2026-09-26
---

**Where:** internal/memory/vault.go:530-560 (WriteNodes), internal/memory/beliefs.go:185-210 (plus 12 other WriteNodes callers)
**Confidence:** med

`Vault.WriteNodes` renders each node, stages it, and unconditionally calls `wt.Commit`; if every rendered
node is byte-identical to what is on disk, go-git returns "cannot create empty commit: clean working tree"
and the error aborts the whole `Pipeline.Run`. Live install: 272 memory runs failed with exactly this error
since 2026-07-18, 97 of them in a single 2026-09-19..09-24 streak (log shows the same situation-chat turns
re-ingested every cycle right before the failure, i.e. the chat-turn floor never advances while the run
keeps failing). Any `applied` op whose rendered node equals the stored one (e.g. a belief op that changes
nothing visible) hits it. Errors stopped after 09-25, possibly by coincidence of a binary update — the code
path is unchanged on main. Fix: in WriteNodes skip nodes whose rendered bytes equal the file (the
`WriteFile` precedent right below it already does this) and treat `git.ErrEmptyCommit` as a no-op.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
