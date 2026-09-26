---
type: chore
title: "Summary: largest Desktop source files with no test coverage"
status: open
priority: med
tags: [test-coverage, summary, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track test coverage (Swift Desktop)
created: 2026-09-26
---

**Where:** WatchtowerDesktop/Sources (non-View files; name-reference scan against Tests/**)
**Confidence:** med

Non-View files whose declared types and methods appear in no test:

| File | LOC |
|---|---|
| App/OnboardingView.swift | 1586 |
| WatchtowerCore/Database/Queries/JiraQueries.swift | 1035 |
| ViewModels/ProjectMapViewModel.swift | 507 |
| ViewModels/ReleaseDashboardViewModel.swift | 274 |
| ViewModels/MeetingPrepViewModel.swift | 223 |
| ViewModels/UserStatsViewModel.swift | 181 |
| Services/GoogleAuthService.swift | 153 |
| ViewModels/EpicProgressViewModel.swift | 130 |
| WatchtowerCore/Services/JiraBoardSyncManager.swift | 112 |
| Services/Transcription/WhisperKitEngine.swift | 111 |
| WatchtowerCore/Services/SlackAuthService.swift | 107 |
| WatchtowerCore/Database/DatabaseObserver.swift | 103 (dead) |
| ViewModels/PipelineHistoryViewModel.swift | 102 |
| WatchtowerCore/Database/Queries/MeetingNoteQueries.swift | 82 |
| WatchtowerCore/Database/Queries/UserStatsQueries.swift | 80 |
| WatchtowerCore/Database/Queries/PipelineRunQueries.swift | 75 |

Barely covered (one or two indirect references): `ViewModels/ChannelStatsViewModel.swift` 198 and `WatchtowerCore/Services/BackgroundTaskManager.swift` 479 (only `StepRecord`, the token totals and `resolvePendingAsSkipped` are tested; the `startPipelines` phase orchestration and the `disabledFeatures` gating are not).

Of the 13 `@Observable` classes with zero test references, 9 are view models or services. That goes against the review-rules "every new @Observable ViewModel/center ships with its own test suite". Most of the gap is in the Jira dashboards, statistics, onboarding, and the auth/CLI wrappers; the core feature centers (MeetingRecorder, Dictation, Target*, CatchUp, Ideas, Features) are well covered.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
