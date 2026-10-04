# Onboarding v2 — Goals → Connect → About you (2026-10-03)

Board: #276 and its subtargets (#279–#299). The eight-step onboarding
(Slack OAuth → Settings → Claude check → role questionnaire + AI interview →
team form → LLM profile → feature splash) is gone: three steps, no LLM,
no source required. Step-by-step walkthrough: [`docs/onboarding-flow.md`](../onboarding-flow.md).
UI text is English only.

## Contracts

**Goal → feature mapping** (`OnboardingFeaturePlan`, WatchtowerCore). The
goals are `workCommunication`, `tasksAndJira`, `meetings`, `development`.
- Work communication → `slack-digests`, `tracks`, `people-cards`,
  `briefing`, `day-plan`, `ideas`, `reaction-commands`, `memory`. Memory
  rides this goal (owner decision 2026-10-04, #375 — it is a headline
  feature, not one to leave off by default): its core pipeline extracts
  episodes from Slack messages, so it has material exactly when this goal
  does; its other sources (Gmail, calendar, Jira, chats, Targets/Tracks)
  are sub-switches onboarding does not touch. The config default
  (`memory.enabled: false`) is unchanged, so an install that never ran
  onboarding keeps it off.
- Tasks & Jira → `stream-digests`, `next-step`.
- Meetings → `briefing` (meeting prep rides the daily briefing).
- Development → nothing (Workbench, the chat, Targets and Knowledge search
  need no switch).
- Always on: `knowledge-search`, `secretary-inbox` (Attention detection,
  owner decision 2026-10-03, #283 — mechanical, and Inbox/Catch-Up lean on
  it). Onboarding never disables an always-on feature: the Customize
  screen lists them in its "Always on" row, and one the owner turned off
  in Settings shows under "Off (as in Settings)" on a re-run and stays
  off, Reset to goals included; on its own it does not make the re-run
  "Features customized". Settings → Features keeps them as normal toggles, and the
  related-features offer after a connect never proposes them. Left alone:
  `knowledge-connectors` (Confluence in search) and the core entries.
  `OnboardingFeaturePlanTests` parses `internal/features/registry.go` and
  fails on a toggleable feature that is in none of these sets.
- Default goals: all but Meetings. Zero goals = Development only.
- `OnboardingFeatureSelection` follows the goals until a switch is flipped
  on the Customize screen (`FeatureCustomizeView`), then stays frozen until
  "Reset to goals". It is applied by `FeatureManagerService.applySelection`
  (only real changes are written; no daemon restart).

**Sidebar visibility.** A tab shows when its feature rule AND its source
rule hold (`SidebarDestination.isVisible`, `ConnectedSources`): Calendar
needs a calendar; Boards, Workload, Blockers, Project Map and Releases need
Jira; Statistics needs Slack or mail; Inbox and Catch-Up need any source
(Slack, mail, Jira or a calendar). Inbox has no feature rule; Catch-Up needs
`secretary-inbox`, `slack-digests` or `stream-digests` on (owner decision
2026-10-03, #284). A Jira- or calendar-only install that lands on a hidden
tab therefore falls back to Inbox. The quiet "+ Connect Slack, Mail, Jira…"
row at the bottom of the menu names the kinds still missing (Mail = any
Google, IMAP or CalDAV/ICS source), opens Settings → Connections, and hides
for good with its × (`sidebar_connect_row_dismissed`).

**Profile writes are OWNER-01's** (`OnboardingProfileWriter`,
docs/inventory/owner-identity.md). About you's Done writes role, manager,
reports and peers plus `onboarding_done = 1`; Later writes the flag alone;
both inside one `pool.write`, never touching `custom_prompt_context`. A
known owner writes through `upsertOwnerProfile`; with no owner the write
parks under the no-owner key the first owner adopts. Done overwrites the
people fields with exactly what the form holds, so the form always
prefills from the row the writer will write (`OnboardingProfileWriter.current`)
and Done stays off until that prefill succeeded. The pickers leave out
bots, deleted users, Slackbot and the owner's own user in every Slack
workspace (`OwnerQueries.ownSlackUserIDs`, the scan-exempt file).

**One daemon start.** The Connect sheets run in `DaemonRestartPolicy.deferred`.
Finish writes `onboarding_done` first, then brings the daemon up in the
background (`OnboardingFinishPlan.bringUpDaemon`: start if none runs, else
restart once), so Continue never waits on a slow restart. No one-shot
`digest`/`tracks`/`people generate` runs: the daemon's first cycle does
it; launch just ensures a daemon runs. A daemon that fails to come up
shows a banner over the tab setup landed on.

**Workspace without Slack.** Goals' Continue runs `watchtower workspace init
--json` (at most once per app session, only while no Slack account exists):
directory, migrated database and `active_workspace`, idempotent. A later
Slack login reuses that workspace; `auth login` into a second team while
account #1 is live is refused with a pointer to `slack add` (#279).
`AppState.openDatabaseForOnboarding` then wires only what the steps need
(owner, connected sources, account view models); the rest of the app's DB
wiring, including the notification-permission request, runs once at
completion.

**People load.** A newly connected Slack account (or one already there on a
relaunch mid-onboarding) starts `watchtower sync --users-only --progress-json
--account <id>` (`PeopleRosterLoad`, held by `AppState`): roster only, no
sync lock, survives leaving the step, SIGTERM on quit. While paging the CLI
reports no total, so the line is "Loading people… N"; while saving it is
"N of M".

**Legacy step migration.** `onboarding_v2_step` holds the step by name. On
first use the old `onboarding_current_step` integer is read once (`7` →
complete, anything else → Goals) and the legacy keys are dropped. The DB's
`onboarding_done` wins over a local step at launch; an unreadable profile
skips onboarding for that launch only.

**Assistant language.** One setting, `digest.language`, an English language
name. A fresh install starts from the first macOS preferred language
(Traditional Chinese and Latin Serbian are kept apart). The chat,
`watchtower ask` and the REPL answer in the language the owner writes in
(`prompts.ChatDirective`, #281); background pipelines keep the strict
`prompts.Directive`. Settings → General holds the picker.
`transcription.langset` is seeded once from the Mac's languages (mapped to
Whisper codes, English always included) while the key is absent on a launch
that lands in onboarding. Goals' Continue writes `sync.initial_history_days
= 3` (the old onboarding's default) when the config had none.

**Run setup again.** Seeded from what is in effect: goals mapped back from
the enabled features (`OnboardingFeatureSelection.current`, closest to the
saved goals; a hand-toggled set shows as "Features customized"), the
configured language (English when absent), About you from the profile. A
failed feature-list or config read shows its error instead of starting.
Cancel returns to the main window on every step. A re-run that changed
nothing (no language, history or feature write, no account added or
removed) leaves a running daemon alone and keeps the owner's tab; one that
changed something restarts it once, Cancel included.

**About you after a later Slack connect.** The first Slack account
connected outside onboarding (no active one before) offers About you once,
ever (`about_you_after_slack_shown`, set when the sheet appears or when
onboarding's About you step is left), and only while the profile names no
manager, reports or peers. It is a sheet in the Settings window, shown once
the Add sheet has gone. Done writes the profile only; Later just closes;
neither touches the daemon or the onboarding state.

**Related features after a connect.** A source kind newly connected outside
onboarding (Slack or mail → Work communication, a calendar → Meetings,
Jira → Tasks & Jira) offers the features those goals turn on and that are
off now. Nothing is enabled without Turn on, which enables them through
`FeatureManagerService.enableNow([ids])` (never Settings → Features'
staged changes) and restarts the daemon once; a retry after a failed
restart only restarts. The offer shares the Settings sheet slot with About
you and always queues behind it.

**Finish landing.** Catch-Up when the goals include Work communication and
its tab shows, else Workbench for Development, else AI Chat. Re-runs keep
the current tab. Catch-Up's empty state during the very first sync (a sync
running, none finished yet) reads "Syncing Slack for the last N days —
usually 3–5 min" (wording follows the connected sources) with the sync
heartbeat line.

## What went away

The AI interview and role questionnaire (`OnboardingChatViewModel`, its
chat), the team form, the LLM profile generation, the Settings step, the
feature splash, `OnboardingSettingsPlan`, `OnboardingSyncETA`, the
post-onboarding pipeline burst (`BackgroundTaskManager`) and its sidebar
progress, the legacy `OnboardingStateMachine`. All six onboarding OWNER-01
guards run against `OnboardingProfileWriter` in
`Tests/Core/OnboardingProfileWriterOwnerTests.swift`; the three that checked
the LLM-written context now check the About-you answers the writer writes in
the same row (owner-approved variant A, 2026-10-03).
