# Onboarding Feature Splash Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A selling feature-selection splash as the final onboarding step, per `docs/superpowers/specs/2026-08-16-onboarding-feature-splash-design.md` (read it first — it is binding).

**Architecture:** Go registry gains selling attributes (tagline/benefits/icon) riding `features list --json`; Swift adds an `.features` onboarding step rendering `FeatureSplashView` off the existing `FeatureManagerService`; the onboarding completion sequence moves into the splash's exit path.

**Tech Stack:** Go (internal/features, cmd), SwiftUI (WatchtowerDesktop).

## Global Constraints

- Worktree `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/feature-splash`, branch `feature/onboarding-feature-splash`. Never touch other checkouts.
- English everywhere; commit per task with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Inner loop: `go test ./internal/features ./cmd`; Swift filtered `swift test --filter <Class>`; never delete `.build`; gofmt/golangci-lint clean per task.
- FEAT-01..04 contracts untouched (`docs/inventory/features.md`); no cascade dialogs on the splash; completion must never depend on a working feature list ("Keep everything on" always exits).
- Copy tone per spec: benefit-first, concrete, no exclamation marks.

---

### Task 1: Registry selling attributes (Go)

**Files:** Modify `internal/features/registry.go`, `internal/features/registry_test.go`, `cmd/features.go`, `cmd/features_test.go`.

**Interfaces (Produces):** `Feature.Tagline string`, `Feature.Benefits []string`, `Feature.Icon string`; JSON fields `tagline`, `benefits` (array, `[]` never `null`), `icon` in `features list --json`.

- [ ] **Step 1: Failing tests** — extend `TestRegistry_Valid`: every entry (all 14, core included) has non-empty `Tagline`, non-empty `Icon`, and 2–3 `Benefits`, each non-empty. Extend the `list --json` shape test (`TestFeaturesList_JSONShape`): decoded entry exposes `tagline`/`icon` strings and `benefits` as an array; assert a leaf entry marshals `benefits` as `[]`-compatible (non-null) — follow the existing `feeds_into` convention/test shape.
- [ ] **Step 2:** `go test ./internal/features ./cmd -run 'TestRegistry_Valid|TestFeaturesList_JSONShape'` → FAIL.
- [ ] **Step 3:** Implement: add the three fields to `Feature`; write real copy for all 14 entries (spec's tone; the secretary-inbox example in the spec is the calibration sample; icons = sensible SF Symbols — reuse the sidebar's icon names from `SidebarDestination.icon` where a feature maps to a tab: inbox=tray, ideas=lightbulb, memory=archivebox, briefings=sun.max, dayPlan=calendar.day.timeline.left, tracks=binoculars, people=person.2, digests=doc.text.magnifyingglass, targets=scope, chat=bubble.left.and.bubble.right; invent for the rest: slack-digests=doc.text.magnifyingglass, stream-digests=envelope.badge, next-step=arrow.turn.down.right or similar, feed=rectangle.grid.1x2, dashboard=tray).
  In `cmd/features.go`'s `featureJSON` add the three fields with the `append([]string{}, ...)` empty-array idiom for benefits.
- [ ] **Step 4:** Tests PASS; `go build ./...`; gofmt/golangci clean.
- [ ] **Step 5: Commit** `feat(features): selling attributes (tagline, benefits, icon) on the registry`

### Task 2: Swift decode of the new fields

**Files:** Modify `WatchtowerDesktop/Sources/Services/FeatureManagerService.swift` (FeatureInfo), `WatchtowerDesktop/Tests/FeatureManagerServiceTests.swift`.

**Interfaces (Produces):** `FeatureInfo.tagline: String`, `.benefits: [String]`, `.icon: String` (CodingKeys as-is, all snake-case free names — `tagline`/`benefits`/`icon` are single words).

- [ ] **Step 1:** Failing decode test: extend the canned list JSON fixture with the three fields; assert decode.
- [ ] **Step 2:** `swift test --filter FeatureManagerServiceTests` RED → implement → GREEN. Existing fixtures without the fields must fail decode ONLY if fields are non-optional — decide: make them non-optional and update all fixtures (preferred; the Go side always emits them).
- [ ] **Step 3: Commit** `feat(desktop): decode selling attributes from features list`

### Task 3: Onboarding step + flow rewiring

**Files:** Modify `WatchtowerDesktop/Sources/App/OnboardingStateMachine.swift`, `WatchtowerDesktop/Sources/App/OnboardingView.swift`; Test `WatchtowerDesktop/Tests/` (find the existing OnboardingStateMachine tests; create `OnboardingStateMachineTests.swift` in the non-ML test target if none).

**Interfaces (Produces):** `OnboardingStep.features` (raw 6; `.complete` becomes 7) with the persisted-rawValue migration comment from the spec; `OnboardingView` renders `FeatureSplashView` (Task 4 file — for THIS task render a placeholder `FeatureSplashView(onFinish:)` stub if Task 4 hasn't landed; tasks 3+4 may be one implementer in sequence) for `.features`.

- [ ] **Step 1:** Failing tests: step sequence `.generating` advances to `.features` not `.complete`; resume: machine restored with stored raw 6 reports `.features`; `markComplete()` still clears keys; `indicatorSteps` unchanged (still the same 4 dots, `.features` maps to the "Setup" label like `.generating` — check `stepLabel`/indicator mapping and pin it).
- [ ] **Step 2:** RED → implement enum case + transitions + comment → GREEN.
- [ ] **Step 3:** Rewire `OnboardingView`'s teamForm completion closure per spec: success → `goTo(.features)`; move `markOnboardingDone` + `startPipelines` + `completeOnboarding` + `onRetry` into a single `finishOnboarding()` helper the splash exit calls (order pinned by a test where extractable — put the sequence in a small testable coordinator function if OnboardingView's closure shape allows; otherwise document build-verified).
- [ ] **Step 4:** `swift test --filter OnboardingStateMachineTests`; `swift build`.
- [ ] **Step 5: Commit** `feat(desktop): features onboarding step with completion moved to the splash exit`

### Task 4: FeatureSplashView

**Files:** Create `WatchtowerDesktop/Sources/Views/Onboarding/FeatureSplashView.swift`; modify `OnboardingView.swift` (replace the Task-3 stub render).

Layout per spec (hero / Always-included pills / feature cards grid with icon+tagline+benefits+cost words+toggle, child stream-digests folded into slack-digests card / memory Experimental tag / footer Continue + "Keep everything on" / inline error + Retry). All state on `appState.featureManager` (`load()` on appear, `setPending`, `apply(restart: { await DaemonManager.restart() })` — grep the exact restart call in FeatureManagerSection and reuse). Cost words: heavy="Uses AI heavily", medium="Uses AI moderately", light="Uses AI lightly", none omitted. "Powers:" caption from feedsInto resolved to titles. "Keep everything on": clear pending (`service.pending.removeAll()` or equivalent public API — check; if none, add a `discardPending()` method with a one-line test in Task 2's file), then finish. Continue with zero pending = no apply call, straight finish. `.disabled(service.isApplying)` on footer; ScrollView.

- [ ] **Step 1:** Implement view; `swift build` clean; `swift test --filter "FeatureManagerServiceTests|SidebarSectionTests"` still green.
- [ ] **Step 2: Commit** `feat(desktop): selling feature splash as the final onboarding step`

### Task 5: Gate + review + PR + merge

- [ ] Full gate: `go test ./...`, `cd WatchtowerDesktop && swift test` (known pre-existing flake: MeetingRecorderCenterTests.testLiveChunksAccumulateAndSurviveViewLifetime — green in isolation = acceptable), `make lint-all`.
- [ ] debate-review full panel on the branch diff; fix wave; verify round.
- [ ] Push (gh account vadimtrunov), ONE PR to main, CI green (dedupe-gate "skipping" on the push run is normal; the pull_request run must be green), merge with a merge commit (owner pre-approved), confirm main CI.

## Self-review notes

- Spec coverage: registry fields (T1), decode (T2), step+flow (T3), view (T4), gate/PR (T5). Non-goals honored (no presets, no sub-toggles, no what's-new).
- Persisted-rawValue migration is comment+reconciliation, no code — per spec.
- Tasks 3 and 4 touch OnboardingView.swift both — run them as ONE implementer sequentially or strictly serialized.
