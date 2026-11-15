# Behavior Inventory — Channel sync exclusion (Stop syncing)

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/sync/search_sync.go` (`searchAndSave`),
> `internal/sync/message_sync.go` (`buildChannelQueue`), `internal/sync/syncagain.go`,
> `internal/db/channel_settings.go` (`SetSyncExcluded`, `SyncExcludedChannelIDs`,
> the catch-up writers) or `cmd/channels_exclude.go`, read this file first.
> Any proposed change that would break a guard test or remove a contract must be
> raised as a question before touching code.

**Module:** `internal/sync/` (every Slack save path), `internal/db/channel_settings.go`, `internal/db/migrations/00190_channel_sync_excluded.sql`, `cmd/channels_exclude.go`
**Last full audit:** 2026-11-15

## SYNCEX-01 — Stop syncing is honoured on every save path

**Status:** Enforced

**Observable:** A channel with `channel_settings.sync_excluded = 1` gets no new message rows from any Slack save path, except messages whose text mentions the account's user (`<@U…>` or `<@U…|name>`), which are stored as usual and reach the Inbox. The save paths are the forward blanket search, the mention query, resumed search pages, the deletion sweep, the history backfill (`Orchestrator.BackfillSearch`, which the daemon's history backfill and `watchtower slack backfill` both use), `sync --full`, `sync --channels` and a Sync again catch-up. The sync reads the excluded set once per run, so a change applies from the next run. A match dropped from the search is still recorded in the listing, so the live deletion diff never takes the channel's stored rows for deleted. Messages stored before the exclusion stay. The only writer of the flag is `db.SetSyncExcluded`, reached through `watchtower channels exclude|include` (the Desktop runs that CLI).

**Why locked:** Stop syncing is the owner's "what I don't need" setting (ask #1337). A path that keeps storing the channel silently undoes it, spends storage and AI work on it, and can surface it again; dropping a mention of the user would lose attention the owner asked to keep (decision 3, ask #1350).

**Test guards:**
- `internal/sync/sync_excluded_test.go::TestSYNCEX01_EveryPathHonoursExclusion` — eight subtests, one per save path (forward search, mention query, resumed search pages, deletion sweep, history backfill, `sync --full`, Sync again catch-up, `sync --channels`): each stores nothing new for the excluded channel while the same answer still stores another channel's message (the path ran). The mention query subtest stores the mention of the user.

**Locked since:** 2026-11-15 (approved by the owner in ask #1350)

## Changelog

- 2026-11-15 (adaptive Slack sync, #1709, plan `docs/superpowers/plans/2026-11-15-slack-adaptive-sync.md` Task 5): file created with SYNCEX-01, approved in ask #1350. See `docs/features/slack-adaptive-sync.md`.
