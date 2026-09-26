---
type: idea
title: "Swift dual-path writers: about 37 tables written directly by the Desktop, and equivalence is pinned for only a few"
status: open
priority: high
tags: [swift, go, dual-path, data-integrity, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track architecture
created: 2026-09-26
---

**Where:** WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/*.swift, ViewModels/TargetsViewModel.swift:182-307, Views/Targets/SuggestLinksSheet.swift:129, ViewModels/OnboardingChatViewModel.swift:593, Database/DatabaseManager.swift:~100-135
**Confidence:** high

Raw `INSERT`/`UPDATE`/`DELETE` statements in Swift touch about 37 distinct tables (targets 20 statements, ideas 12, tracks 11, user_profile 9, meeting_transcripts 6…). About 30 Swift files state in comments that they mirror a Go writer ("dual-path", "mirrors the Go…"). Only a few pairs have a shared-fixture pin (transcript segments render, owner resolver, catch-up ack). Several writers sit outside the Queries layer altogether: raw SQL in `TargetsViewModel`, in a View (`SuggestLinksSheet`), in `OnboardingChatViewModel`, and the reset wipe in `DatabaseManager`. The next item shows a live divergence this has already produced. Direction, in three steps: (1) make an inventory table (`docs/inventory/dual-path.md`) listing each Swift writer, its Go twin, and its pin or "none". (2) Adopt a rule: a new Swift write either goes through the CLI (`watchtower <x> --json`, as `ideas mine` and `jira` already do) or ships with a shared JSON fixture that is replayed by a Go test and a Swift test. (3) Move the raw SQL out of Views/ViewModels into `*Queries` first, since that costs nothing and is a prerequisite.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
