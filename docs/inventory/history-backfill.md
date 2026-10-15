# Behavior Inventory — History backfill

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/historybackfill/`, `internal/db/history_backfill.go`,
> `internal/daemon/history_backfill.go`, `internal/digest/backfill.go`, the `FirstSyncFrom` /
> `FetchRange` / `BackfillSearch` code in `internal/sync/`, `internal/gmail/`, `internal/imap/`,
> `internal/planusage/gate.go` or `cmd/backfill.go`, read this file first. Any proposed change
> that would break a guard test or remove a contract must be raised as a question before touching code.

**Module:** `internal/historybackfill/` + `internal/db/history_backfill.go` + `internal/daemon/history_backfill.go` + `internal/digest/backfill.go` + `internal/ideas/backfill_account.go` + `internal/jira/sync.go` (`FirstSyncFrom`) + `internal/sync/search_sync.go` (`BackfillSearch`, `FirstSyncFrom`) + `internal/gmail/sync.go` + `internal/imap/sync.go` (`FetchRange`, `FirstSyncFrom`) + `internal/planusage/gate.go` + `cmd/backfill.go` + Desktop `BackfillQueries` / `BackfillProgress`
**Last full audit:** 2026-10-15

## BACKFILL-01 — Only a source's first sync starts a backfill

**Status:** Enforced

**Observable:** A history backfill row is created only from a source's first sync (Slack: a completed search sync that began with no usable watermark on an account with no stored messages, upper = local midnight of the day after its exclusive `after:` date; Gmail: watermark 0 and the ID list succeeded with at least one message, upper = when that sync started; IMAP: first sync; Jira: no project watermark before a `Sync` that left one, whatever it returned), with floor = now − `sync.backfill_days`. A source that already had a cursor never gets one, `backfill_days <= 0` creates none, a first sync that already reached the floor creates none, and a repeated signal never creates a second row or resets an existing one (insert-if-absent). A rate-limited or partial first Slack sync is not a first sync.

**Why locked:** Existing installs must be untouched, and nothing may re-digest a period that was already digested.

**Test guards:**
- `internal/daemon/history_backfill_test.go::TestStartHistoryBackfill_FromFirstSync`
- `internal/daemon/history_backfill_test.go::TestStartHistoryBackfill_OffOrAlreadyDeep`
- `internal/db/history_backfill_test.go::TestHistoryBackfill_StartIsIdempotent`
- `internal/sync/search_backfill_test.go::TestFirstSyncFrom_FreshAccountCompletedRun`
- `internal/sync/search_backfill_test.go::TestFirstSyncFrom_RateLimitedFirstRunIsNotAFirstSync`
- `internal/sync/search_backfill_test.go::TestFirstSyncFrom_IncompletePaginationIsNotAFirstSync`
- `internal/gmail/fetch_range_test.go::TestSync_FirstSyncFrom`
- `internal/gmail/fetch_range_test.go::TestSync_FirstSyncFromFalseOnListFailure`
- `internal/gmail/fetch_range_test.go::TestSync_FirstSyncFromFalseOnEmptyList`
- `internal/jira/first_sync_test.go::TestSync_FirstSyncFrom`
- `internal/daemon/history_backfill_test.go::TestPhaseJiraSync_FirstSyncStartsBackfill`
- `internal/daemon/history_backfill_test.go::TestPhaseSlackSync_FirstSyncStartsBackfill`
- `internal/daemon/history_backfill_test.go::TestPhaseMailSync_FirstSyncStartsBackfill`
- `internal/sync/search_backfill_test.go::TestFirstSyncFrom_AccountWithStoredMessagesIsNotAFirstSync`
- `internal/imap/fetch_range_test.go::TestSyncFirstSyncFrom`

**Locked since:** 2026-10-15

## BACKFILL-02 — Backfill digests never move the forward marks

**Status:** Enforced

**Observable:** `RunBackfillWindow` keeps its "considered" stamps in memory for the call and its digests end below every forward window, so the forward per-channel `MAX(period_to)` and `digest_considered_ts` marks are unchanged and the forward digest window is unaffected. A channel the AI declines to digest does not loop the pass cycle.

**Why locked:** Moving a forward mark would make the live digests skip or repeat real recent messages.

**Test guards:**
- `internal/digest/backfill_test.go::TestRunBackfillWindow_ForwardWindowUnaffected`
- `internal/digest/backfill_test.go::TestRunBackfillWindow_DeclinedChannelDoesNotLoop`

**Locked since:** 2026-10-15

## BACKFILL-03 — The plan gate holds processing, not the fetch

**Status:** Enforced

**Observable:** When the 5-hour or weekly Claude plan limit projects `will_hit` or `hit`, the runner still fetches the chunk (idempotent) but does not process or advance it: the row shows `waiting = plan_limit` and the Step ends. A missing, stale or malformed plan status does not block.

**Why locked:** The backfill must never eat the owner's plan limit, and the fetch staying idempotent is what makes waiting safe.

**Test guards:**
- `internal/historybackfill/runner_test.go::TestRunner_PlanGateHoldsChunk`
- `internal/planusage/gate_test.go::TestNearLimit`

**Locked since:** 2026-10-15

## Changelog

- 2026-10-15: file created with 3 contracts (BACKFILL-01..03), introduced by the history backfill feature (spec `docs/superpowers/specs/2026-10-15-history-backfill-design.md`).
- 2026-10-16 (final fix wave, controller rulings R19/R25): BACKFILL-01 sharpened, not weakened — the Slack upper is the day after the exclusive `after:` date (`TestFirstSyncFrom_FreshAccountCompletedRun` now expects D + 1 day), and a Gmail first sync needs a non-empty listing (new guard `TestSync_FirstSyncFromFalseOnEmptyList`; `TestSync_FirstSyncFrom` unchanged).
- 2026-10-16 (R28/R29): Jira joins BACKFILL-01 as a source (`source_kind` 'jira', `jira.Syncer.FirstSyncFrom`, new guards `TestSync_FirstSyncFrom` in `internal/jira` and `TestPhaseJiraSync_FirstSyncStartsBackfill`). The Gmail backfill's AI step is now account-scoped (`ideas.BackfillEmail`); no contract weakened.
- 2026-10-16 (R30): the Gmail upper is when the first sync started, so the first sync's own week is mined too; `TestSync_FirstSyncFrom` (gmail) now expects ≈ the sync start. Not weakened: the start conditions are unchanged.
