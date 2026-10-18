# Onboarding v2 — Goals → Connect (2026-10-03; About you removed 2026-10-14)

Board: #276 and its subtargets (#279–#299). The eight-step onboarding
(Slack OAuth → Settings → Claude check → role questionnaire + AI interview →
team form → LLM profile → feature splash) is gone: two steps, no LLM,
no source required. The third step, About you (role, manager, reports,
peers), was removed on 2026-10-14 (owner decision, #758). Step-by-step walkthrough: [`docs/onboarding-flow.md`](../onboarding-flow.md).
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
  onboarding keeps it off. An install onboarded before this change has
  Work communication's features on and Memory off, a set no goal
  combination reproduces: its Run setup again reads "Features customized"
  and Continue keeps Memory off — there is no telling it from Memory
  switched off in Settings — and Reset to goals turns it on.
- Tasks & Jira → `stream-digests`, `next-step`.
- Meetings → `briefing` (meeting prep rides the daily briefing).
  It is also the only goal that downloads the transcription model ahead of
  use, after the first sync (#744, `TranscriptionModelAutoDownload`); every
  other route downloads it at the first recording or dictation.
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
  `knowledge-connectors` (Confluence in search), `automations` (on by
  default, runs nothing until the owner confirms a recipe) and the core
  entries.
  `OnboardingFeaturePlanTests` parses `internal/features/registry.go` and
  fails on a toggleable feature that is in none of these sets.
- Default goals: all four (owner decision 2026-10-14, #756 — Meetings was
  off before). Zero goals = Development only.
- Calendar and Gmail sync default on (`calendar.enabled`/`gmail.enabled`
  are `true` in Go's defaults and Swift's `ConfigService` fallbacks, owner
  decision 2026-10-14, #757): a Google account connected with the calendar
  or mail ticked syncs it without a config edit; the per-account
  `google_accounts` flags still decide which accounts sync what. The `true`
  default applies only where the key is absent (a new install, or a config
  Settings never saved); an install whose Desktop already saved
  `enabled: false` keeps it until a Google connect turns the granted
  service's switch on (`recordGoogleConnection`, #740).
- `OnboardingFeatureSelection` follows the goals until a switch is flipped
  on the Customize screen (`FeatureCustomizeView`), then stays frozen until
  "Reset to goals". It is applied by `FeatureManagerService.applySelection`
  (only real changes are written; no daemon restart).
- The Customize screen tags a feature "Experimental" when it is off at the
  screen's first load (on a fresh install: ships off by default), except
  Memory — `OnboardingFeaturePlan.establishedDefaultOffFeatureIDs` (#378).

**Connect step cards** (`OnboardingConnectPlan`, WatchtowerCore). Slack for
Work communication, one Google card for Work communication or Meetings,
Jira for Tasks & Jira. The Jira sheet (`AddJiraAccountView`, shared with
Settings) turns into a board step after a successful connect (#572):
`JiraBoardChoiceView` fetches the boards of the site the connect added
(every enabled site when it added none, `JiraBoardPicker.sites`) with `jira
--account N boards`, lists them with the current selection ticked (grouped
by site when there are several; "Couldn't load boards" with Try Again when a
fetch failed), and Done writes only the changes (`JiraBoardPicker.invocations`
→ `jira boards select|deselect`). The connect's daemon restart is held while
the step is up (`JiraAccountsViewModel.addAccountHoldingRestart`) and applied
once when the sheet closes — Done, Skip or otherwise — by `finishBoardStep`:
one restart under `.restart`, none under onboarding's `.deferred` (the daemon
starts at the finish). A sheet that closes while `jira add` is still in the
browser marks the step closed, and the connect then applies its policy itself
when it succeeds (reset at each connect). No foreground sync: the daemon path syncs and starts
the backfill. Skip leaves
Jira with no board, which readiness reports as `needsSource(.jiraBoards)`
(first-run.md). Nothing is preselected. **Confluence at connect (#573):** the
form's **Also connect Confluence** checkbox (on by default) adds
`--with-confluence` to `jira add` (`JiraAccountsViewModel.addArgs`), so one
consent covers both. With it, the board step also runs `confluence --account
N select --recent` once for each site the connect added
(`ConfluenceConnectStep.addedSites` — no every-site fallback when the
before-read failed) and shows one caption line naming the selected spaces,
"no space …", or the failure (`ConfluenceConnectStep.summary`), each
pointing at Settings → Connections → Jira. It is a line, not a step: Done and
Skip do not wait for it. The daemon picks the new `ext_sources` rows up on
its next cycle. A failed connect with the box on adds a hint to untick it
(an Atlassian app without the Confluence API refuses the wider scopes). The Google card carries no scopes: connecting a
Google account means mail and calendar both, whatever the goals (owner
decision 2026-10-14, #740), so its sheet opens with Calendar and Gmail
checked like Settings' Add Google sheet, and either can be unchecked there.
A calendar granted this way makes the Calendar tab show (the source rule
below; Calendar has no feature rule) and turns `calendar.enabled` on
(`recordGoogleConnection`), with or without the Meetings goal; the goal
still decides only the `briefing` feature.

**Sidebar visibility.** A tab shows when its feature rule AND its source
rule hold (`SidebarDestination.isVisible`, `ConnectedSources`): Calendar
needs a calendar; Boards, Workload, Blockers, Project Map and Releases need
Jira; Statistics needs Slack or mail; Inbox and Catch-Up need any source
(Slack, mail, Jira or a calendar). Inbox has no feature rule; Catch-Up needs
`secretary-inbox`, `slack-digests` or `stream-digests` on (owner decision
2026-10-03, #284). A selection that lands on a hidden tab falls back to
Home, which has no gate (first-run P2, `docs/features/first-run.md`). The quiet "+ Connect Slack, Mail, Jira…"
row at the bottom of the menu names the kinds still missing (Mail = any
Google, IMAP or CalDAV/ICS source), opens Settings → Connections, and hides
for good with its × (`sidebar_connect_row_dismissed`).

**Profile writes are OWNER-01's** (`OnboardingProfileWriter`,
docs/inventory/owner-identity.md). Finishing onboarding writes
`onboarding_done = 1` alone (`OnboardingProfileWriter.later`) inside one
`pool.write`, never touching `custom_prompt_context` or any other column. A
known owner writes through `upsertOwnerProfile`; with no owner the write
parks under the no-owner key the first owner adopts. The writer keeps
`done(_:about:)` (role, manager, reports, peers plus the flag) and the
`OnboardingAboutYou` answers struct although no screen calls them since
About you went: the six onboarding OWNER-01 guards write through them.

**One daemon start.** The Connect sheets run in `DaemonRestartPolicy.deferred`.
Finish writes `onboarding_done` first, then brings the daemon up in the
background (`OnboardingFinishPlan.bringUpDaemon`: start if none runs, else
restart once), so Continue never waits on a slow restart. No one-shot
`digest`/`tracks`/`people generate` runs: the daemon's first cycle does
it; launch just ensures a daemon runs. The daemon syncs calendars once
before that first cycle, so a calendar connected here shows events within
about a minute instead of after the first Slack sync (#740). A daemon that fails to come up
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

**People load.** A Slack account connected during onboarding (or one
already there on a relaunch mid-onboarding) starts `watchtower sync --users-only --progress-json
--account <id>` (`PeopleRosterLoad`, held by `AppState`): roster only, no
sync lock, survives leaving the step, SIGTERM on quit. While paging the CLI
reports no total, so the line is "Loading people… N"; while saving it is
"N of M".

**Legacy step migration.** `onboarding_v2_step` holds the step by name. On
first use the old `onboarding_current_step` integer is read once (`7` →
complete, anything else → Goals) and the legacy keys are dropped. The DB's
`onboarding_done` wins over a local step at launch; an unreadable profile
skips onboarding for that launch only. A stored `aboutYou` (someone parked
on the removed step when they upgraded) resumes at Connect, whose Continue
finishes; when the saved goals are Development only, Connect is skipped and
launch goes back to Goals as for any skipped step with nothing after it.

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
That 3 days is only the first cycle's depth: new sources are then backfilled to `sync.backfill_days` (30) in the background, see [history-backfill.md](history-backfill.md).

**Run setup again.** Seeded from what is in effect: goals mapped back from
the enabled features (`OnboardingFeatureSelection.current`, closest to the
saved goals; a hand-toggled set shows as "Features customized"), the
configured language (English when absent). A failed feature-list or config read shows its error instead of starting.
Cancel returns to the main window on every step. A re-run that changed
nothing (no language, history or feature write, no account added or
removed) leaves a running daemon alone and keeps the owner's tab; one that
changed something restarts it once, Cancel included.

**Related features after a connect.** A source kind newly connected outside
onboarding (Slack or mail → Work communication, a calendar → Meetings,
Jira → Tasks & Jira) offers the features those goals turn on and that are
off now. Nothing is enabled without Turn on, which enables them through
`FeatureManagerService.enableNow([ids])` (never Settings → Features'
staged changes) and restarts the daemon once; a retry after a failed
restart only restarts. The offer is a sheet in the Settings window, shown
once no Add account sheet is up, and closes only through its own buttons.

**Finish landing.** Home, for every goal set (first-run P2,
`AppState.landOnHome`). Re-runs keep the current tab. During the very first
sync (a sync running, none finished yet) Catch-Up's empty state and Home's
Getting ready both show `AppState.firstSyncLine`: "Syncing Slack for the
last N days — usually 3–5 min" (wording follows the connected sources) with
the sync heartbeat line.

## What went away

The AI interview and role questionnaire (`OnboardingChatViewModel`, its
chat), the team form, the LLM profile generation, the Settings step, the
feature splash, `OnboardingSettingsPlan`, `OnboardingSyncETA`, the
post-onboarding pipeline burst (`BackgroundTaskManager`) and its sidebar
progress, the legacy `OnboardingStateMachine`.

About you (2026-10-14, #758 — the owner: picking managers and reports is not
needed): the step (`OnboardingAboutYouStepView`, `OnboardingAboutYouModel`,
`AppState.onboardingAboutYou`), `OnboardingRoute.hasSlackAccount` (it only
existed to skip the step), the one-time About you sheet after the first
Slack account connected outside onboarding (`LateAboutYouSheet`, the
`about_you_after_slack_shown` key, `SettingsSheet`) and
`OwnerQueries.ownSlackUserIDs` (its pickers left the owner out). A Slack
account connected from Settings no longer starts a people load.

All six onboarding OWNER-01 guards run against `OnboardingProfileWriter` in
`Tests/Core/OnboardingProfileWriterOwnerTests.swift`; the three that checked
the LLM-written context now check the About-you answers the writer writes in
the same row (owner-approved variant A, 2026-10-03). They stay unchanged
after About you's removal.
