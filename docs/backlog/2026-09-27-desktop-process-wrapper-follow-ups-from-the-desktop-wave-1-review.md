---
type: chore
title: "Desktop process-wrapper follow-ups from the desktop wave-1 review"
status: open
priority: low
tags: [desktop, process, slack, onboarding, review-2026-09-27, bundle]
context: debate-review of fix/backlog-desktop-wave1 — deferred findings
created: 2026-09-27
---

Deferred from the debate-review of the shared `ProcessPipes` helper and the Slack status rework. None is
a regression of that branch; each is pre-existing and now sits in one place.

## Cancel can miss the Slack reconnect process around launch
- where: WatchtowerDesktop/Sources/Views/Settings/SlackConnectionDetail.swift (reconnect flow, cancelSlackReconnect)

`flow.authProcess` is published before `ProcessPipes.run` launches it and Cancel only terminates a running
process, so a Cancel in that hop (or during the seconds-long `auth trust-cert` step) is lost and
`auth login` still opens the browser. Main had the mirror-image window. Fix: a `cancelRequested` flag
checked right before launch and after trust-cert, or an `onLaunch` callback from `ProcessPipes.run`.

**Status (fix/desktop-low-bundle):** fixed with both: Cancel sets a lock-guarded flag the flow checks after trust-cert, and `ProcessPipes.run(onLaunch:)` re-checks it once `auth login` is running.

## Writing stdin to an exited child can kill the app with SIGPIPE
- where: WatchtowerDesktop/Sources/WatchtowerCore/Services/ProcessPipes.swift (stdin write)

`fileHandleForWriting.write(data)` to a child that already exited (e.g. cobra rejected a flag before
reading `--secret-stdin`) raises SIGPIPE, whose default action terminates Watchtower.app; nothing ignores
it. Fix: `signal(SIGPIPE, SIG_IGN)` at launch plus `try write(contentsOf:)` with a catch; narrow the doc
comment to "cannot deadlock".

**Status (fix/desktop-low-bundle):** already fixed in 6982eade (`F_SETNOSIGPIPE` on the write end, `try write(contentsOf:)` with a logged catch).

## ProcessPipes pins three cooperative-pool threads per long-lived child
- where: WatchtowerDesktop/Sources/WatchtowerCore/Services/ProcessPipes.swift (drain/run)

Two blocking `readDataToEndOfFile` and one `waitUntilExit` run in `Task.detached` for the child's whole
life; a 5-minute OAuth child holds three threads of the core-count-sized pool (ProcessCLIRunner
precedent). Fix: `terminationHandler` + `readabilityHandler`, or a dedicated DispatchQueue.

**Status (fix/desktop-low-bundle):** already fixed in 20cc4828 (every blocking call runs on a thread of its own, `BlockingCall`).

## Call-site drain wiring is untested
- where: JiraBoardSyncManager, BackgroundTaskManager, DatabaseManager.runCLIMigrations

The shared helper is pinned by ProcessPipesTests, but nothing tests that these call sites start the
stderr drain before streaming stdout. `runCLIMigrations` also still blocks the main thread in
`ensureOnboardingDatabase()` and only logs a failed migration (its launch failure is not logged at all).

**Status (fix/desktop-low-bundle):** Jira board sync and `db migrate` now have call-site tests with >64 KiB of stderr (`JiraBoardSyncProcessTests`, `testMigrateLargeStderrIsDrainedNotTimedOut`); the main-thread block and the unlogged launch failure were fixed in dfb0ba02. Left: `BackgroundTaskManager` (needs a MainActor harness with an injectable CLI path) and "only logs a failed migration" (product call, see the Swift bugs bundle).

## Onboarding model presets still hardcode claude aliases
- where: WatchtowerDesktop/Sources/WatchtowerCore/Services/OnboardingSettingsPlan.swift, OnboardingView ModelPreset

Now gated to provider claude, but `haiku`/`opus` are still literals in Swift against the "no model names
in Swift" rule. Fix: source the preset choices from AIModelCatalog.

**Status (fix/desktop-low-bundle):** left: `ai models --json` reports only light/strong defaults per provider, so there is no registry source for the Quality preset (`opus`); it needs a registry field first.

## Owner call: what "Disconnect Slack" means on a multi-account install
The Workspace-level Disconnect runs `auth logout` (account #1 only). The wave shows it only while
account #1 itself is connected. Decide: disconnect everything, account #1 only (current), or drop it
in favour of the per-row Remove buttons.

**Status (fix/desktop-low-bundle):** left: owner call.

> Original note: «так там два больших фичи влилось. Пройдись еще разок, дополнии беклог и давай его начинать закрывать»
