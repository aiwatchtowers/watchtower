# Behavior Inventory — Account purge on revoked access

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/purge/`,
> `internal/db/account_access.go`, `internal/db/account_purges.go`,
> `internal/db/account_purge_steps.go`, `internal/daemon/account_purge.go`,
> `cmd/accounts.go`, `WatchtowerDesktop/Sources/Services/AccountPurgeCenter.swift`
> or `WatchtowerDesktop/Sources/WatchtowerCore/Services/AccountPurgeNoticePolicy.swift`,
> read this file first. Any proposed change that would break a guard test or
> remove a contract must be raised as a question before touching code.

**Module:** `internal/purge/` (switch, scheduler, runner), `internal/db/account_access.go` (access facts), `internal/db/account_purges.go` (ledger), `internal/db/account_purge_steps.go` (step lists), migration 00146, `internal/daemon/account_purge.go` (`phaseAccountPurge`), `cmd/accounts.go` (`accounts purges`), the Desktop center and notice policy. Feature note: `docs/features/revoke-purge.md`. Board #601, spec `docs/superpowers/specs/2026-10-21-revoke-purge-design.md` (approved 2026-10-21, ask #474; plan decisions ask #477).
**Last full audit:** 2026-10-21

## PURGE-01 — Schedule and cancel

**Status:** Enforced

**Observable:** With purge on revoked access enabled, an account's data is never deleted without a notice of at least 72 hours, shown from the moment the purge is scheduled (red line in Settings → Connections, Home banner, a notification). A revoked account is scheduled due 72 h after its revocation (never sooner than 72 h after scheduling); reconnecting before then cancels it, and an account in `error` at the due time waits. When no account of a source has confirmed access for 30 days (offline time counts; disabled accounts count as accounts of their source), each account of it is scheduled, due at the 30-day mark; fresh access cancels. A removed account keeps its data on removal (SLACK-01 unchanged), and once its own last confirmed access is 30 days old it gets its own lease purge due 72 h after scheduling; adding it back, or fresh access, cancels it. Turning the purge off schedules nothing and cancels every scheduled purge; a running purge always finishes and the account ends `purged`. A `purged` account accepts only an `ok` write (a Re-login), which revives it. Off by default; on in the corporate build.

**Mechanism:** `purge.Enabled(cfg)` decides the switch, strongest first: the `policy` seam (unset until #608) > `privacy.purge_revoked_data` > `purge.BuildDefault` (ldflags, `"on"` in the corp profile) > off. The `Set*AccountAuthState` writers keep `revoked_at` (set on `revoked` when empty, cleared on `ok`, kept on `error`) and `access_ok_at` (set on `ok`), and refuse every write over a `purged` row except `ok` (`authStateWhereSQL`, `reenableOnLoginSQL`). Jira and Linear passes never write `ok` (LINEAR-03): after a nil `Sync` error the daemon calls `MarkAccountAccessOK`, which stamps `access_ok_at` only; a clean Confluence sync stamps its Jira account. `purge.Plan` reads only the account rows and the open ledger rows; every due date it sets is at least `Grace` after the pass. `purge.Apply` writes the decision; `phaseAccountPurge` runs it first in every cycle. An empty `access_ok_at` is no evidence and never schedules a lease.

**Why locked:** Deleting without the full notice, or not cancelling on a reconnect, destroys an owner's history over a password change or a provider glitch; not deleting on a real revocation leaves a company's data on a former employee's Mac, the reason the feature exists. A running purge left half-done would leave an account half-deleted and still syncing.

**Test guards:**
- `internal/purge/enabled_test.go`: `TestPurge01_EnabledOrder`.
- `internal/db/account_access_test.go`: `TestPurge01_PurgedRowAcceptsOnlyOK`.
- `internal/purge/schedule_test.go`: `TestPurge01_RevokedSchedulesAtRevokedPlusGrace`, `TestPurge01_ReconnectCancels`, `TestPurge01_ErrorStatusWaits`, `TestPurge01_LeaseSchedulesWhenAllStale`, `TestPurge01_LeaseCancelledByFreshAccess`, `TestPurge01_OffCancelsScheduledKeepsRunning`, `TestPurge01_RunningNeverCancelled`, `TestPurge01_RemovedAccountLease`, `TestPurge01_RemovedLeaseCancelledWhenReadded`.
- `internal/daemon/account_purge_test.go`: `TestLinear03_PurgeOffKeepsData`, `TestLinear03_PurgeScheduledCancelledByReconnect` (LINEAR-03's off and reconnect paths through the daemon phase).

**Locked since:** 2026-10-21

## PURGE-02 — Chunked delete and ledger

**Status:** Enforced

**Observable:** A purge deletes everything attributable to the account without AI — its raw rows, inbox items with their account-only situations and learned rules, knowledge-index documents, and the digests, tracks and people cards that belong to that account alone — and keeps AI text that mixes sources (briefings, Catch-Up recaps, ideas and decisions, memory, chats, automation outputs, transcripts), digests and tracks spanning several accounts, and calendar events tied to a recording or recap. Its sign-in files are deleted. The account row stays, `status = 'purged'`, disabled, its watermarks reset, so permalinks and labels still resolve and a Re-login starts over as a first sync. A purge never holds the database write lock for long and survives a daemon stop: it resumes where it was.

**Mechanism:** `db.PurgeSteps(source, id)` returns ordered, idempotent statements (dependents first). `RunPurgeStep` runs one transaction, one statement, at most `ChunkRows` (500) rows of the driving table; `purge.Run` repeats each step until it affects nothing, counts the rows on the ledger (`AddPurgeRows`), stops on its time budget (`purgeCycleBudget`, 5 minutes per cycle) or a cancelled context and resumes the `running` row from the top next cycle, records a failed chunk in `error`, deletes the token files outside any transaction, then `FinishAccountPurge` marks the ledger row `done` and the account `purged` (`purgedAccountSQL`) in one transaction. KB documents are deleted directly (the `messages` `kb_dirty` trigger fires on UPDATE only). Every table with an account column is covered by a step or named in `purgeKeptTables` (`imap_messages`, `account_purges`, `jira_user_map`, `linear_user_map`). The sync phases skip accounts in `purgeHold` (purged, or a purge running), so a syncer wired at startup never refills one.

**Why locked:** One big delete transaction would block every hook and the Desktop writer for its whole length (hooks give up after 500 ms / 1 s); a non-resumable purge would leave an account half-deleted after a restart; a new account-scoped table missing from the steps would silently survive every purge; deleting cross-account or AI-written rows would destroy the owner's own work.

**Test guards:**
- `internal/db/account_purge_steps_test.go`: `TestPurge02_EveryAccountTableCovered` (schema-driven: every table with an account column is purged or listed in `purgeKeptTables`), `TestPurge02_ChunkedResumable`, `TestPurge02_ScopeKeepsCrossAccount`, `TestPurge02_JiraAndLinearScope`.
- `internal/purge/run_test.go`: `TestPurge02_RunFinishesPurged`, `TestPurge02_BudgetStopsAndResumes`.

**Locked since:** 2026-10-21

## Changelog

- 2026-10-21 (board #601, asks #474 and #477): PURGE-01 and PURGE-02 written with the feature. LINEAR-03 amended in `linear.md`; SLACK-01 gains a note line only.
