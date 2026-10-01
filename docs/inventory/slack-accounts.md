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

**Locked since:** 2026-10-01
