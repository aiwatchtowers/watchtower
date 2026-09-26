# Onboarding Feature Splash — Design

**Date:** 2026-08-16
**Status:** Approved by owner (this session)
**Owner request:** after onboarding, show a selling splash screen where the new user picks which features to enable/disable, with descriptions — built on the Feature Manager (PR #114).

## Owner decisions

1. **Audience:** new users only, as the final onboarding step. Existing installs never see it (they have Settings → Features). No what's-new mechanism.
2. **Defaults:** everything arrives ON (the app's shipped defaults; memory stays off/experimental). The user unchecks what they don't want. "Keep everything" is a zero-friction exit.
3. **Copy lives in the Go registry:** `Feature` gains selling attributes (tagline, benefits, icon) that ride `features list --json` — one source of truth; a future feature added to the registry automatically appears on the splash and in Settings.
4. **Approach A:** a new `OnboardingStep` case rendered inside the onboarding shell, between profile generation and completion.

## Registry extension (Go)

`internal/features/registry.go` — `Feature` gains:

```go
Tagline  string   // one benefit-first phrase, e.g. "Your team's pulse, distilled"
Benefits []string // 2–3 short benefit bullets, user language, no jargon
Icon     string   // SF Symbol name rendered by the Desktop card
```

Every entry — including the four core ones — gets real values (core entries are shown on the splash as "Always included", which is part of the sell). Sub-toggles do NOT get selling copy (they never appear on the splash; memory's Advanced disclosure stays a Settings-only affordance).

`cmd/features.go`'s `featureJSON` gains `tagline`, `benefits`, `icon` (benefits as a JSON array, `[]` never `null` — the existing convention). `TestRegistry_Valid` extends: non-empty `Tagline`/`Icon` and 2–3 `Benefits` for every entry; the wire-shape test extends to the new fields.

Copy tone: English, benefit-first, concrete, no exclamation marks, no em-dash-free marketing sludge — e.g. secretary-inbox: tagline "Never lose a thread again", benefits "Every mention, DM and reply triaged for you" / "Related messages clustered into one situation" / "A secretary card tells you why it matters".

## Onboarding step (Swift)

`OnboardingStateMachine.OnboardingStep` gains `.features` between `.generating` and `.complete` (`.features = 6`, `.complete` shifts 6→7).

- **Persisted-rawValue migration note:** `onboarding_current_step` stores the raw Int. A mid-onboarding install that stored `6` (`.complete` in the old numbering) decodes as `.features` after the update — harmless: on every launch `AppState` reconciles with the DB flag (`user_profile.onboarding_done`); done → `markComplete()`. Completed installs are unaffected (their UserDefaults keys were removed at completion). No migration code needed; a comment at the enum records this.
- `indicatorSteps` unchanged (the splash shares the "Setup" label group like `.teamForm`/`.generating` — the dots don't grow).
- **Flow rewiring** (`OnboardingView`'s teamForm completion closure): on `generatePromptContext()` success go to `.features` instead of finishing. `markOnboardingDone()` + `startPipelines` + `completeOnboarding()` + `onRetry()` move into the splash's exit path, so quitting at the splash resumes at the splash (state machine) and the DB flag stays honest (onboarding isn't done until the splash is passed). The generation-failure bounce back to `.teamForm` is unchanged.

## The splash screen (Swift)

`Sources/Views/Onboarding/FeatureSplashView.swift`, rendered by `OnboardingView`'s switch for `.features`. Reuses `appState.featureManager` (`FeatureManagerService`) directly — no new service, no new state store; run `load()` on appear (it is already loaded at app launch; re-load is cheap and covers the onboarding-before-first-load path).

Layout (the privacy-GroupBox house pattern scaled up):

- **Hero:** banner + headline ("Watchtower works for you around the clock.") + subline ("Pick what it should do. Everything runs on your Mac; change any of this later in Settings → Features.").
- **"Always included" row:** the four core features as compact pills/cards (icon + title + tagline), no toggles — the free-core part of the sell.
- **Feature cards grid:** one card per top-level toggleable feature (parent == ""), child (stream-digests) folded INTO its parent's card as a secondary line with its own small toggle. Card = SF Symbol icon, title, tagline (semibold), benefit bullets (caption), cost badge mapped to plain words ("Uses AI heavily" / "moderately" / "lightly"), and a Toggle staged via `setPending`. `feedsInto` renders as a "Powers: Ideas, Briefing" caption (names resolved via the loaded list) — the soft dependency sell; no cascade dialogs on the splash (nothing is ever disabled implicitly: unchecking X leaves dependents on and degraded, FEAT-04 untouched).
- **Memory card:** rendered like the rest but arriving OFF with an "Experimental" tag — honest, still selling.
- **Footer:** primary button "Continue" (applies staged changes via `apply(restart:)` — one daemon restart only when something changed) and secondary "Keep everything on" (clears pending, applies nothing). Both exits then run the moved completion sequence (markOnboardingDone → startPipelines → completeOnboarding → onRetry). `loadError`/apply failure shows inline above the footer with Retry; "Keep everything on" always works even when `load()` failed (a broken CLI must not trap the user in onboarding — completion does not depend on the feature list).
- `.disabled(isApplying)` on the footer during apply; the whole screen scrolls (fixed onboarding window size).

## Error handling

- `load()` failure: cards area shows the error + Retry; the "Keep everything on" exit stays available (defaults already correct on disk).
- `apply()` partial failure: the service's existing semantics (failed+unattempted stay pending, loadError set, restart fired if something landed). The splash shows the error and stays; a second Continue retries the remainder. The user can always exit via "Keep everything on" — remaining staged changes are discarded (`pending` cleared), config stays as-is; Settings → Features is the follow-up surface.

## Testing

- Go: `TestRegistry_Valid` extension (tagline/icon non-empty, 2–3 benefits, all 14 entries); `list --json` wire-shape test extension (tagline/benefits/icon, `[]` not `null`).
- Swift: decode test for the new `FeatureInfo` fields (fixture JSON); `OnboardingStateMachineTests` (if absent, add) — transition `.generating → .features → .complete`, resume at `.features`, the rawValue-migration reconciliation note asserted where reachable; splash exit-path logic extracted into a small testable helper if it grows beyond a closure (completion sequence order pinned: markOnboardingDone before completeOnboarding). View layer build-verified per house rule.
- Inventory: no new contracts; FEAT-01..04 untouched (the splash is a consumer of the existing CLI/service semantics).

## Non-goals

- No what's-new/update splash for existing installs.
- No presets (Full/Essentials).
- No sub-toggle editing on the splash (memory Advanced stays in Settings).
- No cascade dialogs on the splash.
- No localization (English UI, as everywhere).
