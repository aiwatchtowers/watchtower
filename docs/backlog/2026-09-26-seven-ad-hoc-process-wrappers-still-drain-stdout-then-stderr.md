---
type: bug
title: "Seven ad-hoc Process wrappers still drain stdout then stderr sequentially (SB3 deadlock class)"
status: open
priority: med
tags: [test-coverage, cli, process, deadlock, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track test coverage (Swift Desktop)
created: 2026-09-26
---

**Where:** WatchtowerDesktop/Sources/ViewModels/{Slack,Email,Google,Jira,Calendar}AccountsViewModel.swift (runProcess), ExternalConnectionsViewModel.swift:305-308, MeetingPrepViewModel.swift:212-215, Services/GoogleAuthService.swift:141-144, WatchtowerCore/Services/SlackAuthService.swift:82-86; stderr-after-exit: WatchtowerCore/Services/BackgroundTaskManager.swift:365-381, WatchtowerCore/Services/JiraBoardSyncManager.swift:83-99, App/OnboardingView.swift:1528-1582
**Confidence:** med

`ProcessCLIRunner` (CLIRunner.swift:127-135, "SB3") and `CatchUpViewModel` (line 485) both document the same rule: stdout and stderr must be drained concurrently. Otherwise a child that writes more than 64 KiB to stderr blocks on write while the parent is still waiting for stdout EOF, and both sides hang forever. Ten other wrappers keep the broken shape. The account view models and auth services read stdout to EOF and only then read stderr. `BackgroundTaskManager.runTask`, `JiraBoardSyncManager.runSyncProcess` and `OnboardingView.runCLI` stream stdout but read stderr only after `waitUntilExit`, so a verbose `digest`/`jira sync --progress-json` run on a large workspace (per-channel error lines, provider warnings) freezes the first-run pipeline sidebar or the board-sync spinner with no timeout. None of these wrappers has a test. Fix: route them through `ProcessCLIRunner` (or one shared streaming variant) and add a single test with a child that writes more than 64 KiB to stderr before closing stdout.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
