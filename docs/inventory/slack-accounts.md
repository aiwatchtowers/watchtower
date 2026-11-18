# Behavior Inventory — Slack accounts

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `cmd/slack.go` (`runSlackRemove`,
> `removeSlackAccount`, `rollbackSlackAccount`) or
> `internal/db/slack_accounts.go` (`SetSlackAccountRemoved`), read this file
> first. Any proposed change that would break a guard test or remove a
> contract must be raised as a question before touching code.

**Module:** `cmd/slack.go` (account removal and connect rollback), `internal/db/slack_accounts.go`
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
