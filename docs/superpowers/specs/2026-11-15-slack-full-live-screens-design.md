# Slack Full and Live — the screens

**Date:** 2026-11-15 · **Board:** target #1779 (group #1709, the UI part of #1763) · **Status:** draft for review
**Parent spec:** `docs/superpowers/specs/2026-11-14-slack-full-and-live-design.md` (decisions D1–D15, "Out of scope" promises this spec). **Feature note:** `docs/features/slack-live.md`.

## Goal

Every Slack state the parent spec introduces has a screen that says what is true and offers the one thing to do next:

1. The mode on Connections → Slack: **Full**, **Full · Live on**, **Live**, **Off**, the Live check's age ("checked 5 h ago") with **Check again**, and the check's failures.
2. `needsFullSlack` ("needs your workspace's app") on every Slack-dependent screen, and on the phone.
3. **Set up for my company** (D9): the configuration-token paste, progress, success, errors.
4. Entry into Full for everyone else: the app's About page, the connect confirm, the browser wait, approval, port 18551 busy, the connect-code paste, and **Add the link to the app**.
5. The banner for the retired shared app (D11).
6. The disabled **Add to Knowledge** on a Live artifact (shipped in plan A; documented here, not changed).

No production code changes with this spec. The mockups are design-only SwiftUI scenes in the DesignShots test target.

## Context (recon, 2026-11-15)

- **Shipped (plan A, PR #862):** `SlackMode.derive(full:liveStatuses:)` (`WatchtowerCore/Services/Slack/SlackMode.swift`, SLACKMODE-01); `SlackLiveStatusCenter` (`WatchtowerCore/Services/Slack/SlackLiveStatusCenter.swift`: `statuses`, `lastError`, `isRunning`, `refreshIfStale()`, `checkAgain()`, `reload()`), created by `AppState.initSlackLive`; Connections → Slack calls only `refreshIfStale()` on appear — `statuses`, `lastError` and `checkAgain()` have no screen yet. `ArtifactPanelModel.liveSlackReason` and `knowledgeKeepBlocked` disable **Add to Knowledge** with the reason as hover help.
- **Connections → Slack today** is `SlackConnectionDetail` (`Views/Settings/SlackConnectionDetail.swift`): a legacy `Form` with Workspace (connect/reconnect/disconnect), Slack Workspaces (`SlackAccountsViewModel`) and the reaction dictionary. In-flight connects live on `AppState.slackAuthFlow` so they survive navigation (`docs/features/connections-tab.md`).
- **Readiness:** `FeatureReadiness.evaluate` (`WatchtowerCore/Services/FeatureReadiness.swift`) over `ReadinessFeature`/`ReadinessSource` (`WatchtowerCore/Models/Readiness.swift`); `FeatureEmptyState` draws the line and the one button; Home's Getting ready zone shows the same line per feature. A Slack feature with no `slack_accounts` row reads `needsSource(.slack)` → "Connect Slack to get this". The sidebar hides Catch-Up and Statistics while no messages source is connected (`SidebarDestination.requiredSources`); §2.2 changes that for Live.
- **Phone:** no Slack-derived screens. Settings → Accounts lists the Mac's heartbeat accounts (`HeartbeatAccount` kind/label/status, written by `internal/hub/slices/heartbeat.go` `DBAccounts` from `slack_accounts`) with `AccountStatusStyle` (`WatchtowerMobile/Sources/Features/Settings/AccountStatusStyle.swift`). The phone has no DesignShot catalog (its shots are the simulator `ScreenshotTourTests`), so its change is described in text only.
- **Language:** the Desktop is not localised (no `.lproj`/`.xcstrings`, no `String(localized:)`; `EmptyStateCopyTable`: "UI text is English only"). Every string below is English. The mode names stay **Full** / **Live** (D1).

## 1. Connections → Slack: the mode

`SlackConnectionDetail` moves off `Form` onto `SettingsSection`s in a `ScrollView` (style guide; the old sections port as they are). Top to bottom:

1. The shared-app banner (§5), only when an account syncs through the retired app.
2. **Slack mode** — the chip, a one-sentence summary, and the **Live** block.
3. The admin's unfinished setup, one row, only when a setup record exists (§3.4).
4. **Connect your workspace's app** (§4.2) — shown in Live, Off and Shared app; in Full it is folded behind **Connect another workspace…** under Workspaces.
5. **Workspaces** — the account rows, then the existing reaction dictionary.

### 1.1 The chip and the summary

The chip is `SlackMode.derive` (never stored, SLACKMODE-01) plus one display-only override: an enabled account on the retired shared app shows **Shared app** (the derived mode stays what it is; the parent's `full` fact excludes the shared app, so the derived value would be Live or Off while the data still syncs — the chip must not say "Off" over a syncing account).

| Display | When | Chip (Tone) | Summary |
|---|---|---|---|
| Full | `full`, no Live `ok` row | "Full" (`Tone.success`) | "Synced on this Mac through your workspace's own Slack app. Every feature works." |
| Full · Live on | `full` and `SlackMode.liveOn` | "Full · Live on" (`Tone.success`) | "Synced on this Mac through your workspace's own Slack app. Chats also read Slack through Live for what is not synced." |
| Live | derived `live` | "Live" (`Tone.status("blue")`) | "Chats and automations read Slack through your Claude or ChatGPT connector. Nothing is synced, so digests, the Inbox, tracks and people need your workspace's app." |
| Off | derived `off`, no shared-app account | "Off" (`Tone.status("gray")`) | "Slack is not connected. Connect your workspace's app to sync, or turn on the Slack connector in your Claude or ChatGPT account to ask about Slack in Chats." |
| Shared app | the account's `shared_app` flag (rule below) is true, on an enabled, not removed account | "Shared app" (`Tone.warning`) | "<label> syncs through Watchtower's old shared Slack app until Slack turns it off." |

**Which account is on the shared app (one rule, asks #1414/#1425).** Go decides and reports `shared_app` in `slack accounts --json`; Swift only reads the flag. There is no build-flavor input and no corp rule:

- `shared_app` = the row's `client_id` equals `auth.RetiredSharedClientID` (the retired public shared app's id, a recognition-only ldflag, no secret), on an enabled, not removed account (`slackmode.SharedApp`). Every other id — a setup app, an MDM or link id, the corp build's baked app — is a company app (Full); the corp admin brings that app up to date with the adopt path of §3.2.
- **A row with an empty `client_id`** (connected before plan B's column) is **not shared**, whatever the build. The A17 backfill (`slackmode.BackfillClientIDs`, run by `slack accounts`, the daemon's start and every connect) gives it the build's baked id, or, with nothing baked, `RetiredSharedClientID`; from then on the rule above applies. Until then its Re-login follows A17: through the build's own app while one exists, else the connect flow (link / MDM) (`slackmode.Relogin`).
- **An unset `RetiredSharedClientID`** (a `make build` or `--dev` binary) means nothing is shared: no chip, no banner.
- **The id must be in every public release (build-time guard).** The release `.app` is built only by `scripts/build-app.sh` (`make app`/`dmg` call it); its `go build -ldflags` line gains `-X watchtower/internal/auth.RetiredSharedClientID=${RETIRED_SLACK_CLIENT_ID}` from the build profile. A new block `retired-slack-id-check` in that script, placed with the other pre-build checks (beside `bridge-profile-check`), stops a **public release** — flavor `""`/`dev` per `FlavorOf`, not `--dev`, `NOTARIZE_PROFILE` set (the script's existing release test) — before anything is built when `RETIRED_SLACK_CLIENT_ID` is empty: "ERROR: a public release must set RETIRED_SLACK_CLIENT_ID (recognises accounts on the retired shared Slack app)". A corp profile and `--dev` builds are not checked. Test: `scripts/tests/test-build-app-retired-slack-id.sh` (run by `make test-scripts`, part of `make release-check`) extracts the block verbatim like `test-build-app-bridge.sh` does and asserts: public release + empty → exit 1; public release + set → passes; corp → passes; `--dev` → passes. A Go test cannot check the release profile itself: profiles (`.env`) are gitignored.
- Tests: `TestSlackAccountSharedApp_RetiredIDOnly` (only the retired shared id is shared; a corp-baked, MDM or link id, an empty `client_id` and an unset retired id are not), `TestSlackAccountRelogin_FirstMatchWins` (the empty-id Re-login), `TestBackfillSlackClientIDs_FromBakedID`, `_AfterRetirement` (A17), `TestSlackAccountsJSON_SharedAppByClientIDOnly`. Swift only reads the flag: `SlackModePresentationTests.testSharedAppFollowsFlag`.

### 1.2 The Live block

One row per provider that has a `slack_live_status` row (Claude first, then ChatGPT (Codex)); the provider's newest row decides it. Each row: a state dot, "<provider>: <status>", the reason under it, and the age on the right. **Check again** sits on the block's header and calls `SlackLiveStatusCenter.checkAgain()`.

| `status` / `error_class` | Status text | Reason line | Dot (Tone) |
|---|---|---|---|
| `ok`, identified teams | "On · <workspaces, comma-separated>": an account's label when the team has one, else the team id (Live only has no accounts) | — | `success` |
| `ok`, only team `''` | "On · workspace not identified" | "Chats use it; Watchtower could not tell which workspace it reads." | `success` |
| `not_connected` / `cli_missing` | "Not connected" | "Claude Code is not installed on this Mac." / "Codex is not installed on this Mac." | `status("gray")` |
| `not_connected` / `connectors_off` | "Not connected" | "Connectors are off in Watchtower's chat settings." | gray |
| `not_connected` / `disabled` | "Not connected" | "The Slack connector is switched off in Watchtower's chat settings." | gray |
| `not_connected` / `policy` | "Not connected" | "Your organization's policy turns this off." | gray |
| `not_connected` / `workspace_not_connected` | "Not connected" | "The connector reads a different Slack workspace." | gray |
| `not_connected` / `connector_id_unknown` | "Not connected" | "Codex has not loaded its Slack app yet. Check again later." | gray |
| `not_connected` / anything else | "Not connected" | "Turn on the Slack connector in your Claude or ChatGPT account." | gray |
| `needs_admin` | "Waiting for your Slack admin" | "Your workspace admin must approve the connector." | `warning` |
| `no_plan` | "Not in your plan" | "Your plan has no Slack connector." | gray |
| `unavailable` / `sandbox` | "Unavailable" | "The chat sandbox is not available on this Mac." | `warning` |
| `unavailable` / anything else | "Unavailable" | "The connector did not answer. Check again later." | `warning` |

The age is `checked_at` against now: "checked just now" (under 1 min), "checked N min ago" (under 60 min), "checked N h ago" (under 48 h), "checked N d ago". Never a bare "on" (parent §1).

States of the block (every one has a shot, §8):

| State | Source | What shows |
|---|---|---|
| Loading | the center has not finished its first `reload()` | spinner + "Reading the Live status…"; no **Check again** |
| Empty | read done, no rows | "Live has not been checked yet." + **Check again** |
| Busy | `isRunning` | spinner in the section title, rows kept, **Check again** disabled, "Checking Live… this takes a few seconds." |
| Probe failed | `lastError` from a probe run | rows kept + warning line "The Claude Live Slack check failed: <error>"; retry = **Check again** |
| Read failed | `lastError` from `reload()` | warning line "Could not read the Live Slack status: <error>." + **Try again** (→ `reload()`); **Check again** hidden |

To print "Claude" instead of the CLI's `claude`, the center keeps its last error as a value (`provider`, `message`, `kind: probe | read`) and the presentation builds the sentence; today's `lastError` string goes.

### 1.3 The view model

`SlackModePresentation` in `WatchtowerDesktop/Sources/WatchtowerCore/Services/Slack/SlackModePresentation.swift`: a pure value built from `[SlackAccount]`, `[SlackLiveStatusRow]`, the center's `isRunning`/`hasRead`/last error, the setup record (§3.4), the connect listener's state (§4.4), the MDM `SlackApps` list, and `now`. It owns every string of §1, §4.2, §4.4 and §5 (the chip, summary, Live rows, reasons, ages, block states, the connect section, the setup-record row, the banner). The view only lays it out. Test: `SlackModePresentationTests` (`Tests/Core`) pins every string of these tables and each state's choice of actions; the mode itself stays pinned by the existing `slack_mode_cases.json` (SLACKMODE-01).

New on the center: `hasRead` (the first `reload()` finished) for the loading state.

## 2. `needsFullSlack` on the Slack-dependent screens

### 2.1 The state

`ReadinessSource.fullSlack` (new case in `WatchtowerCore/Models/Readiness.swift`), with `Readiness.needsFullSlack` as the name for `.needsSource(.fullSlack)`. `ReadinessInputs` gains `slackLiveOnly: Bool` — `SlackMode.derive(...) == .live` (no synced account, a Live `ok` row). In `FeatureReadiness.readiness(of:)`, where the feature's source is not connected:

- source `.slack` and `slackLiveOnly` → `.needsFullSlack` (instead of `.needsSource(.slack)`);
- source `.anySource`, nothing else connected and `slackLiveOnly` → `.needsFullSlack` (instead of `.needsSource(.anySource)`);
- otherwise unchanged. A shared-app account counts as connected (`ConnectedSources.slack` reads `slack_accounts`), so its features keep their content and never show this state. Precedence is unchanged: `off` still wins.

Strings (in `FeatureReadiness.line` and `ReadinessSource.actionTitle`):

- line: "Needs your workspace's Slack app. Live answers in Chats only."
- button: "Connect workspace app" — `EmptyStateAction.connect(.fullSlack)` opens Connections → Slack (`ConnectionService(readinessSource:)` maps `.fullSlack` to Slack).

Tests: `FeatureReadinessTests.testNeedsFullSlackForSlackFeatures`, `testNeedsFullSlackForAnySourceOnlyWhenNothingElse`, `testSharedAppAccountIsNotNeedsFullSlack`, `testOffBeatsNeedsFullSlack`; `EmptyStateCopyCoverageTests` gains the new line.

### 2.2 Where it shows

| Screen | Feature (source) | Shows `needsFullSlack` when |
|---|---|---|
| Digests | `digests` (slack) | Live only |
| Tracks | `tracks` (slack) | Live only |
| People | `peopleCards` (slack) | Live only |
| Ideas | `ideas` (slack) | Live only |
| Catch-Up | `digests` (slack) | Live only — the tab stays visible with Live alone (sidebar rule below) |
| Inbox, Inbox → Messages | `inbox` (anySource) | Live only and no mail, calendar, Jira or Linear |
| Morning brief (Briefings), Day plan | `briefing`, `dayPlan` (anySource) | same |
| Memory | `memory` (anySource) | same |
| Home → Getting ready | every card above | the card's line and a **Connect workspace app** button (`.kitSecondary`, Home has its own prominent action) |
| Statistics | `slackSync` (slack) | Live only — the tab stays visible with Live alone (sidebar rule below) |
| Knowledge (search) | `knowledgeIndex` (none) | no readiness change. The note "Slack is not in Knowledge: Live answers are not kept. Connect your workspace's app to add synced Slack." (quiet **Connect workspace app**) ships as a string in `SlackModePresentation.knowledgeNote` with its test only: the Desktop has no Knowledge search screen yet, so it is placed under that screen's search field when one exists (agent decision, §11 B4) |

**The sidebar with Live only (owner, ask #1315).** Catch-Up and Statistics stay visible and show `needsFullSlack` instead of being hidden. Rule, in `WatchtowerCore/Services/SidebarVisibility.swift`: `ConnectedSources` gains `slackLive` (`ConnectedSources.fetch`: `EXISTS(SELECT 1 FROM slack_live_status WHERE status = 'ok')`), `SidebarSource` gains `.slackLive` (`provides` → `slackLive`), and `SidebarDestination.requiredSources` adds `.slackLive` to exactly these two tabs: Catch-Up `[.messages, .slackLive, .jira, .linear, .calendar]`, Statistics `[.messages, .slackLive]`. `.messages` keeps its meaning (synced Slack or mail), so no other tab changes. Re-read: `AppState.refreshConnectedSources()` runs on a `SlackLiveStatusCenter.statuses` change, next to the `ReadinessCenter.refresh()` of §6, so the tabs appear and disappear with the mode. Tests: `SidebarVisibilityTests.testLiveOnlyShowsCatchUpAndStatistics`, `testLiveDoesNotCountAsMessages` (every other `.messages` tab stays hidden), `testRefreshOnLiveStatusChange`.

**The one narrowing of the parent's promise** ("`needsFullSlack` on every Slack-dependent screen"): **Knowledge shows a note, not a readiness state** (its feature has no source to need). Every other Slack-dependent screen shows the state.

Mocked: the Digests empty state (wide and narrow), Catch-Up, Statistics, a Home card, the Knowledge note (a mockup of a future placement, see the Knowledge row). The other tabs draw the same `FeatureEmptyState` with their own title and "lands here" line; their loading/error/busy states are `FeatureEmptyState`'s existing ones (nil readiness = no line; error and preparing are other readiness values) and do not change.

### 2.3 The phone

The phone has no digests, Inbox or briefing screens, so the state shows only in Settings → Accounts:

- Go: `accountsSQL` / `DBAccounts` (`internal/hub/slices/heartbeat.go`) lists Slack accounts with `status != 'removed'` (it does not look at `enabled`). It gains one extra row `{kind: "slack", label: "Slack", status: "live"}` when that query returns no Slack account (no row with `status != 'removed'`) and a `slack_live_status` row is `ok` — the same rule as `slackmode.Derive`, with "an account" meaning what `accountsSQL` already counts. Test `TestDBAccounts_LiveOnlySlackRow` (and that any listed Slack account suppresses it).
- **Phase-1 limit:** per the code comment on `DBAccounts`, the hub runtime starts only in a `hubtest-*` test workspace (go hub phase 1, Task 14), so this row reaches no real phone until the hub leaves phase 1. The change is still specified now so the wire value is settled.
- Paths that change together: Go `internal/hub/slices/heartbeat.go` (`accountsSQL`/`DBAccounts`, the row) → the wire `HeartbeatAccount` (`internal/hub/wire/payloads.go`, unchanged shape: `status` is a free string) → Kit `HeartbeatAccount` (`WatchtowerKit/Sources/WatchtowerSync/Relay/HeartbeatPayload.swift`, unchanged) → phone `AccountStatusStyle` (`WatchtowerMobile/Sources/Features/Settings/AccountStatusStyle.swift`, new `live` case). `accountsSQL`'s comment names a Swift twin (`HubAccountRows`) that no longer exists in the tree; nothing else on the Desktop changes.
- Phone: `AccountStatusStyle(status: "live")` → mark `.textOnly`, text "Live only — sync needs your workspace's app", tone `.secondary`. Test `AccountStatusStyleTests.testLiveOnly` (`WatchtowerMobile/Tests`). A shot is added to `ScreenshotTourTests` with the implementation, not here.
- An older phone shows the raw word "live" (its `default:` branch) — acceptable, nothing breaks.

## 3. Set up for my company (D9)

### 3.1 Where it starts

**Set up for my company** appears in the connect section ("No Watchtower app in your workspace yet?"), and on the shared-app banner. It opens a sheet over the main window (a short blocking flow — the style guide's case for a sheet).

### 3.2 The sheet

| State | Shot | What shows | Buttons |
|---|---|---|---|
| Empty | `slack-fl-setup-empty` | title "Set up Watchtower for your company"; intro "Creates Watchtower's app in your Slack workspace from our manifest. Colleagues then connect from the app's About page in Slack; nothing depends on this Mac afterwards."; step 1 "1. Generate a configuration token" + "On Slack's app page, under Your App Configuration Tokens, press Generate Token for your workspace and copy the access token." + **Open Slack's token page**; step 2 "2. Paste it here", a secure field "Configuration token", "Used once for this setup and never stored." | **Cancel**, **Create the app** (disabled) |
| Ready | `slack-fl-setup-ready` (+ `-narrow`) | the same, token pasted | **Cancel**, **Create the app** |
| Busy (progress) | `slack-fl-setup-progress` | four steps with done / running / waiting marks: "Checking the token", "Creating the app", "Writing the connect link to its About page", "Connecting your Slack account"; "Keep this window open. If it closes, continue from Connections → Slack; the app is never created twice." | **Close** |
| Success | `slack-fl-setup-success` | "Watchtower's app is ready in <workspace>" / "You are connected. Colleagues open Watchtower in Slack, go to About and click the connect link." | **Copy connect code**, **Done** |
| Error: bad token | `slack-fl-setup-badToken` | "That token did not work: it has expired or is not a configuration token. Generate a new one and paste it." | **Cancel**, **Try again** |
| Error: not allowed | `slack-fl-setup-notAllowed` | "Your workspace does not let you create apps. Ask a workspace admin to run this setup." Under it, the note for the admin, shown ready to copy and selectable: "Please set up Watchtower for <workspace> in Slack: <guide link>" (A23; the guide page is Task 17's); after **Copy a note for your admin**: "Copied. Send it to a workspace admin." The not-collaborator state (adopt) offers the same note | **Cancel**, **Copy a note for your admin**, **Try again** |
| Error: network | (layout of `badToken`) | "Could not reach Slack: <error>. Nothing was created." | **Cancel**, **Try again** |
| Error: other Slack refusal | (layout of `badToken`) | "Slack refused the app: <code>. Nothing was created." | **Cancel**, **Try again** |
| Link not written | `slack-fl-setup-linkFailed` | "Watchtower's app is ready in <workspace>" / "The app works, but its About page has no connect link yet: the token expired before the link was written. Paste a fresh token to add it." | **Close**, **Add the link to the app** |
| Waiting for approval | `slack-fl-setup-approval` | "Waiting for your admin's approval. Slack sent them a request to install Watchtower. Check again once they approve; this window can close." | **Close**, **Check again** |
| Error: another run (plan B Task 13 review) | `slack-fl-setup-busy` | "Another setup is already running on this Mac. Try again once it has finished." Test: `testBusyShowsAlreadyRunning` | **Cancel**, **Try again** |
| Create answer lost (`pending_create`, plan B Task 13 review) | `slack-fl-setup-pendingCreate` | "Slack did not answer when Watchtower asked it to create the app in <workspace>, so the app may exist. Look for “Watchtower” on api.slack.com/apps. If it is there, enter its App ID and Client ID from its Basic Information page, then paste a fresh configuration token to add the connect link; if not, start again." + quiet **Open Slack's app page**, fields "App ID" and "Client ID". **Use this app** records the ids (`--attach`, no token) and opens §3.3, which asks for a configuration token again: two steps, because the pending form holds no token (it comes from a run that has ended); a written link on a setup whose owner is not connected goes on to the connect. **Start again** first asks (next row). Test: `testPendingCreateLeftOver`, `testAttachedAppLinkThenConnects` | **Cancel**, **Start again**, **Use this app** |
| Start again after a lost create (plan B Task 13 spec review) | `slack-fl-setup-pendingConfirmClear` | "Watchtower may have created the app already. Check Slack's app page first: if “Watchtower” is there, enter its ids and use it. Start again only if it is not there, or the workspace gets a second Watchtower app." Only the second press clears the pending record (`slack app pending --clear`) and brings back the empty form; a `no_pending` answer says "The setup for <workspace> no longer waits for Slack's answer. Connections → Slack shows where it stands." with **Done**. Tests: `testPendingClearStartsOver`, `testClearPendingAnsweredNoPendingSaysSo` | **Cancel**, **Nothing there: start again**, **Use this app** |
| Adopt (`existing_app`, ask #1425) | `slack-fl-setup-adopt` | title "Watchtower's app already exists in <workspace>", body "Update it to the current version: Watchtower adds the connect link to its About page and the sign-in settings it needs. Nothing changes for colleagues already connected." above the token form. Test: `testExistingAppOffersAdoptNotCreate` | **Cancel**, **Update the app** |
| Adopt: App ID needed (`need_app_id`, A19) | `slack-fl-setup-adoptAppId` | the adopt title and body, then a field "App ID" with "Find it on the app's Basic Information page at api.slack.com/apps."; **Update the app** waits for it. Test: `testAdoptNeedsAppID` | **Cancel**, **Update the app** |
| Adopt: not a collaborator (`not_collaborator`, Q11) | `slack-fl-setup-adoptNotCollaborator` | title "Watchtower's app already exists in <workspace>", body "Your token cannot change this app. Ask one of its collaborators (listed on its Collaborators page) to run this setup.", then the admin note ready to copy (as in **not allowed**). Tests: `testNotCollaboratorState`, `SlackAppSetupSheetTests.testReviewStatesMatchTheMockups` | **Cancel**, **Copy a note for your admin**, **Try again** |
| Adopt: check the App ID (`confirm_app`, plan B Task 13 review) | `slack-fl-setup-adoptConfirm` | the adopt title "Watchtower's app already exists in <workspace>", then "App <app id> is called “<name>”. Update it only if it is your workspace's Watchtower app." (an App ID typed in the field is confirmed by its name before anything changes). Test: `testAdoptNeedsAppID` | **Cancel**, **Update the app** |
| Adopt: App ID not taken (plan B Task 13 review) | `slack-fl-setup-adoptAppIdProblem` | under the App ID field: "That is not an App ID: it starts with A." (also "That App ID is not the app this workspace connects through.", "Slack has no app with that App ID in this workspace."). The pending form's id checks use the same lines: "That is not an App ID: it starts with A." / "That is not a Client ID: two numbers joined by a dot." Test: `testAdoptNeedsAppID`, `testAdoptAppNotFound`, `testPendingCreateLeftOver` | **Cancel**, **Update the app** |

Unmocked lines that reuse a mocked layout (plan B Task 13 review): "That token is for <workspace>, not this setup's workspace. Generate one in the right workspace." (adopt or link with another workspace's token: nothing is changed), "Slack refused the change: <code>. Nothing was changed." (adopt, link), "Watchtower could not save the setup on this Mac, so it stopped. Connections → Slack shows the setup: press <the button its record row shows — Continue setup, Check again or Add the link to the app> on its row there. The app is never created twice." (no row: "… so it stopped. Try again. The app is never created twice.") (`testStorageSaysHowToGoOn`), "Watchtower could not save this on this Mac. Nothing changed on Slack's side; try again." (pending), "The setup for <workspace> no longer waits for Slack's answer. Connections → Slack shows where it stands." (**Done**), "This Mac has no unfinished setup for <workspace>, so there is nothing to add the link to.", "Watchtower's app is not connected in <workspace> any more, so there is nothing to update. Create the app instead.", "The setup stopped before it finished: <error>. Connections → Slack shows where it got to; the app is never created twice." (the CLI ended without an answer). Adopt steps: "Checking the token", "Reading the app" (App ID from the field only), "Updating the app". The pasted token field empties when a run starts; the token lives in the model for that run only (`testSubmitClearsTheTokenField`). A link written while the status cannot be read goes on to the connect rather than ending at Done (`testLinkWithUnreadableStatusGoesOnToTheConnect`).

**Adopt (ask #1425).** The adopt states have one entry point: a **Create the app** run whose CLI answers `existing_app` (the workspace already has a live account on a company app, e.g. the corp build's baked app) — never a second create. Title "Watchtower's app already exists in <workspace>", body "Update it to the current version: Watchtower adds the connect link to its About page and the sign-in settings it needs. Nothing changes for colleagues already connected.", **Update the app** (`slack app adopt --team <the shown workspace>`: a token of another workspace answers `wrong_team` and changes nothing, `TestAdopt_WrongTeam`, `testAdoptPassesTheShownTeamAndRefusesAnother`). Adopt must not ship to users before plan B Task 16 decides PKCE on adopt: the CLI does not turn `pkce_enabled` on yet (`Runner.EnablePKCEOnAdopt` false), and if Task 16 turns it on, the adopt body's last sentence becomes "Watchtower turns on PKCE sign-in for this app, which cannot be undone; Slack may ask colleagues already connected to allow Watchtower again." (one-way on Slack's side, spike), shown above **Update the app**. Tests: `testExistingAppOffersAdoptNotCreate`, `testAdoptSuccess`, `testNotCollaboratorState`.

Nothing asks for the workspace, the app name or the redirect: the token names the workspace, the manifest is ours, the name is "Watchtower". The workspace's label in the success line comes from Slack's answer.

The token is passed to the CLI on stdin, never in argv (as `slack_token_<id>.json` keeps secrets out of argv), and lives only in the sheet's model until the run ends.

### 3.3 Add the link to the app

The same sheet in its link mode, opened from the setup's "Link not written" state or from the setup-record row (§3.4). Title "Add the connect link to the app", intro "Writes the connect link and code into the About page of Watchtower's app in <workspace>. Needs a fresh configuration token." Shots: `slack-fl-setup-addLinkEmpty`, `-addLinkBusy` ("Writing the link…"), `-addLinkError` (the bad-token line + **Try again**), `-addLinkDone` ("The connect link is on the app's About page." + **Done**). Buttons: **Cancel**, **Add the link**; while the link is being written, **Close** (closing the sheet does not stop the run) and **Add the link** disabled (plan B Task 13). When the setup's owner is not connected yet (an app attached after a lost create), a written link goes on to the connect (step 4 of §3.2).

### 3.4 The unfinished setup on Connections → Slack

The setup keeps a record (team, app id, client id, stage, whether the link is written; parent §5.1 step 3). While a record is not finished, Connections → Slack shows one row above the connect section with one prominent button:

| Record | Row | Button | Shot |
|---|---|---|---|
| app created, owner not connected | "Setup is not finished: Watchtower's app exists in <workspace>, but you have not connected yet." | **Continue setup** (re-runs from the install step; never a second create) | `slack-fl-pane-setupInstall` |
| install requested, approval pending | "Waiting for your admin's approval in <workspace>. Check again once they approve." | **Check again** | `slack-fl-pane-setupApproval` |
| connected, link not written | "The app's About page has no connect link yet, so colleagues cannot connect." | **Add the link to the app** | `slack-fl-pane-linkMissing` |
| create answer lost (`pending_create`, plan B Task 13 review) | "Setup is not finished: Slack did not confirm Watchtower's app in <workspace>. Check api.slack.com/apps before going on." | **Continue setup** (opens the lost-create state of §3.2) | `slack-fl-pane-setupPending` |

Whether Slack tells the loopback callback that an install request is pending (rather than sending nothing) is not known yet (T1 spike). Without such an answer the approval case shows as "Setup is not finished", which is still true; the approval row appears only when Slack says so.

### 3.5 The view model

`SlackAppSetupModel` in `WatchtowerDesktop/Sources/WatchtowerCore/Services/Slack/SlackAppSetupModel.swift`, `@Observable`, held on `AppState` (`slackAppSetup`, like `slackAuthFlow`) so a run survives closing the sheet and switching tabs. It runs the T7 CLI (`watchtower slack app create --json`, `slack app link --json`, `slack app status --json`; names final in plan B) through `CLIRunnerProtocol`, reads one JSON line per step, and owns every string of §3. Test: `SlackAppSetupModelTests` (`Tests/Core`) — the strings of every state, step marks from a scripted CLI, the token never in argv, and the resume cases of §6.

## 4. Entry into Full for everyone else

### 4.1 The app's About page in Slack

Not a Watchtower screen: Slack renders the manifest's `long_description`, written by the setup (T7, Go, pinned by `TestAppSetup_WritesLinkToDescription`):

```
Watchtower for <workspace>. Connect: http://127.0.0.1:18551/slack/connect?team=<team id>&client=<client id>
Connect code: <team id>:<client id> — paste it in Watchtower → Connections → Slack if the link does not open.
Open Watchtower first. No Watchtower yet? Download it from <release page>.
```

### 4.2 The connect section (Live, Off, Shared app; folded in Full)

`SettingsSection` "Connect your workspace's app", caption "Open Watchtower's app in Slack, go to its About tab and click the connect link. No clickable link? Paste the link or the connect code here." Then:

- **Set up by your organization** (only with the MDM key `SlackApps`, D4): one row per `{team_id, client_id}`, "Workspace <team id>" (the key carries no name) + **Connect** (the pane's one prominent action). Shot `slack-fl-pane-organization`.
- A field "Connect link or code" + **Connect** (disabled while empty). It accepts the link or the `<team>:<client id>` code; anything else: "That is not a Watchtower connect link or code. Copy it again from the app's About tab in Slack." (shot `slack-fl-pane-pasteInvalid`).
- "No Watchtower app in your workspace yet?" + quiet **Set up for my company**.

In Full the section is folded behind a quiet **Connect another workspace…** under Workspaces (shots `slack-fl-pane-full`, `-fullLive`): after retirement (T9) the public build has no baked client id, so this is how a second workspace connects there. Scope (asks #1414/#1425, plan B A8): **every build** once it no longer bakes a Slack app (`builtin_app: false` in `slack accounts --json`) — there the old **Add Slack Account** sheet goes. The corp build is no exception: its baked app is the company's own app, which its admin adopts (brings up to date with the adopt path of §3.2) before plan B Task 18 drops the baked id; its colleagues then connect from that app's About link or the MDM key like everyone else. **Order:** plan B Task 16 (adopt turns on `pkce_enabled`; the secret-less exchange needs it, spike) ships before Task 18 drops the baked id — Task 18's "Depends on: Task 15, Task 16, Task 17 … and the corp admin has run Set up for my company (adopt) on the corp app" in `docs/superpowers/plans/2026-11-17-slack-full-plan-b.md`.

### 4.3 The flow

| Step | Shot | What shows | Buttons |
|---|---|---|---|
| Confirm (link clicked) | `slack-fl-connect-confirm` | Watchtower comes forward on Connections → Slack with a sheet: "Connect a Slack workspace?" / "A link asks Watchtower to connect workspace <team id> through app <client id>. Connect only if you opened this link yourself." | **Cancel**, **Connect** |
| Browser (busy) | `slack-fl-connect-browser` | spinner, "Finish in your browser: Slack asks you to allow Watchtower." / "If Slack says your admin must approve the app, connect again once they have." | **Cancel** |
| Connected | `slack-fl-connect-success` | "Connected to <workspace>" / "The first sync starts now. Digests and the Inbox fill in after it." | **Done** |
| Team mismatch | `slack-fl-connect-teamMismatch` | "Slack signed you in to a different workspace than the link names. Nothing was saved." | **Close**, **Start again** |
| Denied in Slack | `slack-fl-connect-denied` | "You did not allow Watchtower in Slack. Nothing was saved." | **Close**, **Start again** |
| Failed (other) | (layout of `teamMismatch`) | "Could not connect: <error>. Nothing was saved." | **Close**, **Start again** |

A pasted link or code is the owner's own press, so it skips the confirm and starts at the browser step. An MDM **Connect** also skips it. Only a link that reached the loopback listener asks first (parent §5.3: any web page can open a loopback URL).

Waiting for approval: a regular user whose workspace requires approval sees Slack's own "request sent" page; Watchtower gets no callback and stays on the browser step, whose second line says what to do. **Cancel** ends it; nothing is stored.

### 4.4 Port 18551 busy

When the listener cannot bind, the connect section shows a warning line above the field: "The connect link cannot reach Watchtower: port 18551 is busy. Quit the app holding port 18551, then open Connections → Slack again to retry." (shot `slack-fl-pane-portBusy`). Slack is strict about the redirect port (plan B spike Q4, A9), so a pasted link or code cannot finish either while the port is busy: the flow fails with "Could not connect: port 18551 is busy. Nothing was saved." In Full the folded section opens by itself while the port is busy, so the line is seen. The listener tries to bind again each time Connections → Slack opens; the line goes when it succeeds.

### 4.5 The view model

`SlackConnectFlowModel` in `WatchtowerDesktop/Sources/WatchtowerCore/Services/Slack/SlackConnectFlowModel.swift`, `@Observable`, held on `AppState` beside the listener (T8). It parses the pasted text, runs the flow's states (idle → confirming → browser → connected / failed), and owns every string of §4.2–§4.4 except the section's static lines, which `SlackModePresentation` builds. One flow at a time: the shared `SlackAuthFlowState` guard also covers Reconnect. Test: `SlackConnectFlowModelTests` (`Tests/Core`).

## 5. The retired shared app (D11)

- **Banner** at the top of Connections → Slack while any enabled account is on the shared app (shots `slack-fl-pane-sharedApp`, `-sharedApp-narrow`): icon in `Tone.warning`, the card tinted with `Tone.warning` at `ChipTint.fillOpacity`, title "Watchtower's shared Slack app is retiring", body "<label> still syncs through it until Slack turns it off. Move to Full with your workspace's own app, or use Live through your Claude or ChatGPT account." Buttons: **Set up for my company** (`.kitSecondary`), **Paste a connect link** (`.kitQuiet`, focuses the connect field). No dismiss: it goes when the account moves to its workspace's own app — the move re-binds the same account row to the new client id, history kept, nothing removed (ask #1425, which replaced #1414's new-row move; SLACK-01 untouched) — or when Slack stops the token (the account then shows the existing Re-login/error state).
- The account row carries an outline tag "Shared app" and "Syncing through the shared app · last sync <age>".
- **Connections overview:** the Slack card's status line reads "Shared app retiring"; it is not a problem (`needsAttention` stays false, no red badge) — the app keeps working.
- Strings in `SlackModePresentation` (`sharedAppBanner`); tests `SlackModePresentationTests.testSharedAppBanner`, `testSharedAppIsNotAttention`; the parent's `TestSharedAppBanner` (T9) covers the Go side of the shared-app detection.

## 6. Failure modes

| Path | Failure | Behaviour | Test |
|---|---|---|---|
| Live block | the app quits or the Mac sleeps mid-probe | the CLI child is reaped (plan A); no row written; on next open `refreshIfStale` probes again; the block shows the rows it reads | `TestLiveProbe_KilledLeavesNoRow` (exists), `SlackModePresentationTests.testBusyKeepsRows` |
| Live block | the status read fails | read-failed state with **Try again**; old rows stay | `SlackLiveStatusCenterTests.testReadFailureKeepsRows` |
| Live block | **Check again** pressed twice | the second press is ignored while `isRunning` (button disabled) | `SlackLiveStatusCenterTests.testCheckAgainWhileRunningIsIgnored` |
| Setup | sheet closed mid-run | the run continues on `AppState.slackAppSetup`; the pane shows its record row when it ends | `SlackAppSetupModelTests.testCloseKeepsRunning` |
| Setup | app quits after create, before install | the record stays; next launch shows **Continue setup**; the CLI resumes at install, never a second create | `TestAppSetup_ResumeAfterCreate` (parent), `SlackAppSetupModelTests.testRecordOffersContinueNotCreate` |
| Setup | token expires between create and link write | "Link not written" state; **Add the link to the app** with a fresh token | `TestAppSetup_LinkUpdateFails` (parent), `SlackAppSetupModelTests.testLinkFailedOffersAddLink` |
| Setup | bad or wrong token | stop before any create; bad-token state | `TestAppSetup_BadConfigToken` (parent), `SlackAppSetupModelTests.testBadTokenState` |
| Setup | the token reaching argv or disk | never: stdin only, model drops it at the end | `SlackAppSetupModelTests.testTokenNeverInArgv`, `TestAppSetup_SecretNeverStored` (parent) |
| Setup | the create's answer is lost (`pending_create`) | never a second create: the lost-create state; the owner attaches the app found on api.slack.com/apps or, after a second confirming press, starts again | `TestAppSetup_LostCreateAnswerCLI` (parent), `SlackAppSetupModelTests.testPendingCreateLeftOver`, `testPendingClearStartsOver` |
| Setup | adopt with a token of another workspace | `wrong_team` before any export or update; nothing changed | `TestAdopt_WrongTeam`, `TestAppSetup_AdoptWrongTeamCLI`, `SlackAppSetupModelTests.testAdoptPassesTheShownTeamAndRefusesAnother` |
| Setup | Slack did its part, the local save failed (`storage`) | the storage line names the record row's own button (by stage), else says try again; never a second create | `SlackAppSetupModelTests.testStorageSaysHowToGoOn` |
| Setup | the CLI exits with no answer (crash, kill, refused to start, not installed) | the running step marked failed; "The setup stopped before it finished: <error>…"; the record row (if any) shows where it got to | `SlackAppSetupModelTests.testCLIExitsMidway`, `testNoCLIStops` |
| Connect | the app quits between redirect and callback | the flow is in memory only: after restart the model is idle and the listener answers the late callback "start again" | `TestSlackConnectListener_CallbackWithoutFlow` (parent), `SlackConnectFlowModelTests.testFreshModelIsIdle` |
| Connect | a second link arrives while a flow runs | no second confirm; the running flow keeps its sheet | `SlackConnectFlowModelTests.testSecondLinkWhileRunningIsRefused` |
| Connect | a web page opens the loopback link | the confirm; nothing starts without **Connect** | `TestSlackConnectListener_RequiresConfirm` (parent), `SlackConnectFlowModelTests.testLinkStartsAtConfirm` |
| Connect | pasted text is neither link nor code | inline error, nothing starts | `SlackConnectFlowModelTests.testPasteRejectsOtherText` |
| Connect | team mismatch / denied | failed state, nothing stored, **Start again** | `TestSlackLinkConnect_TeamMismatch` (parent), `SlackConnectFlowModelTests.testMismatchAndDeniedStates` |
| Listener | port 18551 busy | warning line telling the owner to free the port (paste cannot finish either, A9); bind retried when the pane opens | `TestSlackConnectListener_PortBusy` (parent), `SlackModePresentationTests.testPortBusyLine` |
| Readiness | the mode changes Off ↔ Live (a probe or a chat use writes `slack_live_status`) while a tab is open | `slackLiveOnly` is a new `ReadinessInputs` input, so it needs its own trigger: `ReadinessCenter` reads `slack_live_status` in `readSnapshot` (added to `DBSnapshot`), and a change of `SlackLiveStatusCenter.statuses` calls `ReadinessCenter.refresh()` at once (the probe is a CLI child — another process — which the GRDB observation does not see; the 30 s tick is only the backstop for chat/automation writes). Off → Live turns "Connect Slack to get this" into `needsFullSlack`; Live → Off the reverse | `ReadinessCenterTests.testLiveStatusChangeReevaluates`, `FeatureReadinessTests.testOffModeKeepsConnectSlack` |
| Build | a public release built without `RETIRED_SLACK_CLIENT_ID` | refused before building by `retired-slack-id-check`; a non-release binary without the id calls nothing shared (no banner), and an empty `client_id` is never shared (§1) | `scripts/tests/test-build-app-retired-slack-id.sh`, `TestSlackAccountSharedApp_RetiredIDOnly` |
| Sidebar | the mode changes Off ↔ Live while the app is open | `refreshConnectedSources()` on the center's change: Catch-Up and Statistics appear with Live and go with Off; a failed read keeps the last value (existing) | `SidebarVisibilityTests.testRefreshOnLiveStatusChange` |
| Phone | the Mac sends `live` to an old phone | the raw word shows (default branch); nothing breaks | `AccountStatusStyleTests.testUnknownStatusShowsRaw` (exists in spirit; add) |

## 7. Writers of the same data and who wins

| Data | Writers | Race rule | Screen behaviour |
|---|---|---|---|
| `slack_live_status` | the probe (from the pane or the chat watcher), every chat turn or automation run that calls a connector read tool | newest `checked_at` wins (`UpsertSlackLiveStatus`, plan A) | the pane reads on appear and after each probe; it does not poll, so a chat's newer verdict shows on the next open |
| `slack_accounts` + token files | `slack login`/link connect, the refresher, `slack remove` | per-account flock (parent §5.5) | `SlackAccountsViewModel` re-reads on appear (existing) |
| The setup record | `slack app create`/`adopt`/`link`/`pending`; one run at a time (`SlackAppSetupModel.isRunning`, and the CLI takes the record's flock — T7) | the holder wins; a second run reports busy and the sheet shows "Another setup is already running on this Mac. Try again once it has finished." with **Cancel** and **Try again** (§3.2) | the pane's record row re-reads on appear and when the model's run ends |
| The app's `long_description` | the setup, and **Add the link to the app** | last write wins (parent §8); both write the same text | — |
| The connect flow | link clicks, the paste field, MDM **Connect**, Reconnect | one flow at a time (`SlackAuthFlowState`); later starts are refused while one runs | the running sheet stays |

## 8. Mockups

Design-only SwiftUI scenes in `DesignShotCatalog` (`SlackFullLiveShotFixtures`, `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+SlackFullLive.swift`), built from the design kit (`SettingsSection`, `Chip`, `.card()`, `.kit*` buttons, `Tone`) and, for the empty state, the real `FeatureEmptyState`. Every string comes from `SlackFullLiveMockCopy` (`Tests/DesignShots/SlackFullLiveMockCopy.swift`), pinned by `SlackFullLiveMockCopyTests` — including that the keep reason equals the shipped `ArtifactPanelModel.liveSlackReason` and that every frame has a shot. Rendered by `DesignShotsTests.testSlackFullLiveShotsRender` (`make desktop-shots` renders them with the rest), light and dark, committed under `docs/design/mockups/slack-full-live/` as `<shot>-light.png` / `<shot>-dark.png`. They are on branch `feature/1709-screens-spec` (next to this spec); a checkout of another branch does not have the folder. Sample data only (`acme`, made-up ids).

| Shot | State |
|---|---|
| [`slack-fl-pane-full`](../../design/mockups/slack-full-live/slack-fl-pane-full-light.png) | Full; Claude Live not connected (connectors off); **Connect another workspace…** |
| [`slack-fl-pane-fullLive`](../../design/mockups/slack-full-live/slack-fl-pane-fullLive-light.png) | Full · Live on; Codex not installed |
| [`slack-fl-pane-fullLive-narrow`](../../design/mockups/slack-full-live/slack-fl-pane-fullLive-narrow-light.png) | the same at 360 pt |
| [`slack-fl-pane-live`](../../design/mockups/slack-full-live/slack-fl-pane-live-light.png) | Live only (Codex on, team shown by id; Claude not connected), with the connect section |
| [`slack-fl-pane-liveProblems`](../../design/mockups/slack-full-live/slack-fl-pane-liveProblems-light.png) | Live; workspace not identified; Codex waiting for the Slack admin |
| [`slack-fl-pane-off`](../../design/mockups/slack-full-live/slack-fl-pane-off-light.png) | Off; Live never checked (empty) |
| [`slack-fl-pane-loading`](../../design/mockups/slack-full-live/slack-fl-pane-loading-light.png) | first status read running |
| [`slack-fl-pane-checking`](../../design/mockups/slack-full-live/slack-fl-pane-checking-light.png) | busy: **Check again** running |
| [`slack-fl-pane-probeFailed`](../../design/mockups/slack-full-live/slack-fl-pane-probeFailed-light.png) | error: the probe failed, rows kept |
| [`slack-fl-pane-readFailed`](../../design/mockups/slack-full-live/slack-fl-pane-readFailed-light.png) | error: the status read failed, **Try again** |
| [`slack-fl-pane-organization`](../../design/mockups/slack-full-live/slack-fl-pane-organization-light.png) | Off with an MDM `SlackApps` workspace |
| [`slack-fl-pane-portBusy`](../../design/mockups/slack-full-live/slack-fl-pane-portBusy-light.png) | port 18551 busy |
| [`slack-fl-pane-pasteInvalid`](../../design/mockups/slack-full-live/slack-fl-pane-pasteInvalid-light.png) | pasted text is not a link or code |
| [`slack-fl-pane-setupInstall`](../../design/mockups/slack-full-live/slack-fl-pane-setupInstall-light.png) | admin's setup not finished: **Continue setup** |
| [`slack-fl-pane-setupApproval`](../../design/mockups/slack-full-live/slack-fl-pane-setupApproval-light.png) | admin's setup waits for approval |
| [`slack-fl-pane-linkMissing`](../../design/mockups/slack-full-live/slack-fl-pane-linkMissing-light.png) | **Add the link to the app** |
| [`slack-fl-pane-setupPending`](../../design/mockups/slack-full-live/slack-fl-pane-setupPending-light.png) | the create's answer was lost: **Continue setup** (plan B Task 13 review) |
| [`slack-fl-pane-sharedApp`](../../design/mockups/slack-full-live/slack-fl-pane-sharedApp-light.png) | shared-app banner, chip and tag |
| [`slack-fl-pane-sharedApp-narrow`](../../design/mockups/slack-full-live/slack-fl-pane-sharedApp-narrow-light.png) | the same at 360 pt |
| [`slack-fl-setup-empty`](../../design/mockups/slack-full-live/slack-fl-setup-empty-light.png) | setup sheet, nothing pasted |
| [`slack-fl-setup-ready`](../../design/mockups/slack-full-live/slack-fl-setup-ready-light.png) | token pasted |
| [`slack-fl-setup-ready-narrow`](../../design/mockups/slack-full-live/slack-fl-setup-ready-narrow-light.png) | the same at 380 pt |
| [`slack-fl-setup-progress`](../../design/mockups/slack-full-live/slack-fl-setup-progress-light.png) | busy: steps |
| [`slack-fl-setup-success`](../../design/mockups/slack-full-live/slack-fl-setup-success-light.png) | done |
| [`slack-fl-setup-badToken`](../../design/mockups/slack-full-live/slack-fl-setup-badToken-light.png) | error with **Try again** |
| [`slack-fl-setup-notAllowed`](../../design/mockups/slack-full-live/slack-fl-setup-notAllowed-light.png) | the workspace forbids creating apps |
| [`slack-fl-setup-linkFailed`](../../design/mockups/slack-full-live/slack-fl-setup-linkFailed-light.png) | app works, link not written |
| [`slack-fl-setup-approval`](../../design/mockups/slack-full-live/slack-fl-setup-approval-light.png) | waiting for the admin's approval |
| [`slack-fl-setup-busy`](../../design/mockups/slack-full-live/slack-fl-setup-busy-light.png) | another setup runs (a problem body; plan B Task 13 review) |
| [`slack-fl-setup-pendingCreate`](../../design/mockups/slack-full-live/slack-fl-setup-pendingCreate-light.png) | the create's answer was lost: find the app or start again |
| [`slack-fl-setup-pendingConfirmClear`](../../design/mockups/slack-full-live/slack-fl-setup-pendingConfirmClear-light.png) | **Start again** asks to check Slack's app page first |
| [`slack-fl-setup-adopt`](../../design/mockups/slack-full-live/slack-fl-setup-adopt-light.png) | adopt: the workspace already has Watchtower's app |
| [`slack-fl-setup-adoptAppId`](../../design/mockups/slack-full-live/slack-fl-setup-adoptAppId-light.png) | adopt: the App ID is needed |
| [`slack-fl-setup-adoptNotCollaborator`](../../design/mockups/slack-full-live/slack-fl-setup-adoptNotCollaborator-light.png) | adopt: the token's owner is not a collaborator; the admin note |
| [`slack-fl-setup-adoptConfirm`](../../design/mockups/slack-full-live/slack-fl-setup-adoptConfirm-light.png) | adopt: the typed App ID's name to check |
| [`slack-fl-setup-adoptAppIdProblem`](../../design/mockups/slack-full-live/slack-fl-setup-adoptAppIdProblem-light.png) | adopt: the App ID was not taken |
| [`slack-fl-setup-addLinkEmpty`](../../design/mockups/slack-full-live/slack-fl-setup-addLinkEmpty-light.png) | Add the link: empty |
| [`slack-fl-setup-addLinkBusy`](../../design/mockups/slack-full-live/slack-fl-setup-addLinkBusy-light.png) | Add the link: busy |
| [`slack-fl-setup-addLinkError`](../../design/mockups/slack-full-live/slack-fl-setup-addLinkError-light.png) | Add the link: error with **Try again** |
| [`slack-fl-setup-addLinkDone`](../../design/mockups/slack-full-live/slack-fl-setup-addLinkDone-light.png) | Add the link: done |
| [`slack-fl-connect-confirm`](../../design/mockups/slack-full-live/slack-fl-connect-confirm-light.png) | link clicked: the confirm |
| [`slack-fl-connect-browser`](../../design/mockups/slack-full-live/slack-fl-connect-browser-light.png) | busy: finishing in the browser |
| [`slack-fl-connect-success`](../../design/mockups/slack-full-live/slack-fl-connect-success-light.png) | connected |
| [`slack-fl-connect-teamMismatch`](../../design/mockups/slack-full-live/slack-fl-connect-teamMismatch-light.png) | error: team mismatch, **Start again** |
| [`slack-fl-connect-denied`](../../design/mockups/slack-full-live/slack-fl-connect-denied-light.png) | error: denied in Slack |
| [`slack-fl-needs-full-digests`](../../design/mockups/slack-full-live/slack-fl-needs-full-digests-light.png) | `needsFullSlack` on Digests |
| [`slack-fl-needs-full-digests-narrow`](../../design/mockups/slack-full-live/slack-fl-needs-full-digests-narrow-light.png) | the same at 360 pt |
| [`slack-fl-needs-full-catchup`](../../design/mockups/slack-full-live/slack-fl-needs-full-catchup-light.png) | `needsFullSlack` on Catch-Up (visible with Live only) |
| [`slack-fl-needs-full-statistics`](../../design/mockups/slack-full-live/slack-fl-needs-full-statistics-light.png) | `needsFullSlack` on Statistics (visible with Live only) |
| [`slack-fl-needs-full-home-card`](../../design/mockups/slack-full-live/slack-fl-needs-full-home-card-light.png) | Home → Getting ready card |
| [`slack-fl-needs-full-knowledge`](../../design/mockups/slack-full-live/slack-fl-needs-full-knowledge-light.png) | the Knowledge note |
| [`slack-fl-artifact-keep-disabled`](../../design/mockups/slack-full-live/slack-fl-artifact-keep-disabled-light.png) | **shipped:** disabled Add to Knowledge, the reason as hover help |

Not mocked, by design: the About page (Slack renders it, §4.1), the overview card's one status line (§5), the phone (no Desktop catalog; text in §2.3), and the error variants that reuse a mocked layout (§3.2, §4.3).

## 9. Add to Knowledge on a Live artifact (shipped, unchanged)

Plan A shipped it (LIVE-01): in a conversation marked `live_slack_since`, the artifact panel's **Add to Knowledge** is disabled and its hover help is "Built on Live Slack answers, which are not kept" (`ArtifactPanelModel.liveSlackReason`); an earlier pin can still be removed (**Remove from Knowledge** is never blocked). A keep that races the mark is refused by `ChatArtifactQueries.keep` (`ChatArtifactKeepError.liveSlack`) and the panel then shows the same reason. Tests: `LiveSlack01GuardTests.testPanelExplainsWhyKeepIsDisabled`, `testPanelBlocksKeepButNotRemove`, `testKeepRefusedForLiveConversation`. This spec only mocks it (`slack-fl-artifact-keep-disabled`).

## 10. Promises → tasks → tests

Screen tasks (S) follow the parent plan B tasks they need.

| Promise | Task | Needs | Test |
|---|---|---|---|
| The pane shows the mode, the Live rows with their age, and every block state | S1 `SlackModePresentation` + the pane on `SettingsSection` | plan A (shipped) | `SlackModePresentationTests`, `SlackLiveStatusCenterTests` |
| **Check again** probes now, once at a time | S1 | plan A | `SlackLiveStatusCenterTests.testCheckAgainWhileRunningIsIgnored` |
| `needsFullSlack` on every Slack-dependent screen and Home | S2 readiness | plan A | `FeatureReadinessTests.testNeedsFullSlack*`, `EmptyStateCopyCoverageTests` |
| Catch-Up and Statistics stay visible with Live only and show `needsFullSlack` | S2 sidebar rule | plan A | `SidebarVisibilityTests.testLiveOnlyShowsCatchUpAndStatistics`, `testLiveDoesNotCountAsMessages` |
| The Knowledge note while Live (string + test; placed when a Knowledge search screen exists) | S2 | plan A | `SlackModePresentationTests.testKnowledgeNoteOnlyInLive` |
| The phone says "Live only" | S2 | plan A | `TestDBAccounts_LiveOnlySlackRow`, `AccountStatusStyleTests.testLiveOnly` |
| One-paste setup with progress, errors and resume | S3 `SlackAppSetupModel` + sheet + record row | T7 | `SlackAppSetupModelTests`, `TestAppSetup_*` |
| **Add the link to the app** | S3 | T7 | `SlackAppSetupModelTests.testLinkFailedOffersAddLink`, `TestAppSetup_LinkUpdateFails` |
| Link, paste and MDM connect with a confirm only for links | S4 `SlackConnectFlowModel` + sheets + connect section | T8 | `SlackConnectFlowModelTests`, `TestSlackConnectListener_*`, `TestSlackLinkConnect_*` |
| Port busy is said and has a way out | S4 | T8 | `SlackModePresentationTests.testPortBusyLine`, `TestSlackConnectListener_PortBusy` |
| A second workspace connects in Full | S4 | T8, T9 | `SlackModePresentationTests.testFullFoldsConnectSection` |
| The baked app leaves every build only after adopt can turn on PKCE (plan B Task 16 before Task 18) | plan B T16, T18 | T13 (adopt) | plan B Task 18 "Depends on: … Task 16"; `TestAdopt_*` |
| The shared-app banner, chip and tag; not an attention item | S5 | T2 (`client_id`), T9 | `SlackModePresentationTests.testSharedAppBanner`, `testSharedAppIsNotAttention`, `TestSharedAppBanner` |
| Every public release can recognise shared-app accounts; a corp-app account is Full like any company app (ask #1425) | S5 (+ `scripts/build-app.sh` guard) | T9 | `scripts/tests/test-build-app-retired-slack-id.sh`, `TestSlackAccountSharedApp_RetiredIDOnly`, `TestBackfillSlackClientIDs_*` |
| Disabled Add to Knowledge with its reason | shipped (plan A) | — | `LiveSlack01GuardTests` |
| The guide and the feature notes say all of this | S6 docs: `docs/guide/concepts/sources-and-accounts.md` (Full, Live, setup, link, banner), `docs/features/slack-live.md`, `slack-multi-account.md`, `connections-tab.md` | S1–S5 | `go test ./docs/guide` (8 KB cap) |
| Each new screen looked at before merge | S1–S5 | — | the implementation re-renders the same shot names from the real views (`DesignShotsTests.testSlackFullLiveShotsRender`) |

## 11. Decisions

### Sourced

| # | Decision | Source |
|---|---|---|
| 1 | The modes are named Full / Live in the UI | ask #1294 (parent D1) |
| 2 | Live shows next to Full ("Full · Live on"), not only alone | ask #1294, comment #866 (parent D2) |
| 3 | The screen shows the Live check's age, never a bare "on"; **Check again** probes | parent §1 (ask #1294) |
| 4 | Entry into Full is the link from the app's About page, plus the MDM key | ask #1294 (parent D4), conversation 2026-11-14 (parent D7) |
| 5 | The admin creates the app with one paste of a configuration token; never stored | ask #1295 (parent D9), parent §5.1 |
| 6 | The link asks for confirmation before anything starts; port busy offers the paste | ask #1295 (parent D8), parent §5.3 |
| 7 | No client secret anywhere; nothing depends on the admin's Mac after setup | conversation 2026-11-14 after ask #1301 (parent D13, D7) |
| 8 | A Live artifact cannot be added to Knowledge; the button says why | ask #1296 (parent D6, D10) |
| 9 | Shared-app accounts keep working with a banner offering Full or Live | ask #1295 (parent D11) |
| 10 | A screens spec with a mockup for every state, in English, strings in a view model with a test | owner's target #1779 |

### Proposed by the agent, approved by the owner (ask #1315)

All accepted in ask #1315; 2 and 19 explicitly chosen; 10 reversed by the owner (as written below).

1. Connections → Slack moves off `Form` onto `SettingsSection`s (style guide), old sections ported as they are. — ask #1315
2. A **Shared app** chip overrides the derived mode on screen (the derived mode stays; SLACKMODE-01 untouched), so a syncing account is never shown as "Off". — ask #1315 (explicitly chosen)
3. Chip tones: Full and Full · Live on green, Live blue, Off gray, Shared app orange (`Tone`). — ask #1315
4. One Live row per provider with a status row, Claude first; the provider's newest row decides; teams joined by comma. — ask #1315
5. The `status`/`error_class` → text table of §1.2, including the new reasons for `connector_id_unknown` and `sandbox`. — ask #1315
6. Age wording: "just now" / "N min" / "N h" (under 48 h) / "N d". — ask #1315
7. The center keeps its last error as a value (provider, message, kind) and gains `hasRead`; the sentence moves into the presentation, so it says "Claude", not `claude`. — ask #1315
8. Read failure offers **Try again** (reload) and hides **Check again**; a probe failure keeps **Check again** as its retry. — ask #1315
9. `needsFullSlack` is `ReadinessSource.fullSlack` inside the existing `needsSource` machinery; for "any source" features it shows only when nothing else is connected; `off` still wins. — ask #1315
10. **Reversed by the owner:** with Live only, Catch-Up and Statistics stay visible and show `needsFullSlack` (`SidebarSource.slackLive`, §2.2). — ask #1315 (reversed)
11. Knowledge gets a one-line note while the mode is Live, not a readiness state — the only narrowing of the parent's "every Slack-dependent screen" (§2.2). — ask #1315
12. The phone shows Live only as a heartbeat account row "Live only — sync needs your workspace's app"; no new phone screen; no phone mockup (no Desktop-style catalog there). — ask #1315
13. Setup and connect are sheets (short blocking flows), with their runs on `AppState` so they survive closing the sheet and switching tabs. — ask #1315
14. The setup's token goes to the CLI on stdin; the CLI reports one JSON line per step; the CLI verb names (`slack app create|link|status`) are placeholders for plan B. — ask #1315
15. The approval row shows only when Slack's callback says an install request is pending (T1 spike); otherwise "Setup is not finished". — ask #1315
16. A pasted link/code and an MDM **Connect** skip the confirm (the owner's own press); only a link that reached the listener asks. — ask #1315
17. A second connect while one runs is refused, the running sheet stays (one flow at a time, shared with Reconnect). — ask #1315
18. The listener re-tries the port bind whenever Connections → Slack opens; in Full the folded connect section opens itself while the port is busy. — ask #1315
19. In Full, **Connect another workspace…** replaces the **Add Slack Account** sheet — public build only, after T9 removes its baked client id; the corp build keeps the sheet until decided otherwise. — ask #1315 (explicitly chosen); **superseded by asks #1414/#1425**: every build once nothing bakes an app, corp included (§4.2)
20. MDM rows read "Workspace <team id>" (the key has no name) and their **Connect** is the pane's one prominent action. — ask #1315
21. The shared-app banner has no dismiss, tints with `Tone.warning`, and is not an attention item (no red badge); the overview card says "Shared app retiring". — ask #1315
22. The pane does not poll `slack_live_status`; it reads on appear and after a probe. — ask #1315
23. The UI names are English **Full** / **Live** because the Desktop is not localised; they stand for the owner's **Полный** / **Живой** (ask #1294, conversation). Code keeps `full` / `live`. — ask #1315
24. Shared-app detection is build-aware and decided in Go (`shared_app` in `slack accounts --json`): public build = the retired shared id or an empty `client_id`; corp build never. — ask #1315; **superseded by ask #1425**: one rule by client id in every build, the corp app is a company app (§1)
25. `ReadinessCenter` re-evaluates on a `SlackLiveStatusCenter` change and reads `slack_live_status` in its snapshot. — ask #1315
26. The phone's Live-only row follows `accountsSQL`'s own account rule (`status != 'removed'`), not `enabled`. — ask #1315
27. A public release refuses to build without `RETIRED_SLACK_CLIENT_ID` (`retired-slack-id-check` in `scripts/build-app.sh`); an unset id at run time narrows detection to empty `client_id` and logs once. — ask #1315; **superseded by ask #1425**: an unset id means nothing is shared, an empty `client_id` is never shared and is backfilled (A17, §1)

### Changed by later owner answers

- **A1.** Moving off the shared app re-binds the same `slack_accounts` row to the new client id, history kept, nothing soft-removed — ask #1425 «Перепривязать строку», replacing ask #1414 «Новая строка, как в спеке» (§5).
- **A2.** The corp build has no separate rules: its baked app is a company app (Full), which its admin adopts — **Set up for my company** updates an existing Watchtower app instead of creating a second one — ask #1425 (§1, §3.2 adopt, §4.2).
- **A3.** The Slack mode reads each provider's newest probe batch, in Go and in Swift — ask #1525 «Да, в обоих» (SLACKMODE-01 contract change).
- **A4.** A member who cannot create apps gets the "ask your admin" state with a ready, copyable note and the guide link — review #1426, ask #1438 (A23) (§3.2 not allowed).
- **A5.** Plan B Task 16 (adopt turns on `pkce_enabled`) ships before Task 18 retires the baked id, corp included — plan B Task 18's dependencies (§4.2).

### Approved by the owner (ask #1577, rounds #1575–#1576)

Added by plan B Task 13 and its reviews; approved by the owner in ask #1577 (2026-11-18).

- **B1.** The new §3.2 states and their copy: another run (busy), create answer lost (pending create) with **Use this app** / **Start again** and the second confirming press, adopt App ID check (`confirm_app`) and App ID problem lines, the not-collaborator state, the unmocked lines listed under §3.2, and the §3.4 `pending_create` row.
- **B2.** **Use this app** is two steps: the ids, then a fresh configuration token for the link (the pending form holds no token).
- **B3.** The add-link sheet shows **Close** while busy (closing never stops a run) (§3.3).
- **B4.** The Knowledge note ships as a string with its test only, placed when a Knowledge search screen exists (§2.2) — agent decision.

## 12. Out of scope

- Adding a connector inside Claude or ChatGPT (their own settings; the reason lines say where).
- Live on the phone (plan A v1 limit).
- Hiding Live per provider, or choosing which provider Chats use.
- The browser page the listener serves for a late callback ("start again") — it reuses `internal/oauthpage`.
- The Developer Policy hygiene items (#1769) and the legal questions (#1770).

## 13. Open

- Whether Slack's callback reports a pending install request (T1 spike) — decides whether the approval row can appear (§3.4).
- Whether Slack renders the About page link as clickable (T1) — the code is the fallback either way.
