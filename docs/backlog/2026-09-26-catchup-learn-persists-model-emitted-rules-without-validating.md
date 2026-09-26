---
type: bug
title: "catchup.learn persists model-emitted rules without validating scope_key, pipeline or weight"
status: open
priority: med
tags: [catchup, learned-rules, ai-validation, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/catchup/learn.go:71-89 (plus internal/catchup/prompt.go:185-202)
**Confidence:** high

The learn prompt says "build scope_key ONLY from the channel_id / sender_user_id supplied … never invent ids", but the code checks only for non-empty `RuleType`/`ScopeKey`. The following are all written through to `inbox_learned_rules`, which the digest, tracks, briefing and catchup prompts all read:
- a `scope_key` naming an id that is not in `refs`, including the literal example `digest:channel:Cxxx`, or a raw vs namespaced mismatch;
- a `pipeline` outside {digest, tracks, inbox, briefing, catchup};
- a `weight` outside [-1, 1].

A `rule_type` outside the table CHECK aborts the loop halfway with an error. By then some rules are already persisted and the regen never runs, while the feedback row is already written. This is the same "model proposes, code disposes" gap the recap body closed with CATCHUP-04. Fix: allowlist `pipeline` and `rule_type`, clamp `weight`, require the id inside `scope_key` to be one of the enriched ref ids, and skip invalid rules instead of aborting.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
