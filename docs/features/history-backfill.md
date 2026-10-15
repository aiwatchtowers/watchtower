# History backfill — a month of every new source, freshest first (2026-10-15)

Spec: `docs/superpowers/specs/2026-10-15-history-backfill-design.md`. Board target #312 (owner asks #165, #167). Contracts: BACKFILL-01..03 in `docs/inventory/history-backfill.md`.

## Summary

A fresh install stays useful in minutes: the first daemon cycle is unchanged (Slack: the onboarding depth, Gmail and IMAP: 7 days), so the first briefing, inbox and digests describe today. After that a last daemon phase walks each newly connected source back to `sync.backfill_days` (default 30; `0` starts no new backfill and pauses running ones, see below), one 2-day chunk per source per cycle, newest chunk first, and runs the AI pipelines over what it brings in. `calendar.history_days` defaults to 30 (was 14) and needs no backfill: it is re-synced whole every cycle. Jira's first sync is a full scan, so its rows need no fetch, but its month is stage-1 mined by a `jira` backfill row (R29). Confluence and meetings need none.

## What starts a backfill

Only the first sync of a source, and only through the daemon path:

- Slack: `Orchestrator.FirstSyncFrom()` (`internal/sync/search_sync.go`) is set by a completed search sync that began with no usable `search_last_date`; a rate-limited or partial first run is not a first sync. Its value is the first instant that sync covered: `after:D` is exclusive, so it is UTC midnight of D + 1 day (R19) — otherwise day D would be fetched but never digested or rolled up.
- Gmail: `Syncer.FirstSyncFrom()` (`internal/gmail/sync.go`) — watermark 0 and the ID list call succeeded with at least one message; an empty inbox has nothing to backfill (R25). Its value is when that first `Sync` started, not the start of its `newer_than` window (R30): the forward stream pass initializes the account's `ideas_email_floor` at the newest synced message (`initEmailFloor`) and never mines the first sync's own week, so the Gmail row covers `[first sync − backfill_days, first sync)` and its first chunks re-fetch that week (upserts; the own-date `synced_at` keeps it out of inbox detection) and mine it. The "first sync already reached the floor" guard therefore never fires for Gmail.
- IMAP: `Syncer.FirstSyncFrom()` (`internal/imap/sync.go`).
- Jira: `Syncer.FirstSyncFrom()` (`internal/jira/sync.go`) — no project of the account had a `jira_sync_state` watermark before the `Sync` and at least one project has one after, whatever the `Sync` returned (R32: a watermark stamped before a late error — changelog, revoked grant in sprints/releases/comments, cancel — still counts); the value is when that `Sync` started (the forward ideas Jira floor is initialized later, at the first stream pass). `phaseJiraSync` reads it after every `Sync` (R29).

The daemon (`startHistoryBackfill`, `internal/daemon/history_backfill.go`) reads `FirstSyncFrom` after every `Run`/`Sync`, whatever it returned (the watermark may already be written when a later step errors), and inserts a row with floor = now − `backfill_days` and upper = the first instant the first sync covered. No row when `backfill_days <= 0` or the first sync already reached the floor. The insert is `ON CONFLICT DO NOTHING`, so repeated signals are harmless and a source that already had a cursor when this shipped never gets one.

## State — `history_backfill`

Added by the history_backfill migration in `internal/db/migrations/`, mirrored in `schema.sql`. One row per `(source_kind, account_id)`, `source_kind` slack | gmail | imap | jira:

- `floor_ts`, `upper_ts`, `reached_ts` (REAL unix): `reached_ts` starts at `upper_ts` and only moves down; at `reached_ts <= floor_ts` the row is `done` (`done_at` set).
- `status`: `running` | `paused` (auth revoked; resumes when the account is usable again) | `done` | `off` (source removed or turned off).
- `waiting`: `''` | `plan_limit` (set while the plan gate holds the row).
- `chunk_failures`, `last_error`, `started_at`, `updated_at`, `done_at`.

`AdvanceHistoryBackfill` clears failures, `last_error` and `waiting`; after a 3-strike skip the runner then writes `last_error = "skipped <from>..<to>: <err>"` (`SetHistoryBackfillLastError`), so `backfill status` shows the skip until the next successful chunk clears it (R23). Go access: `internal/db/history_backfill.go`.

## The phase

`phaseHistoryBackfill` is last in `runSync` (after briefing and day plan), so a cycle's normal work always finishes first and the shared digest pipeline and ideas lock are never used concurrently with the forward phases. It runs when any row is `running`/`paused`, or when the one-time Slack-done hooks have not stamped yet and at least one slack row is `done` (R24: slack rows that are all `off` give the hooks nothing to do). `historybackfill.Runner.Step` (`internal/historybackfill/runner.go`) walks rows in id order and takes at most one chunk `(max(reached − 2 d, floor), reached]` per running source. Chunks are written `(from, to]` throughout: the digests cover messages after `from` up to and including `to`, and the fetches are widened to whole days around it.

- **Stop switch.** `sync.backfill_days <= 0` skips the whole phase (R20): running rows stay as they are and setting it back resumes them. Memory keeps waiting while a row is `running`/`paused`. To stop a running backfill: set `sync.backfill_days` to 0 to pause it; memory waits until the rows finish or are removed.
- **Budget.** `Step` derives a deadline context (5 minutes, `historyBackfillBudget`) used for Fetch, Process and the Slack-done hooks. When it expires while the parent context is alive, the chunk is held with no strike and no advance, and the Step ends. A canceled parent context (shutdown) is not a failure either. A source's `historybackfill.ErrHold` is held the same way (R23).
- **Per chunk:** account check, Fetch, plan gate, Process, Advance.
- **Account check** (`Daemon.accountState`): a deleted account, a Slack account that is `removed` or disabled, or a Gmail account when Gmail is off globally (`gmail.enabled`) or per account, turns the row `off`; a revoked account pauses it and a recovered one resumes; a Jira account that is `removed` or disabled, or any Jira row while `jira.enabled` is off, turns `off` too; IMAP has no enabled flag or revoked state, so only deleting the mailbox ends its row. A lookup error other than not-found reads as OK (the chunk's fetch then fails and is retried). A source with no wired syncer this cycle just waits.
- **Failures.** A Fetch or Process error records `last_error` and a strike; the third strike of the same chunk skips it (`reached_ts` moves past, `SKIPPING` logged, the skip kept in `last_error`). A restart resumes from `reached_ts`.
- **Usage.** The phase is a `pipeline_runs` row named `history-backfill`; its tokens and cost are the delta of the digest and ideas pipelines' running counters around the Step.

## Fetch per source (writes no cursor)

- **Slack** — `Orchestrator.BackfillSearch(from, to)`: `search.messages` with `after:<from−1d> before:<to+1d>` (Slack's operators are exclusive and day-granular), saved through the existing search save path (`searchAndSave(live=false)`); it touches no watermark, progress heartbeat or auth/error state, and the shared rate limiter applies. An incomplete result (rate limit, partial pages) wraps `sync.ErrBackfillIncomplete`, which the daemon's Slack source maps to `historybackfill.ErrHold`: the chunk is held for a later cycle with no strike (R23).
- **Gmail** — `Syncer.FetchRange`: `in:inbox` between the dates, all pages, noise labels skipped, ignoring `gmail.max_messages_per_sync`; no watermark or auth state.
- **IMAP** — `Syncer.FetchRange`: `SEARCH SINCE … BEFORE …` (day-granular), uncapped, in batches of `imap.max_messages_per_sync`.
- **Jira** — no fetch: the first sync is a full project scan, so every issue is stored already.
- **Gmail and IMAP rows keep the message's own date as `synced_at`** (UTC RFC3339, `backfillSyncedAt`), not "now". The inbox detector reads `synced_at` as "arrived since my cursor", so backfilled mail stays below every detector cursor and never reaches inbox detection, with no detector change (ruling R9). `updated_at` is always the write time (`UpsertGmailMessage`/`UpsertImapMessage`, R18), so the knowledge index, whose mail sources follow `updated_at`, still picks backfilled mail up; on the forward path both columns are "now".

## Process per kind

- **Slack** (only when digests are on): `digest.Pipeline.RunBackfillWindow(from, to)` then `RunBackfillRollups(from, to)` (daily rollup of each UTC day the chunk touches).
- **Gmail:** `ideas.Pipeline.BackfillEmail(accountID, from, to)` (`internal/ideas/backfill_account.go`, R28) — that account's stage-1 email digests only: it lowers only that account's `ideas_email_floor` to `from` (never raising a floor already below it), drains its pre-digests bounded by `to` (cycle cap `backfillMaxCycles`; a capped drain retries the chunk), and restores the floor to max(saved, reached). No other account, no Jira pass, no consolidator: consolidation happens in the regular ideas run (`phaseIdeas` → `Run`, id-based floors over `stream_digests`), which keeps the `ideas.enabled` gate (R17). The step is gated on `streams.enabled` and runs under `ideas.AcquireBackfillLock`; a held lock is not an error: the chunk is retried next cycle. Re-running a window re-mines it (one stage-1 call again); IDEA-05 dedups downstream.
- **Jira:** `ideas.Pipeline.BackfillJira(accountID, from, to)` — the same shape for that account's `ideas_jira_floor` and Jira stream digests (R29), same gate and lock.
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

Only when both succeed does it write the stamp `<workspace>/history_backfill_hooks_done.txt`. Until then every cycle retries (the phase keeps running while the stamp is unset and a slack row is done); once stamped the hook returns at once. A hook error is only logged. The hooks run under the runner's budget context and not at all once the rows used the budget up; while `planusage.NearLimit` holds they wait — held, no stamp, retried next Step (R21).

## Memory gate

Memory extraction is oldest-first behind a timestamp watermark, so it would skip backfilled messages. While any row is `running` or `paused` (`HasActiveHistoryBackfill`), `phaseMemory` logs "waiting for the history backfill to finish" and returns. When the last row ends, memory starts from its watermark (0 on a fresh install, so it reads the whole month oldest first). A row turning `off` releases the gate (a row on a source turned off would otherwise hold memory forever). Group-1 consumers (tracks, the ideas consolidator, the knowledge index) pick the new rows up on their own next runs.

## Surfaces

- CLI: `watchtower backfill status [--json]` (`cmd/backfill.go`). The pinned `--json` shape is `{"backfills": [{source, account_id, status, waiting, days_total, days_done, last_error, started_at, done_at}]}`; the text form prints `<source> #<id>  <status>  done/total days` plus waiting and error. `days_*` are `(upper − floor)` / `(upper − reached)` in days, rounded.
- Desktop: `BackfillQueries.rows` and `BackfillProgress.line` (WatchtowerCore). The line reads "Loading history paused — Claude plan limit" when any `running`/`paused` row waits on the plan; otherwise "Loading history: N of M days" summed over the `running` rows only, or "Loading history paused — reconnect the account" when every such row is `paused` (a revoked account, R22); it is hidden when every row is done/off. Two readers: the tray menu line rides on `PlanUsageCenter`'s 30 s poll (`backfillLine`), and `StatusBarView` reads it in its own 30 s reload, in a read of its own so a failure keeps the last line and never blanks the stats. `FeatureReadiness` is unchanged.

## v1 limits

- Briefing, day plan, next step and catch-up describe today and are not backfilled; Gmail and IMAP inbox detection never sees backfilled mail (it would be auto-archived within days anyway); Slack mentions are backfilled by the hook.
- Existing installs and any source that already had a cursor get no backfill.
- Memory for a source connected after the memory watermark has moved does not get its older month.
- The hooks stamp is global: a Slack workspace connected later never gets the mentions/people hooks, and the stamp is written even when inbox and people are both off.
- Only the daemon path starts a backfill; the first sync of a foreground `watchtower sync` does not (a later daemon cycle sees a cursor and no first sync). Likewise a manual full sync from the CLI or Settings → Sync before the daemon's first cycle writes the cursors, so that source starts no backfill (Slack, Gmail, Jira).
- Jira: issues updated between the first `Sync`'s start (the row's upper) and the moment the forward stream pass initializes the account's `ideas_jira_floor` later in the same cycle (seconds to minutes) are mined by neither (R31).
- A Jira first sync counts once any project wrote a watermark; a project that failed it and syncs later has its older issues mined only where the row has not walked yet.
- An inbox empty at first sync starts no backfill (R25). Its watermark stays 0, so the first sync that lists mail later counts as the first sync and starts one.
- Re-enabling a source whose row turned `off` (Slack account re-enabled, Gmail switched back on) does not resume it; `off` is final. IMAP ends only on deleting the account.
- A skipped chunk (3 strikes) is not retried later; it shows in the log and in `last_error` until the next successful chunk.
- A revoked account's row stays `paused` and keeps memory waiting until it is reconnected; the way out is to remove the account (its row turns `off`).
- On an API-key or Codex provider the plan gate is inert (there is no Claude plan status), so the 5-minute budget per cycle is the only brake.
- Fresh-install race (M5): a first Slack sync that ends incomplete lets memory move its watermark before the row exists, and a crash between the watermark write and the row insert leaves a source that never backfills.
- The Digests tab sorts by `created_at`, so month-old backfilled digests show on top for hours (M6).
- `days_total` reads 27–28 rather than 30 for `backfill_days=30` on Slack (it counts upper − floor, and the first sync already covered the newest days), and the Desktop line sums days across sources, so "N of M days" is not one source's month (M7).
- A chunk that stays over budget or over the 20-pass digest cap is resumed next cycle, so a very large workspace takes several cycles per chunk.

## Tests

- Go: `internal/historybackfill/{chunk,runner}_test.go`, `internal/db/history_backfill_test.go`, `internal/daemon/history_backfill_test.go` (start trigger incl. Jira, account state incl. Jira, hooks stamp and plan gate, stop switch, due rule, Gmail flags, two Gmail rows in one Step, Jira own-account process, usage, memory release), `internal/digest/backfill_test.go`, `internal/sync/search_backfill_test.go`, `internal/gmail/fetch_range_test.go`, `internal/imap/fetch_range_test.go`, `internal/planusage/gate_test.go`, `internal/ideas/backfill_test.go` (`TestBackfill_IdeasDisabledSkipsConsolidator`, CLI path), `internal/ideas/backfill_account_test.go` (`BackfillEmail`/`BackfillJira` scoping and restore), `internal/jira/first_sync_test.go`, `internal/kb/source_mail_test.go` (`TestMail_BackfilledRowsReachTheIndex`).
- Swift: `Tests/Core/BackfillQueriesTests.swift`, `Tests/Core/BackfillProgressTests.swift`.
