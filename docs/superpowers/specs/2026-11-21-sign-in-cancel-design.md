# Cancel for a waiting browser sign-in — design

**Target:** #2132 · **Branch:** `feature/oauth-sign-in-cancel` · **Mockups:** [`docs/design/mockups/sign-in-cancel/`](../../design/mockups/sign-in-cancel/README.md)

## Problem

Signing in through the browser can hang the app. If Google shows "Access blocked: the app has not passed verification" (403 `access_denied`), it never redirects back to Watchtower's loopback listener. The `watchtower … login` process then waits for its `loginTimeout` (5 minutes in every Go login: `internal/calendar/auth.go`, `internal/gmail/auth.go`, `internal/auth/oauth.go`, `internal/jira/auth.go`, `internal/linear/oauth.go`, `internal/imap/outlook_auth.go`, `internal/mcpoauth/login.go`). During that time the screen shows a spinner or greyed-out buttons and offers no way out. The Slack connect flow and the company chain's Slack step have no deadline at all.

A redirect that carries `error=access_denied` already fails at once (`internal/auth/callback.go`). Only a page that never comes back needs the owner's Cancel. No code can detect that case.

## Goal

Every place in the macOS app that starts a browser sign-in gives the owner a way out:

- While the sign-in waits, the place shows the same waiting line, with a visible **Cancel**.
- Cancel ends the sign-in process and returns the place to how it was before. A cancel is silent: it never shows an error.

The iPhone has no browser sign-ins and is out of scope.

## The waiting line

`SignInWaitLine` (DesignKit) shows:

- a small spinner;
- `line` — "Waiting for the Google sign-in in your browser…";
- `hint` — "If the page shows an error or you closed it, press Cancel.", in secondary;
- a `.kitSecondary` **Cancel**.

Account rows put the spinner and Cancel in the row's trailing slot (`SignInWaitCancel`) and the two lines under the row's title (`SignInWaitText`). All texts come from `SignInWaitCopy` (WatchtowerCore): `service` is "Google", "Slack", "Atlassian", "Linear", "Microsoft" or a quick connection's name. Colours come from `Tone` only.

States of a place that starts a sign-in:

| State | What shows | Mockup |
|---|---|---|
| idle / needs sign-in | the place's own button (Re-login, Reconnect, Grant access…) | `sign-in-wait-row-idle` |
| waiting | the waiting line. The other buttons of the same connector stay disabled, as today | `sign-in-wait-row-waiting` |
| after Cancel | the idle state again, with no error | `sign-in-wait-row-idle` |
| failed / timed out | the CLI's error under the row, as today. The place's own button is the Retry | `sign-in-wait-row-timed-out` |
| narrow (420 pt) | the lines wrap and Cancel stays visible | `sign-in-wait-row-narrow` |

There is no empty or loading state: the line exists only while a sign-in runs.

## Where it goes

The numbers follow the inventory made for #2132. Places that already have a Cancel (the Add sheets, Linear Re-login, the Calendar empty state, the Slack connect sheet, the company sheet while it is up, agent sign-in) stay as they are.

| # | Place | Starts | Cancel calls | Mockup |
|---|---|---|---|---|
| G1 | Connections → Google, account **Re-login** | `GoogleAccountsViewModel.relogin` | `GoogleAccountsViewModel.cancelConnect` | row-waiting |
| G2 | Connections → Google, **Connect Google Calendar** action | `GoogleAccountsViewModel.addAccount` | the same | section-waiting |
| G3 | Calendar health banner and account-error **Reconnect** | `GoogleAccountsViewModel.relogin` | the same | banner-waiting |
| G4 | Revoked-calendar alert **Reconnect** (`Navigation.reconnectGoogleCalendar`) | runs through `GoogleAccountsViewModel` instead of `GoogleAuthService.connect`, which no screen shows, with the same CLI command as today: `relogin` of the flagged account (`google login --account <authState.accountID>`) when the alert names one that exists, otherwise a new `GoogleAccountsViewModel.reloginLegacyCalendar` that runs today's `calendar login --app-return` (the CLI resolves account #1 itself, `resolveAccountOneForLogin`) under the same `authProcess`/`isConnecting`. The alert already switches to Calendar (`selectedDestination = .calendar`), as today — no new navigation; the Calendar health banner (G3) shows the waiting line there; when no banner of a single account is up (the legacy run), Calendar shows the same line at the top, above its content, and the empty state's own Connect (`GoogleConnectFlow`) is disabled while it runs, so two Google sign-ins never run at once | the same, in the banner or the top line | banner-waiting, calendar-top-waiting |
| G5 | **Use my own Google project** | `OwnGoogleProjectModel.connect` | new `OwnGoogleProjectModel.cancel` (cancels its stream task; `CLILineStream` kills the process group) | section-waiting |
| S1 | Connections → Slack, account **Re-login** (built-in route) | `SlackAccountsViewModel.relogin` | `SlackAccountsViewModel.cancelConnect(accountID:)` (that row's attempt only) | row-waiting |
| S2 | Chat/Inbox agent card **Reconnect Slack** | `AppState.reconnectSlack` | new `AppState.cancelCardSlackSignIn(attempt:)` → `SlackAccountsViewModel.cancelCardSignIn(attempt:)`, which ends only the attempt the card began (named apart from `SlackConnectionDetail`'s private `cancelSlackReconnect`, which cancels the legacy workspace reconnect). The card's `reconnecting` ends through a new outcome `SlackReconnectOutcome.cancelled` (WatchtowerChat). Every switch over it: `AppState.reconnectOutcome` (returns `.cancelled` when the VM reports the run was cancelled) and `AgentActionCard.reconnectNote` (`.cancelled` → no note, the card shows **Reconnect Slack** again); the card takes the screen's waiting line next to `reconnectSlack` (`ApprovalServices.reconnectSlackWaiting`, `MacAgentActionCard.reconnectSlackWait`, wired by `ActionStripView` and the chat thread from `AppState.cardSlackSignInWait`), so a card drawn again mid-sign-in still shows the line and its Cancel. The phone has no Reconnect Slack | chat-card-waiting |
| O1 | Add Outlook sheet (Cancel exists) | `EmailAccountsViewModel.connectOutlook` | `EmailAccountsViewModel.cancelConnect`; only the stale-completion fix below, no UI change | — |
| A1 | Connections → Jira, account **Re-login** | `JiraAccountsViewModel.relogin` | `JiraAccountsViewModel.cancelConnect` | row-waiting |
| A2 | Confluence **Grant Confluence access** / **Allow editing** | `ConfluenceSpacesViewModel.reconsent` / `allowEditing` | new `ConfluenceSpacesViewModel.cancelReconsent` → an injected `onCancelReconsent` → `JiraAccountsViewModel.cancelConfluenceGrant(accountID:)` (ends the flow only while it is still that site's grant) | section-waiting |
| Q1 | Quick Connections **Sign in again** | `ExternalConnectionsViewModel.signIn` | `ExternalConnectionsViewModel.cancelSignIn` (service = the connection's name) | row-waiting |
| C1 | Company card while its chain runs and the sheet is closed | `CompanyConnectFlowModel` chain | `CompanyConnectFlowModel.stop` | company-card-waiting |
| C2 | Company setup wizard, Google/Atlassian **Check by signing in** | `CompanySetupWizardModel.check` | new `CompanySetupWizardModel.cancelCheck` (keeps the check's task and cancels it; `CLILineStream` kills the process group). The check goes back to not-run | wizard-check-waiting |

No Cancel is added to the company setup wizard's Slack step: its wizard-mode `SlackAppSetupModel` has no connector and its create/adopt runs end before the admin connect (`finishSetup`), so no browser sign-in waits there (checked in the T7 review; the first inventory was wrong).

## Failure paths and races

- **Who writes the busy state.** Each view model's busy flag (`isConnecting`, `isAuthorizing`, `isBusy`, `checks[v]`, `phase`) has three writers: the start, the run's completion, and Cancel. Cancel wins: it resets the flag at once and terminates the process. The completion of a run that was cancelled must not touch the state. Each completion therefore checks that its process (or task) is still the current one (`authProcess === process`, as Jira and Linear already do). Google (`GoogleAccountsViewModel.addAccount`/`relogin`) and Outlook (`EmailAccountsViewModel.connectOutlook`) lack this check today. Without it, the old run's exit can reset a new attempt started right after Cancel. Test: Cancel, start again, let the first process exit; the second attempt is still busy.
- **The process exits as the owner presses Cancel.** `terminate()` on a finished process does nothing. The completion has already reset the state, and Cancel resets it again. Test: Cancel after the stub exited leaves idle and no error.
- **Cancel lands while the CLI is saving.** After the browser consents, Go writes in several autocommit steps (account row, grant, connection, auth state, sync switches), and each can wait on the write lock for seconds. A Cancel in that window kills it part-way. So every Cancel ends with a refresh-only re-read of what the place shows (the accounts list, the companies, the Confluence access), never `onConnected` and never a daemon restart. Whatever landed then shows: a fully saved account as connected, a half-saved one as an account that needs Re-login. Test per place: Cancel → the place's re-read ran once. A run whose CLI had already exited 0 before the Cancel arrived is a finished connect, not a cancelled one: it keeps its normal end (re-read and the daemon policy, as Jira's `cancelledAfterConnecting` does). The company chain is the one exception to "no daemon restart": its Cancel is the chain's Stop, whose existing end path re-reads every list and re-wires the daemon for the vendors connected earlier in the chain.
- **The process ignores SIGTERM.** Today no login command traps it. The `CLILineStream` paths kill the whole group with SIGKILL. No new handling.
- **The app quits mid-sign-in.** No change to how each child ends:
  - a loopback login (`google`/`jira`/`linear`/`outlook`/`slack login`, MCP) is not reaped on quit; it waits out its own 5-minute timeout and exits, its port with it;
  - the deadline-free ones end with the app: the Slack connect listener (`slack connect serve`) returns on stdin EOF (`cmd/slack_connect_serve.go`), and the company chain's children watch the chain's pipe and exit on its EOF (`watchChainParent`, `cmd/company_connect.go`);
  - a run killed before the browser consented writes nothing; one killed while saving leaves what it saved (see the previous point).
- **A failure in the middle** (the browser comes back with `error=`, or the token exchange fails): the existing error path. The error shows under the row or section, and the place's own button retries.
- **Timeout:** unchanged, an error after 5 minutes. The Slack connect flow and the company chain's Slack step keep no deadline; Cancel is their only way out.
- **Two windows show the same place** (Settings and Connections): both read the same view model, so both show the waiting line. Cancel in either ends the one run.

## Tests

- `SignInWaitCopyTests`: every text of the line for each service.
- Per place, a view-model test with a stub CLI that blocks:
  - start → busy;
  - Cancel → idle, no error, process reaped;
  - the stale completion after a restart does not reset the new run.

  Cover G1/G3 (one Google path, `relogin`), G2, G5, S1, S2, A1, A2, Q1, C1, C2 and the Outlook race (O1: Cancel, connect again, the first stub exits; still busy).
- G4: the alert's Reconnect (extracted from `Navigation` into a testable `AppState` method) calls `relogin` with the flagged account's id and selects `.calendar`; with no account id, or one that no longer exists, it runs `calendar login --app-return` through `reloginLegacyCalendar` (the stub sees those arguments), selects `.calendar`, and Calendar shows the waiting line; Cancel ends it like the others.
- S2: `AppState.reconnectOutcome` gives `.cancelled` for a cancelled run; `AgentActionCard.reconnectNote` has no note for `.cancelled` (WatchtowerChat test).
- A presentation test for each view that it shows the waiting line while busy: the row, the banner, the card and the wizard step.
- The stubs reap their process groups in `t.Cleanup`/`tearDown`. No test waits on wall-clock time.
- After implementation, the DesignShot snapshots of the built views are compared with the mockups.

## Behavior contracts

`docs/inventory/` has no entry for the paths changed here (searched for Reconnect Slack, `SlackReconnectOutcome`, the calendar alert, Re-login cancel). No guard test is touched.

## Decisions

- Cancel at every browser sign-in, in all connectors (conversation).
- One shared waiting line in DesignKit, not a per-connector variant; a silent cancel (conversation, this proposal).
- The revoked-calendar alert goes through the Google accounts view model, so there is one busy flag for Google; it keeps its current switch to Calendar (this proposal; no change the owner sees besides the new waiting line).
- The 5-minute CLI timeout stays as the backstop (conversation).
- The 403 itself is fixed outside the code: add the owner's account to the OAuth consent screen's test users, or finish verification (conversation).
