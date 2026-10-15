# History backfill — a month of every new source, freshest first (2026-10-15)

Spec: `docs/superpowers/specs/2026-10-15-history-backfill-design.md`. Board target #312 (owner asks #165, #167). Contracts: BACKFILL-01..03 in `docs/inventory/history-backfill.md`.

## Summary

A fresh install stays useful in minutes: the first daemon cycle is unchanged (Slack: the onboarding depth, Gmail and IMAP: 7 days), so the first briefing, inbox and digests describe today. After that a last daemon phase walks each newly connected source back to `sync.backfill_days` (default 30; `0` turns the backfill off for sources that start afterwards), one 2-day chunk per source per cycle, newest chunk first, and runs the AI pipelines over what it brings in. `calendar.history_days` defaults to 30 (was 14) and needs no backfill: it is re-synced whole every cycle. Jira, Confluence and meetings need none either.

## What starts a backfill

Only the first sync of a source, and only through the daemon path:

- Slack: `Orchestrator.FirstSyncFrom()` (`internal/sync/search_sync.go`) is set by a completed search sync that began with no usable `search_last_date`; a rate-limited or partial first run is not a first sync.
- Gmail: `Syncer.FirstSyncFrom()` (`internal/gmail/sync.go`) — watermark 0 and the ID list call succeeded, even if the list is empty.
- IMAP: `Syncer.FirstSyncFrom()` (`internal/imap/sync.go`).

The daemon (`startHistoryBackfill`, `internal/daemon/history_backfill.go`) reads `FirstSyncFrom` after every `Run`/`Sync`, whatever it returned (the watermark may already be written when a later step errors), and inserts a row with floor = now − `backfill_days` and upper = the first sync's window start. No row when `backfill_days <= 0` or the first sync already reached the floor. The insert is `ON CONFLICT DO NOTHING`, so repeated signals are harmless and a source that already had a cursor when this shipped never gets one.

## State — `history_backfill`

Added by the history_backfill migration (`internal/db/migrations/00116_history_backfill.sql`; the number may change before the PR), mirrored in `schema.sql`. One row per `(source_kind, account_id)`, `source_kind` slack | gmail | imap:

- `floor_ts`, `upper_ts`, `reached_ts` (REAL unix): `reached_ts` starts at `upper_ts` and only moves down; at `reached_ts <= floor_ts` the row is `done` (`done_at` set).
- `status`: `running` | `paused` (auth revoked; resumes when the account is usable again) | `done` | `off` (source removed or turned off).
- `waiting`: `''` | `plan_limit` (set while the plan gate holds the row).
- `chunk_failures`, `last_error`, `started_at`, `updated_at`, `done_at`.

`AdvanceHistoryBackfill` clears failures, `last_error` and `waiting`, so a skipped chunk leaves no trace in `last_error` (the `SKIPPING` log line keeps the error). Go access: `internal/db/history_backfill.go`.

## The phase

`phaseHistoryBackfill` is last in `runSync` (after briefing and day plan), so a cycle's normal work always finishes first and the shared digest pipeline and ideas lock are never used concurrently with the forward phases. It runs when any row is `running`/`paused`, or when the one-time Slack-done hooks have not stamped yet and at least one slack row exists. `historybackfill.Runner.Step` (`internal/historybackfill/runner.go`) walks rows in id order and takes at most one chunk `[max(reached − 2 d, floor), reached)` per running source.

- **Budget.** `Step` derives a deadline context (5 minutes, `historyBackfillBudget`) used for Fetch and Process. When it expires while the parent context is alive, the chunk is held with no strike and no advance, and the Step ends. A canceled parent context (shutdown) is not a failure either.
- **Per chunk:** account check, Fetch, plan gate, Process, Advance.
- **Account check** (`Daemon.accountState`): a deleted account, a Slack account that is `removed` or disabled, or a Gmail account when Gmail is off globally (`gmail.enabled`) or per account, turns the row `off`; a revoked account pauses it and a recovered one resumes; IMAP has no enabled flag or revoked state, so only deleting the mailbox ends its row. A lookup error other than not-found reads as OK (the chunk's fetch then fails and is retried). A source with no wired syncer this cycle just waits.
- **Failures.** A Fetch or Process error records `last_error` and a strike; the third strike of the same chunk skips it (`reached_ts` moves past, `SKIPPING` logged). A restart resumes from `reached_ts`.
- **Usage.** The phase is a `pipeline_runs` row named `history-backfill`; its tokens and cost are the delta of the digest and ideas pipelines' running counters around the Step.

## Fetch per source (writes no cursor)

- **Slack** — `Orchestrator.BackfillSearch(from, to)`: `search.messages` with `after:<from−1d> before:<to+1d>` (Slack's operators are exclusive and day-granular), saved through the existing search save path (`searchAndSave(live=false)`); it touches no watermark, progress heartbeat or auth/error state, and the shared rate limiter applies. An incomplete result (rate limit, partial pages) is an error, so the chunk is retried.
- **Gmail** — `Syncer.FetchRange`: `in:inbox` between the dates, all pages, noise labels skipped, ignoring `gmail.max_messages_per_sync`; no watermark or auth state.
- **IMAP** — `Syncer.FetchRange`: `SEARCH SINCE … BEFORE …` (day-granular), uncapped, in batches of `imap.max_messages_per_sync`.
- **Gmail and IMAP rows keep the message's own date as `synced_at`** (UTC RFC3339, `backfillSyncedAt`), not "now". The inbox detector reads `synced_at` as "arrived since my cursor", so backfilled mail stays below every detector cursor and never reaches inbox detection, with no detector change (ruling R9).

## Process per kind

- **Slack** (only when digests are on): `digest.Pipeline.RunBackfillWindow(from, to)` then `RunBackfillRollups(from, to)` (daily rollup of each UTC day the chunk touches).
- **Gmail:** `ideas.Pipeline.Backfill(from, to)` — Gmail and Jira stream digests plus the consolidator over the window — under `ideas.AcquireBackfillLock`. The stage-1 streams are gated on `streams.enabled`, not on `ideas.enabled`; the consolidator keeps its own gate. A held lock is not an error: the chunk is retried next cycle.
- **IMAP:** fetch only. Mail feeds the knowledge index and the other Group-1 readers on their own; nothing else runs.

## Digest scope — chunk-scoped windows (`internal/digest/backfill.go`)

A channel can hold more than one load in a chunk and one run digests at most 25 batches, so `RunBackfillWindow` loops up to 20 passes until no channel has undigested messages in the chunk.

- A channel's window starts at the latest of the chunk start, its newest digest ending inside the chunk, what this call already considered, and the FEAT-03 fast-forward floor; the upper bound is the chunk end.
- "Considered" is an in-memory map for the call. `SetChannelDigestConsideredTS` and the forward `MAX(period_to)` mark are never moved, and backfill digests end below every forward window (BACKFILL-02). The live-edge cooldown is off.
- Muted channels and 1:1 DMs are not backfilled: they are dropped when windows are resolved (they are never digested, so keeping them would read as a pass with no progress).
- A channel whose AI call or store fails is not re-offered in later passes of the same call; once nothing else is left the call returns the failure and the chunk is retried next cycle.
- Digest and rollup prompts carry no previous context and no track context while the backfill runs (ruling R7): chunks go newest first, so an older running summary rarely exists yet, and present-day track context would leak into old windows.
- Lock contention returns incomplete without error. The returned usage is the sum of the call's own passes, never the shared counters.
- Rollups do not touch the forward rollup attempt budget.

## Plan gate

After a chunk's Fetch and before its Process, `planusage.NearLimit(plan_usage_status)` (`internal/planusage/gate.go`) is read. When the `session` (5 h) or `weekly_all` limit projects `will_hit` or `hit`, the row gets `waiting = 'plan_limit'`, the chunk is not advanced and the Step ends for this cycle; the fetch is idempotent (messages upsert), so re-fetching next cycle is harmless (BACKFILL-03). A missing, stale or unreadable status, or a malformed limits blob, does not block; the existing per-step budgets still hold. The gate sits in front of every source including IMAP, which has no AI step (ruling R6).

## Slack-done hooks (one time)

When every `slack` row is `done` or `off` and at least one is `done`, the runner calls `OnSlackDone(ctx, floor)` on each Step (floor = lowest floor of the done rows). The daemon's `onSlackBackfillDone` (`internal/daemon/history_backfill.go`) then runs:

1. `inbox.Pipeline.BackfillMentions(floor)` when `inbox.enabled` — older mentions land as items and the normal auto-archive rules close the old ones.
2. People cards over the window, `RunForWindow(floor, now)`, when `people.enabled` and `digest.enabled` (a `pipeline_runs` row `people-backfill`); the 7-day cadence is untouched.

Only when both succeed does it write the stamp `<workspace>/history_backfill_hooks_done.txt`. Until then every cycle retries (the phase keeps running while the stamp is unset and a slack row exists); once stamped the hook returns at once. A hook error is only logged.

## Memory gate

Memory extraction is oldest-first behind a timestamp watermark, so it would skip backfilled messages. While any row is `running` or `paused` (`HasActiveHistoryBackfill`), `phaseMemory` logs "waiting for the history backfill to finish" and returns. When the last row ends, memory starts from its watermark (0 on a fresh install, so it reads the whole month oldest first). A row turning `off` releases the gate (a row on a source turned off would otherwise hold memory forever). Group-1 consumers (tracks, the ideas consolidator, the knowledge index) pick the new rows up on their own next runs.

## Surfaces

- CLI: `watchtower backfill status [--json]` (`cmd/backfill.go`). The pinned `--json` shape is `{"backfills": [{source, account_id, status, waiting, days_total, days_done, last_error, started_at, done_at}]}`; the text form prints `<source> #<id>  <status>  done/total days` plus waiting and error. `days_*` are `(upper − floor)` / `(upper − reached)` in days, rounded.
- Desktop: `BackfillQueries.rows` and `BackfillProgress.line` (WatchtowerCore). The line reads "Loading history: N of M days" while any row is `running`/`paused` (summed over those rows), "Loading history paused — Claude plan limit" when any active row waits on the plan, and is hidden when every row is done/off. Two readers: the tray menu line rides on `PlanUsageCenter`'s 30 s poll (`backfillLine`), and `StatusBarView` reads it in its own 30 s reload. `FeatureReadiness` is unchanged.

## v1 limits

- Briefing, day plan, next step and catch-up describe today and are not backfilled; Gmail and IMAP inbox detection never sees backfilled mail (it would be auto-archived within days anyway); Slack mentions are backfilled by the hook.
- Existing installs and any source that already had a cursor get no backfill.
- Memory for a source connected after the memory watermark has moved does not get its older month.
- The hooks stamp is global: a Slack workspace connected later never gets the mentions/people hooks, and the stamp is written even when inbox and people are both off.
- Only the daemon path starts a backfill; the first sync of a foreground `watchtower sync` does not (a later daemon cycle sees a cursor and no first sync).
- A Gmail account whose inbox is always empty reports a first sync every cycle (the watermark stays 0); the insert-if-absent start means at most one backfill, even on an existing install.
- Re-enabling a source whose row turned `off` (Slack account re-enabled, Gmail switched back on) does not resume it; `off` is final. IMAP ends only on deleting the account.
- A skipped chunk (3 strikes) is not retried later; it shows only in the log.
- A chunk that stays over budget or over the 20-pass digest cap is resumed next cycle, so a very large workspace takes several cycles per chunk.

## Tests

- Go: `internal/historybackfill/{chunk,runner}_test.go`, `internal/db/history_backfill_test.go`, `internal/daemon/history_backfill_test.go` (start trigger, account state, hooks stamp, usage, memory release), `internal/digest/backfill_test.go`, `internal/sync/search_backfill_test.go`, `internal/gmail/fetch_range_test.go`, `internal/imap/fetch_range_test.go`, `internal/planusage/gate_test.go`.
- Swift: `Tests/Core/BackfillQueriesTests.swift`, `Tests/Core/BackfillProgressTests.swift`.
