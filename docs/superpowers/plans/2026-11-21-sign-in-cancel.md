# Cancel for a waiting browser sign-in — plan

**Spec:** [`docs/superpowers/specs/2026-11-21-sign-in-cancel-design.md`](../specs/2026-11-21-sign-in-cancel-design.md) (approved, ask #1710)
**Target:** #2132 · **Umbrella branch:** `feature/oauth-sign-in-cancel`. Each task gets its own worktree and branch off the umbrella, and is merged into it locally (`git merge`) after its review and the local CI jobs pass. One PR goes from the umbrella into `main`.

Already on the umbrella:

- `SignInWaitLine` / `SignInWaitText` / `SignInWaitCancel` (`Sources/DesignKit/SignInWaitLine.swift`);
- `SignInWaitCopy` (`Sources/WatchtowerCore/Services/SignInWaitCopy.swift`);
- the mockups (`SignInWaitShotFixtures`).

The place ids (G1…C3, O1) are the spec's "Where it goes" table.

## Rules for every task

- Inner loop only: `make test-swift FILTER='<YourTests>'`, `make lint-swift` (swiftlint; `make lint-diff` checks Go only). Desktop core tests go in `Tests/Core` where they can.
- Copy comes from `SignInWaitCopy`. Colours come from `Tone` only. Views come from the kit (`SignInWaitLine` for a section, banner or card; `SignInWaitText` + `SignInWaitCancel` for an account row).
- Cancel is silent:
  - the busy flag resets at once;
  - no error is set;
  - the run's completion checks that its process (or task) is still the current one before it writes anything.
- Every test with a stub CLI reaps it (process group) in `tearDown`. No test waits on wall-clock time: drive the stub with a pipe or a semaphore.
- New `AppState` methods go into a new `AppState+<Area>.swift` file. Tasks run in parallel and must not all edit `AppState.swift`.
- Self-review against `docs/review/review-rules.md` "Swift / Desktop conventions" before hand-back.

## Task 1: Copy tests
**Depends on:** none
- `SignInWaitCopyTests` (Tests/Core): `line`, `hint` and `cancelTitle` for every static service and for a custom one (a quick connection's name).

## Task 2: Google — Re-login, Connect Calendar, Calendar banner, revoked alert (G1–G4)
**Depends on:** none
- `GoogleAccountsViewModel`:
  - `addAccount` and `relogin` completions check `authProcess === process` before they write;
  - `cancelConnect` stays;
  - new `reloginLegacyCalendar()` runs `calendar login --app-return` under the same `authProcess`/`isConnecting`;
  - a `signInAccountID: Int?` tells which row is waiting (nil = section-level or legacy).
- G1: in `GoogleConnectionDetail`, the waiting row shows `SignInWaitCancel` in place of Re-login and `SignInWaitText` under the row.
- G2: the "Connect Google Calendar" action shows `SignInWaitLine` in the Add section in place of its spinner (`CompanyAccountsSections`).
- G3: in `CalendarEventsView`, the banner's and the account-error view's Reconnect show `SignInWaitLine` while waiting.
- G4: move `Navigation.reconnectGoogleCalendar` into `AppState+CalendarReconnect.swift` (`reconnectGoogleCalendar(accountID:)`):
  - with an existing account, it calls `relogin`;
  - otherwise it calls `reloginLegacyCalendar`;
  - either way it selects `.calendar`.

  Calendar shows `SignInWaitLine` at the top while `isConnecting` and no account banner carries it. `GoogleAuthService.connect` and `cancelConnect` lose their last caller; remove them if nothing else uses them.
- Tests:
  - VM: start → busy; Cancel → idle, no error; a stale completion after a restart keeps the new run busy;
  - the legacy arguments;
  - G4 routing (account present, absent, stale id);
  - presentation of the row, banner and section.

## Task 3: Use my own Google project (G5)
**Depends on:** none
- `OwnGoogleProjectModel`:
  - keep the connect stream's `Task`;
  - `cancel()` cancels it (`CLILineStream` kills the group) and returns to the page's form state without an error;
  - a stale stream result is ignored.
- `OwnGoogleProjectPage`: `SignInWaitLine` while `phase == .checking`.
- Tests: Cancel → form, no error; stale result ignored; the page shows the line while checking.

## Task 4: Slack — Re-login and the agent card (S1, S2)
**Depends on:** none
- S1: in `SlackConnectionDetail`, the built-in route's waiting row shows `SignInWaitCancel` + `SignInWaitText`, and Cancel calls `SlackAccountsViewModel.cancelConnect`. The VM must report which account is waiting, and a cancelled run must be told apart from a failed one (a `lastRunCancelled` flag or a returned outcome).
- S2:
  - add `SlackReconnectOutcome.cancelled` (WatchtowerChat);
  - `AgentActionCard.reconnectNote` gives no note for `.cancelled`, and the card shows Reconnect Slack again;
  - while reconnecting, the card shows `SignInWaitLine` with a cancel closure. Thread it next to `reconnectSlack` through `ApprovalServices`, `MacAgentActionCard` and `ActionStripView`;
  - `AppState.cancelCardSlackSignIn` (new file `AppState+SlackCardSignIn.swift`) calls `cancelConnect`;
  - `AppState.reconnectOutcome` returns `.cancelled` for a cancelled run.
- Tests:
  - VM cancel/stale completion;
  - `reconnectOutcome` gives `.cancelled`;
  - `reconnectNote(.cancelled)` (`make chattext-test`/`chat-test` as the package needs);
  - the card shows the line while reconnecting.

## Task 5: Atlassian — Jira Re-login and Confluence access (A1, A2)
**Depends on:** none
- A1: in `JiraConnectionDetail`, the waiting row shows `SignInWaitCancel` + `SignInWaitText`, and Cancel calls `JiraAccountsViewModel.cancelConnect`. The VM reports which account is waiting.
- A2: `ConfluenceSpacesViewModel`:
  - new `cancelReconsent()` calls an injected `onCancelReconsent` (wired to `jira.cancelConnect` where `onReconsent` is wired);
  - a cancelled reconsent sets no `reconsentError`.

  `ConfluenceSpacesSection` shows `SignInWaitLine` (Atlassian) while `isReconsenting`, for Grant access and Allow editing.
- Tests: VM cancel → no error and not reconsenting; the section shows the line; the Jira row's waiting state.

## Task 6: Quick Connections and Outlook (Q1, O1)
**Depends on:** none
- Q1: in `QuickConnectionsDetail`, "Sign in again" shows `SignInWaitCancel` + `SignInWaitText` (service = the connection's name) on the connection being signed in, and Cancel calls `cancelSignIn`. The VM reports which connection is waiting.
- O1: `EmailAccountsViewModel.connectOutlook`'s completion checks `authProcess === process`.
- Tests: Q1 cancel → idle, no error; the row shows the line; O1: Cancel, connect again, the first stub exits → still busy.

## Task 7: Company — chain card, wizard check, wizard Slack step (C1–C3)
**Depends on:** none
- C1: in `CompaniesZone`, a company card whose chain runs with the sheet closed shows `SignInWaitLine` (service = the running vendor's name). Its Cancel calls `CompanyConnectFlowModel.stop()`.
- C2: `CompanySetupWizardModel`:
  - keep each `check(v)`'s `Task`;
  - `cancelCheck(v)` cancels it (the `CLILineStream` group kill) and puts the check back to not-run, with no failed line;
  - `discard()` cancels a running check too.

  `CompanySetupVendorStep` shows `SignInWaitLine` on the running check.
- C3: the wizard's Slack step shows `SignInWaitLine` while its `SlackAppSetupModel` connects, and Cancel calls `cancelConnect`.
- Tests: `stop` from the card; `cancelCheck` → not-run with no failed line, and its stale result is ignored; discard kills the check; the step's line.

## Task 8: Built views vs mockups, docs
**Depends on:** Tasks 2–7
- Add DesignShots of the built views (`sign-in-wait-built-*`) for the same states as the mockups, and compare them with `docs/design/mockups/sign-in-cancel/`. Put them in an `implemented/` folder there.
- Docs:
  - one line in the user guide's connections page: a sign-in waiting in the browser can be cancelled (`docs/guide/`, per `WRITING.md`; `go test ./docs/guide`);
  - the feature notes touched (`google-multi-account.md`, `slack-multi-account.md`, `jira-multi-account.md`, `quick-connections.md`, `company-setup.md`): one sentence each on Cancel.
- Then the umbrella gate: `make test`, `make test-swift`, `make lint-all`, `scripts/leak-check.sh`, plus every `.github/workflows/*.yml` job run locally.
