# Behavior Inventory — Slack accounts

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `cmd/slack.go` (`runSlackRemove`,
> `removeSlackAccount`, `rollbackSlackAccount`),
> `internal/db/slack_accounts.go` (`SetSlackAccountRemoved`),
> `internal/slackmode/`, `internal/slackconnect/`, `internal/slackapp/`,
> `internal/slackauth/`, `cmd/slack_connect*.go` or `cmd/slack_app.go`, read
> this file first. Any proposed change that would break a guard test or remove a
> contract must be raised as a question before touching code.

**Module:** `cmd/slack.go` (account removal and connect rollback), `internal/db/slack_accounts.go`, `internal/slackmode/` (SLACKMODE-01), the Slack Full entry (SLACKFULL-01/02: `internal/slackconnect/`, `internal/slackapp/`, `internal/slackauth/`, `cmd/slack_connect.go`, `cmd/slack_connect_serve.go`, `cmd/slack_app.go`, Desktop `SlackConnectFlowModel`, `SlackAppSetupModel`)
**Last full audit:** 2026-10-01

## SLACK-01 — Removing a Slack account keeps its data

**Status:** Enforced

**Observable:** `watchtower slack remove <id>` disconnects the account and prints that its synced data was kept: the account stops syncing, and its channels, messages, digests, tracks, inbox items and memory stay queryable.

**Mechanism:** `removeSlackAccount` checks the row exists, deletes only that account's token file (`slack_token_<id>.json`, via `watchtowerslack.NewTokenStore(...).Delete`), then calls `SetSlackAccountRemoved`, which sets `status = 'removed'` and `enabled = 0` and nothing else. The `slack_accounts` row is kept for label/domain attribution of historical permalinks; there is no hard delete of Slack accounts in v1. `rollbackSlackAccount` (a connect that failed after creating its row) uses the same soft remove. This is a deliberate departure from `google remove`, which cascades. `db.ClearSlackData` (the full Slack purge) is not on this path.

**Why locked:** Routing removal through a cascading delete, or through `ClearSlackData`, would silently destroy the owner's history for a workspace they only disconnected; forgetting the token-file delete would leave a credential on disk for an account the owner believes removed. Neither failure is visible in CI without this guard.

**Test guards:**
- `cmd/slack01_test.go`: `TestSlack01_RemoveIsNonDestructive` — two accounts, data seeded under the removed account's `2:` namespace; after `runSlackRemove` the removed account's token file is gone, the other account's token file and row are unchanged, the removed row is kept as `removed`/disabled, and the row count of every table in the database is unchanged. `TestSlack01_RemoveUnknownAccountChangesNothing`, `TestSlack01_ConnectRollbackIsSoftRemove`.

**Note (2026-10-21, board #601):** revocation is not removal; SLACK-01 is unchanged and `slack remove` stays soft. A removed account's data, kept by the remove, is deleted by an enabled lease purge 30 days after its last confirmed access, after a 72 h notice (PURGE-01, `docs/inventory/account-purge.md`); with the purge off it is kept for good.

**Note (2026-11-17, #1769, ask #1412):** the data is still kept at once; with the purge on (the default) it is deleted 72 h after the first purge pass that follows the remove (a removed Slack account has a zero lease, PURGE-01). `slack remove` first revokes the account's token at Slack (`auth.revoke`, 10 s), which also signs out every other place using that sign-in; a failed revoke prints "Slack did not confirm the token was revoked; it may stay valid until a workspace admin removes the app" and the remove goes on (token file deleted, row `removed`); it is also logged on stderr with its cause, and the Desktop shows it as a notice in Connections → Slack (`SlackRevokeNotice`). Before the token delete a remove of a not-yet-removed account cancels its scheduled purge rows (`CancelScheduledAccountPurges`; a retry on a removed account keeps its row and due date, `TestSlackRemove_RetryKeepsTheRemovedAccountsPurgeRow`): a lease row scheduled while the workspace was live would otherwise keep its old due date and cut the 72 h notice. Guards: `cmd/slack_remove_test.go` `TestSlackRemove_RevokesBeforeDelete`, `TestSlackRemove_RevokeFailureStillRemoves`, `TestSlackRemove_CancelsScheduledPurge`.

**Note (2026-11-18, #1709 plan B, ask #1425):** SLACK-01 is unchanged and gains no caller. Moving an account off the retired shared Slack app to its workspace's own app re-binds the same row (new token and `client_id`, same account id and data, `writeConnectedAccount` in `cmd/slack_connect.go`); it neither soft-removes nor purges anything (`TestSlackLinkConnect_RebindKeepsHistory`). Since plan B Task 8 the token-file delete runs under the account's token flock: `removeSlackAccount` reads the token, revokes it and deletes the file (`NewTokenStore(...).Delete`) inside one `withSlackTokenLock` section, so a concurrent refresh never rewrites the file of a removed account (`TestSlackRemove_HoldsTheTokenLockThroughRevoke`, `TestSlackTokenWriters_AllLocked`). The observable behaviour and the guards above are unchanged.

**Locked since:** 2026-10-01

## SLACKMODE-01 — Go and Swift derive the same Slack mode

**Status:** Enforced

**Observable:** The app is in Full mode when a synced Slack account exists, in Live mode when there is none but the newest probe batch of any provider says `ok` (an older `ok` never outlives a newer failed check), and Off otherwise. The Desktop and the daemon always agree on which.

**Mechanism:** Go `slackmode.Derive(full, liveStatuses)` and Swift `SlackMode.derive(full:liveStatuses:)` are twins over the one fixture `internal/slackmode/testdata/slack_mode_cases.json`. Before deriving, both sides reduce `slack_live_status` to the newest probe batch of each provider — a probe writes one row per team plus team `''` at one `checked_at`; the batch is `ok` when any row in it is (Go `slackmode.NewestBatches`/`LiveVerdicts`, Swift `SlackModePresentation.liveVerdicts`/`newestBatches`); the fixture's `probes` cases pin it on both sides. Go derives the mode through `automations.SlackMode` (Full = `HasFullSlackAccount`, the Live verdicts = `slackmode.LiveVerdicts` over `slack_live_status`), which the `slack:live` event-trigger refusal at save uses (Live only: "with Live only nothing fires it"; Off: "Slack is not connected"); the chat and agent() Live rules (`cmd` `newestSlackLive`) read the same batch verdict. The probe verdicts live in `slack_live_status` (migration 00188), one row per `(team_id, provider)`, written by `UpsertSlackLiveStatus`, which keeps the newest `checked_at` and never erases a known `connector_id` with an empty one.

**Why locked:** If the two sides disagree, the Desktop shows one mode while the daemon runs another (a Live chat tool offered with no probe, or a Full sync skipped). No other test would see it.

**Test guards:**
- `internal/slackmode/mode_test.go`: `TestSlackMode_SharedFixture`.
- `internal/slackmode/batch_test.go`: `TestNewestBatches_VerdictRowPerProvider`.
- `internal/automations/slack_live_internal_test.go`: `TestSlackMode_FromAccountsAndVerdicts` (the Go caller), `TestSlackMode_NewestBatchWins`.
- `WatchtowerDesktop/Tests/Core/SlackModeFixtureTests.swift`: `SlackModeFixtureTests.testFixtureMatchesGo`.
- `internal/db/slack_live_status_test.go`: `TestUpsertSlackLiveStatus_NewestWins`, `TestUpsertSlackLiveStatus_KeepsConnectorID`.

**Locked since:** 2026-11-14

**Changelog:**
- 2026-11-18 (ask #1525, owner-approved contract change): Live is read from the newest probe batch of each provider in both Go and Swift; before, Go counted any `ok` row, so an older `ok` kept the daemon Live while the Desktop showed Off. The shared fixture gained `probes` cases (newest batch wins both ways, two providers, a same-instant batch with team `''` and team rows).

## SLACKFULL-01 — Nothing connects to Slack without the owner's press

**Status:** Enforced

**Observable:** Opening the connect link `http://127.0.0.1:18551/slack/connect?team=…&client=…` — from Slack's About page or from any web page — only brings Watchtower forward with "Connect a Slack workspace?". Nothing reaches Slack, no browser tab opens and nothing is stored until the owner presses **Connect**. A link that arrives while a flow runs starts nothing. A pasted link or code, an MDM **Connect**, Reconnect and the setup's admin connect are the owner's own press and skip the question. So is a Slack connect the connect assistant starts (`SlackConnectDriver`, agent connect spec §5.3): the owner's **Start** in the assistant panel counts as the press for that run's ordinary steps; a PKCE adopt still needs the panel's confirm card, which no tool call can answer.

**Mechanism:** The loopback listener (`internal/slackconnect` `Handler`, held by the Desktop's `slack connect serve` child or the one-shot `slack connect`) answers `/slack/connect` with the "Switch to Watchtower" page and a `link` event; `Registry.Begin(t, needsConfirm: true)` creates the flow without an authorize URL, and `Confirm` is the only way a link flow gets one (`ErrNotConfirmed` otherwise). Only `GET` on `/slack/connect` and `/callback`, `Host` exactly `127.0.0.1:18551`, no files. One flow at a time in the child (`ErrFlowRunning`) and in the Desktop (`SlackConnectFlowModel` refuses a start while anything runs and cancels an unshown link). A callback with no live flow stores nothing.

**Why locked:** Any web page can open a loopback URL. Without the confirm, a page could start an OAuth into a workspace the owner never chose and attach it to their Watchtower.

**Test guards:**
- `internal/slackconnect/server_test.go`: `TestSlackConnectListener_RequiresConfirm` (a link → one `link` event, no exchange, no browser), `TestSlackConnectListener_CallbackWithoutFlow`, `TestSlackConnectListener_RejectsOtherHostsMethodsPaths`.
- `internal/slackconnect/flow_test.go`: `TestRegistry_ConfirmRequiredForLink`, `TestRegistry_OneFlowAtATime`.
- `cmd/slack_connect_serve_test.go`: `TestSlackConnectServe_LinkConfirmConnected`, `TestSlackConnectServe_SecondStartBusy`.
- `WatchtowerDesktop/Tests/Core/SlackConnectFlowModelTests.swift`: `testLinkStartsAtConfirm`, `testSecondLinkWhileRunningIsRefused`.

**Locked since:** 2026-11-18 (approved in ask #1414, plan B A16)

**Changelog:**
- 2026-11-21 (agent connect, board #2133, **owner approved in ask #1721 Q1**): the connect assistant panel's **Start** is added to the owner's presses that skip "Connect a Slack workspace?" (it runs at most 5 starts and one flow per run, on the same `SlackConnectFlowModel`). A link that arrives from a web page still waits for **Connect**. Note only, no guard changed.

## SLACKFULL-02 — No Slack client secret or configuration token is kept

**Status:** Enforced

**Observable:** Setting up Watchtower's Slack app for a company and connecting through it leave no Slack client secret and no configuration token in any file, the database, a log line, standard output or a process's arguments. The configuration token is pasted into the setup sheet, used for that run and forgotten; the sign-in exchange and every token refresh send no secret.

**Mechanism:** `slack app create|adopt|link` read the token from the first line of standard input only (no flag; a positional argument is refused without being echoed); `SlackAppSetupModel` passes it only as stdin, holds it only while a run lasts and empties the field on submit. The `apps.manifest.create` answer is decoded into a struct with no secret field, and an exported manifest's `credentials` object is dropped (`internal/slackapp`). The PKCE exchange (`slackconnect` exchanger) and the refresher (`slackauth`) post no `client_secret`.

**Why locked:** A company's app secret on one colleague's Mac, or a 12-hour configuration token in a log, would let anyone holding that file act as the company's app. Nothing in Watchtower needs either.

**Test guards:**
- `cmd/slack_app_test.go`: `TestAppSetup_SecretNeverStored` (a fake Slack returns `client_secret`: the workspace dir, every DB table and stdout/stderr hold neither the secret nor the token), `TestAppSetup_TokenNeverInArgv`.
- `internal/slackapp`: `TestAdopt_SecretNeverStored`, `TestClient_CreateDropsTheSecret`.
- `internal/slackconnect/exchange_test.go`: `TestExchange_NoSecretInForm`; `internal/slackauth/fresh_test.go`: `TestSlackRefresh_NoSecretInForm`.
- `WatchtowerDesktop/Tests/Core/SlackAppSetupModelTests.swift`: `testTokenNeverInArgv`, `testTokenDroppedAfterRun`, `testSubmitClearsTheTokenField`.

**Locked since:** 2026-11-18 (approved in ask #1414, plan B A16)
