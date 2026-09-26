---
type: bug
title: "Onboarding \"Connect Slack\" freezes the whole app for up to 5 minutes (MainActor-isolated blocking runCLI)"
status: open
priority: high
tags: [swift, main-thread, onboarding, concurrency, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Swift Desktop)
created: 2026-09-26
---

**Where:** WatchtowerDesktop/Sources/App/OnboardingView.swift:1528-1583 (runCLI), :1208-1250 (startBrowserOAuthFlow), :1253-1290 (applySettingsAndSync)
**Confidence:** high

`OnboardingView` conforms to `View`, which the SDK marks `@MainActor`, so its `private static func runCLI(...) async` is MainActor-isolated too. The team relies on this elsewhere: `SystemSettings.runCLIProbe` is marked `nonisolated` with the comment "View infers @MainActor". `runCLI` is not. It has no suspension points, only a synchronous `process.waitUntilExit()` (plus a `readabilityHandler` path). Every `Task.detached { await Self.runCLI(...) }` therefore hops back onto the main actor and blocks it until the child exits. For `auth login` that is the user's whole browser OAuth round-trip, and up to `loginTimeout` = 5 min (internal/auth/oauth.go:37) if they abandon it. The app beachballs, the "Complete the Slack authorization in your browser" status set just before may never render, and nothing can cancel. `auth trust-cert` and every `config set` on the Settings step block the main thread the same way. Fix: mark `runCLI` `nonisolated` (the SystemSettings precedent), or route through `ProcessCLIRunner`.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
