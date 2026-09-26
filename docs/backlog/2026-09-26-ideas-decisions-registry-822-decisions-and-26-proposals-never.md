---
type: question
title: "Ideas/Decisions registry: 822 decisions and 26 proposals never looked at"
status: open
priority: med
tags: [ideas, decisions, usage, ai-cost, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track usage analysis & dead functionality
created: 2026-09-26
---

**Where:** internal/ideas/consolidate.go; WatchtowerDesktop/Sources/Views/Digests/DecisionsListView.swift:48
**Confidence:** high

All 822 `kind='decision'` rows have `seen_at IS NULL` (the Decisions list stamps `seen_at` on select, so the
ledger has never been opened), no idea or decision has an owner rating, and 26 ideas sit in `proposed`
(the review queue) — only 2 active ideas exist, one of them created via the reaction path today. The
strong-tier `ideas.consolidate` pass still runs every 6 h (44 runs/30d). Owner call: surface decisions
somewhere they are actually seen (Catch-Up already reads decisions), lower the mining cadence, or
default `ideas.enabled` off until the review UX gets used.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
