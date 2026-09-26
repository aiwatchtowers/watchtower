---
type: chore
title: "The chat streaming reducer is copied 8 times; the Idea and Meeting chat ViewModels are about 70% identical"
status: open
priority: med
tags: [swift, duplication, chat, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track architecture
created: 2026-09-26
---

**Where:** ViewModels/{Chat,Target,Idea,Meeting,Onboarding,CalendarSetupChat,EmailSetupChat}ViewModel.swift, Views/Tracks/TrackChatView.swift (TrackChatViewModel)
**Confidence:** high

The same `for try await event in stream { .text / .turnComplete / .reset / .sessionID / .done }` reducer with the `sawTurnComplete` flag appears in 8 files, 12 loops in total (Onboarding has 3). `cancelStream`/`handleSessionID`/`persistMessage`/`finishStream`/`updateLastMessage` are re-declared in 7 files. `IdeaChatViewModel` and `MeetingChatViewModel` share 160 of Idea's 229 distinct non-blank lines. The chat ViewModels total 4,260 lines. CLAUDE.md calls this a "deliberate third copy / house pattern", but it now has 8 copies, and a fix to stream semantics (for example `.reset` or partial-persist-on-cancel) must land 8 times. Direction: extract a `ChatStreamSession` (reducer + persist + cancel + session-id handling) into WatchtowerCore, which is testable without the ML stack. Each ViewModel keeps only its prompt, context block and action hooks. Migrate the two draft-only ViewModels (Idea, Meeting) first, since they are nearly identical.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
