# Onboarding Flow — Watchtower Desktop

Onboarding v2 (2026-10): three steps, no LLM, nothing required.
**Goals → Connect → About you**, then straight into the app. There is no
"all done" screen. Contracts and the reasoning behind them are in
[`docs/features/onboarding-v2.md`](features/onboarding-v2.md).

## Where it lives

| Piece | File |
|---|---|
| Step state machine (persisted) | `WatchtowerDesktop/Sources/WatchtowerCore/Services/OnboardingStateMachineV2.swift` |
| Container view, step indicator | `WatchtowerDesktop/Sources/App/OnboardingV2View.swift` |
| Goals step | `Views/Onboarding/OnboardingGoalsStepView.swift` + `WatchtowerCore/Services/OnboardingGoalsModel.swift` |
| Customize features | `Views/Onboarding/FeatureCustomizeView.swift` + `WatchtowerCore/Services/OnboardingFeaturePlan.swift` |
| Assistant language picker | `Views/Components/AssistantLanguagePicker.swift` + `WatchtowerCore/Services/AssistantLanguage.swift` |
| Connect step | `Views/Onboarding/OnboardingConnectStepView.swift` + `WatchtowerCore/Services/OnboardingConnectPlan.swift` |
| People load (users-only sync) | `WatchtowerCore/Services/PeopleRosterLoad.swift` |
| About you step | `Views/Onboarding/OnboardingAboutYouStepView.swift` + `WatchtowerCore/Services/OnboardingAboutYouModel.swift` |
| Profile writes (OWNER-01) | `WatchtowerCore/Services/OnboardingProfileWriter.swift` |
| Finish: daemon, landing, first sync | `App/OnboardingCompletion.swift`, `WatchtowerCore/Services/OnboardingFinishPlan.swift`, `AppState.leaveOnboardingStep` |

Everything stateful lives in `AppState` (`onboarding`, `onboardingGoals`,
`onboardingAboutYou`, `peopleRoster`), so a step re-rendering, Back, or the
Customize screen never loses what was picked.

## Steps and the route

```
                 ┌────────────── launch ──────────────┐
                 │ DB says onboarding_done = 1?       │── yes ──▶ main window
                 └──────────────┬─────────────────────┘
                                │ no (or no DB yet)
                                ▼
 ┌──────────────────────────────────────────────────────────────────┐
 │ 1. GOALS (purpose)                                               │
 │  goals: Work communication · Tasks & Jira · Meetings ·           │
 │         Development in Workbench   (default: all but Meetings)   │
 │  "Customize features →"  · assistant language line · AI CLI check│
 │  Continue blocked until `watchtower ai test` passes              │
 │  Continue: workspace init (no Slack yet) → history depth (unset) │
 │            → digest.language (if changed) → features             │
 └───────────────┬──────────────────────────────────────────────────┘
                 │ route.step(after: .purpose)
                 ▼
 ┌──────────────────────────────────────────────────────────────────┐
 │ 2. CONNECT        skipped when the goals are Development only   │
 │  one card per source the goals need (Slack, Google, Jira)       │
 │  Add sheets in `.deferred` mode — no daemon restart             │
 │  a new Slack account → `sync --users-only` in the background    │
 │  Back · Continue always allowed                                 │
 └───────────────┬──────────────────────────────────────────────────┘
                 ▼
 ┌──────────────────────────────────────────────────────────────────┐
 │ 3. ABOUT YOU      skipped when no Slack account is connected    │
 │  role and team · manager · reports · peers (from synced users)  │
 │  Done → profile answers + onboarding_done · Later → flag only   │
 └───────────────┬──────────────────────────────────────────────────┘
                 ▼
            FINISH (the last step the route runs)
   onboarding_done written → daemon started (or restarted once) in
   the background → `.complete` → landing tab
```

`OnboardingRoute(goals:, hasSlackAccount:)` decides the skips. The goals it
reads are the ones saved by the last successful Goals Continue
(`onboarding_v2_goals`), never the live checkboxes, so the step dots do not
move while the owner is still picking. Zero goals behave like Development
only.

## Persistence and the legacy migration

- `onboarding_v2_step` (UserDefaults) holds the step as a string:
  `purpose`, `connect`, `aboutYou`, `complete`.
- On first use the machine reads the old flow's `onboarding_current_step`
  integer once: `7` (complete) → `complete`, anything else → `purpose`
  (someone mid-way through the old eight-step flow starts over). The legacy
  keys (`onboarding_current_step`, `onboarding_sync_completed`,
  `onboarding_chat_finished`) are then removed.
- Launch reconciliation (`AppState.reconcileOnboarding`): the database's
  `user_profile.onboarding_done` wins over a local step that is not
  complete, so a wiped defaults domain or a new Mac never re-runs it. An
  unreadable profile skips onboarding for that launch only (logged, not
  persisted). A resumed step the route now skips moves on; if nothing is
  left after it, it goes back to Goals rather than to `.complete`, because
  only a step's Continue runs the completion sequence.

## The workspace and the database

On a fresh install there is no workspace, so launch cannot open the
database. Goals' Continue runs `watchtower workspace init --json` once
(when no Slack account exists yet): it creates the workspace directory and
the migrated `watchtower.db` and records `active_workspace`, without any
Slack login. It is idempotent. A later Slack login reuses this workspace
instead of naming a new one after the team.

`AppState.openDatabaseForOnboarding()` then opens the database with only
what the steps need: owner, connected sources and the account view models
behind the Connect sheets. The rest of the app's database wiring (watchers
that ask for notification permission, reminders, polling, the chat pool)
waits for completion, so no system dialog appears during onboarding.

## People for About you

When a Slack account appears during onboarding (or one is already
connected after a relaunch), `PeopleRosterLoad` runs
`watchtower sync --users-only --progress-json --account <id>`: the team,
the current user and the full `users.list` roster, no messages, no AI, no
sync lock (it runs beside a daemon). The load survives leaving the step and
is stopped (SIGTERM) on quit. The Slack card shows "Loading people… N";
About you shows "Still loading people — N" and re-reads the users every
~2 s until it ends.

## Finish

`AppState.leaveOnboardingStep` from the last step the route runs:

1. `onboarding_done = 1` through `OnboardingProfileWriter` (`done` with the
   About you answers, `later` otherwise), inside one `pool.write`. A failed
   write stops here; the step stays and its button retries.
2. The daemon, in the background: started if none runs, restarted once if
   one does (a setup re-run with a new feature set). One
   `sync --daemon --detach`; its first cycle syncs and runs every enabled
   pipeline itself. `pipelines_completed` is set once it is up.
3. `.complete`, the rest of the app's database wiring, sidebar counts, the
   connected-sources refresh, and the landing tab: Catch-Up when the goals
   include Work communication and the Catch-Up tab shows, else Workbench
   for Development, else AI Chat.

Finish is the only place onboarding starts or restarts the daemon: the
Connect sheets run in `.deferred` mode, and nothing else in the flow touches
it.

## Run setup again

Settings → Profile → **Run Setup Again** (and the chat's profile button)
reads the current feature set and config first; a failure shows instead of
starting. The flow then starts at Goals seeded from what is in effect —
goals mapped back from the enabled features (or "Features customized"),
the configured language (English when none), About you prefilled from the
profile. **Cancel** (top right, every step) returns to the main window
without writing anything more. A re-run that changed nothing does not
restart the daemon and does not change the tab the owner was on.

## After onboarding

- **About you once after a later Slack connect** — the first Slack account
  connected from Settings (say after a Development-only setup) offers the
  About you step as a sheet in the Settings window, once ever, unless the
  profile already names people or onboarding's About you step was left.
- **Related features** — a source connected from Settings offers to turn on
  the features its goal would have enabled and that are off now; nothing is
  enabled without the owner's Turn on.
