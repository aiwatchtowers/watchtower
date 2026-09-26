---
type: chore
title: "OnboardingView (1586 LOC) holds untested non-UI logic: config.yaml hand-edits, CLI argv, sync ETA"
status: open
priority: med
tags: [test-coverage, onboarding, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track test coverage (Swift Desktop)
created: 2026-09-26
---

**Where:** WatchtowerDesktop/Sources/App/OnboardingView.swift:423-475 (checkAndContinue / yamlQuote / saveClaudePathToConfig), 1133-1206 (phase progress / ETA math), 1252-1296 (applySettingsAndSync), 1382-1470 (runSync), 1528-1582 (runCLI)
**Confidence:** high

The largest non-generated Sources file has no test at all. It rewrites `config.yaml` by string surgery: it filters lines with the prefix `claude_path:`, appends a quoted line, and silently ignores write errors with `try?`, while every other config write goes through the CLI. It builds `config set` argv in a detached task, computes sync ETA and phase counts from `SyncProgressData`, and runs its own `Process` wrapper (see the deadlock finding). The onboarding-unstick and feature-splash work (PRs #117/#118) tested `OnboardingCompletion` and `FeatureSplashLogic`, but these paths stayed in the view. Suggest extracting a testable `OnboardingSetupService` (config writes through `config set`, argv builder, ETA math) and covering the YAML quote/injection case, a missing config file, and a failed `config set` (the error path that stops the flow).

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
