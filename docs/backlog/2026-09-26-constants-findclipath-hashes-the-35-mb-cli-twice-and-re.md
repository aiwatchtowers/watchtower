---
type: bug
title: "Constants.findCLIPath() hashes the 35 MB CLI twice and re-verifies its code signature on every call, often on the main thread"
status: open
priority: high
tags: [swift, performance, main-thread, dual-path-doc-drift, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Swift Desktop)
created: 2026-09-26
---

**Where:** WatchtowerDesktop/Sources/WatchtowerCore/Utilities/CLIBinaryStore.swift:40-50,71-75,200-203; WatchtowerCore/Utilities/Constants.swift:271-275; App/OnboardingView.swift:45-48,488,558; ViewModels/BriefingViewModel.swift:27
**Confidence:** med

`resolvedInstalledPath()` deliberately has "no launch-long cache" (a TOCTOU hardening). Each call runs `installedPath()`, which loads both the bundle binary and the store binary fully into memory with `FileManager.contents` and SHA-256s them. It then runs `SecStaticCodeCheckValidity`, which hashes the binary again. `findCLIPath()` has ~80 call sites, and several run on the main actor:
- `OnboardingView.hasCLI` is a computed property read inside `body` (lines 488 and 558), so every onboarding re-render pays this cost.
- `@State hasClaudeCLI = Constants.findCLIPath() != nil` is re-evaluated on every struct init.
- `BriefingViewModel.init`'s default argument calls `ProcessCLIRunner.makeDefault()` on each Briefings tab visit.
- Every account-VM action and every chat send pays it too.

Measured with a scratch binary against the installed 35 MB store copy: 2×SHA-256 took 1.0–1.6 s and the codesign check 0.45–0.83 s. That was on a heavily loaded machine (load avg ~147); expect roughly 0.2–0.4 s idle, still a visible hitch each time. It also churns ~70 MB of allocations per call. CLAUDE.md still claims the verdict is "cached per launch", so the docs drifted too. Fix direction: cache keyed on (inode, mtime, size) of the store file and re-verify only when it changes (keeps the TOCTOU property cheaply), or verify via `SecStaticCodeCheckValidity` alone and drop the redundant double SHA once the signature gate passes. Also move `hasCLI` out of `body`.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
