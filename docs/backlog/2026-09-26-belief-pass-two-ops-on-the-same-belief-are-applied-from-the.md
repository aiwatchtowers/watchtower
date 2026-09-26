---
type: bug
title: "Belief pass: two ops on the same belief are applied from the same snapshot, so the last one wins and the others are lost"
status: open
priority: med
tags: [memory, beliefs, ai-output-validation, MEM-09, MEM-06, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/memory/beliefs.go:177-193, internal/memory/beliefs.go:346, internal/memory/vault.go:538 (plus reflect.go:209 / applyReflectNote)
**Confidence:** high

`applyExistingOp` always starts from `candidatesByID[op.BeliefID]`, the pre-pass snapshot, and the map is never updated after an op applies. If the reply holds two ops for one belief (the prompt asks for "at most ONE op per existing belief", but code never enforces it), both apply to the snapshot, both nodes are appended to `nodes`, and `WriteNodes` writes the same file twice, so the last op wins. The first op's evidence lines, `## History` entry and state change are silently dropped, yet both still count toward `touched`/`beliefs_max`. Scenario: op1 `weaken` cites a staged `chat:` owner turn (owner-rank evidence, MEM-09); op2 `confirm` cites an episode ref. Only op2 lands. The pass counts as clean with no cap-hit, so `advanceChatFloor` moves the floor past that owner turn and the owner's statement is permanently lost. `filterNewEvidence` also fails to dedupe across the two ops, because neither op sees the other's lines. `Reflect` has the same pattern: two `note` observations on one entity → only the last note survives. Fix: track applied nodes by id and apply later ops to the updated node, or reject extra ops per belief id and count them.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
