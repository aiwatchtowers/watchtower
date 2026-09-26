---
type: bug
title: "Settings → Slack \"Workspace\" status reads the retired config.yaml token, always shows \"not connected\""
status: open
priority: med
tags: [test-coverage, multi-account, settings, slack, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track test coverage (Swift Desktop)
created: 2026-09-26
---

**Where:** WatchtowerDesktop/Sources/WatchtowerCore/Services/SlackAuthService.swift:40-56, WatchtowerDesktop/Sources/Views/Settings/SlackConnectionDetail.swift:47-49,54-95
**Confidence:** high

`SlackAuthService.checkStatus()` sets `isConnected = tokenPresent()`, which returns true only when `config.yaml` has `workspaces.<active>.slack_token`. Since Slack multi-account (migration 00048), `ensureLegacySlackAccount` moves that token into `slack_token_1.json` and blanks the config value, and a fresh install has no `workspaces` block at all. `OnboardingView.hasConnectedSlackAccount()` (line 1375) already says the check is retired and switched to `slack_accounts`, but the Settings → Slack "Workspace" section still uses `SlackAuthService`. Result: every post-migration install sees "Slack not connected" and a "Connect Slack" button next to a list of healthy accounts, and the Disconnect button never shows. `SlackAuthService` has zero tests. Fix: derive the status from `SlackAccountQueries.fetchAll` (enabled, not removed), the same way `GoogleAuthService`/`GmailAuthService.checkStatusAsync` read the DB, or remove the legacy section. Add a test with a fixture config that has no token but a `slack_accounts` row.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
