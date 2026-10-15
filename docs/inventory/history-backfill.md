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

**Module:** `internal/historybackfill/` + `internal/db/history_backfill.go` + `internal/daemon/history_backfill.go` + `internal/digest/backfill.go` + `internal/sync/search_sync.go` (`BackfillSearch`, `FirstSyncFrom`) + `internal/gmail/sync.go` + `internal/imap/sync.go` (`FetchRange`, `FirstSyncFrom`) + `internal/planusage/gate.go` + `cmd/backfill.go` + Desktop `BackfillQueries` / `BackfillProgress`
**Last full audit:** 2026-10-15

## BACKFILL-01 — Only a source's first sync starts a backfill

**Status:** Enforced

**Observable:** A history backfill row is created only from a source's first sync (Slack: a completed search sync that began with no usable watermark; Gmail: watermark 0 and the ID list succeeded; IMAP: first sync), with floor = now − `sync.backfill_days`. A source that already had a cursor never gets one, `backfill_days <= 0` creates none, a first sync that already reached the floor creates none, and a repeated signal never creates a second row or resets an existing one (insert-if-absent). A rate-limited or partial first Slack sync is not a first sync.

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
