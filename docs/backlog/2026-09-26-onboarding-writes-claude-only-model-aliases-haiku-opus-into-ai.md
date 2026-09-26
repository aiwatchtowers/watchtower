---
type: bug
title: "Onboarding writes Claude-only model aliases (\"haiku\"/\"opus\") into ai.models.strong regardless of the configured provider"
status: open
priority: med
tags: [swift, onboarding, model-registry, no-hardcoded-models, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Swift Desktop)
created: 2026-09-26
---

**Where:** WatchtowerDesktop/Sources/App/OnboardingView.swift:586-621 (ModelPreset.strongModelOverride), :1270-1272
**Confidence:** high

The Fast/Quality presets hard-code the claude CLI aliases `haiku`/`opus` and write them with `config set ai.models.strong`, without reading `ai.provider`. Config overrides are scoped to the configured provider (`AIConfig.ConfiguredProvider`). Scenario: an owner on `codex` or `ollama` re-runs onboarding from Settings and picks "Fast". `ai.models.strong=haiku` is sent to codex/ollama, and every strong-tier call then fails with an unknown model. This also breaks the "No model names are hardcoded in Swift" rule in CLAUDE.md, and the step's copy ("Claude is ready with … model") assumes claude. Fix: source the choices from `AIModelCatalog` (the registry's per-provider defaults/aliases), or skip the override when the provider is not `claude`.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
