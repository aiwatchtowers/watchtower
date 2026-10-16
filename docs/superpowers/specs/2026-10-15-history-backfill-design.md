# History backfill — a month of every source, freshest first (2026-10-15)

Board target #312. Owner decisions: ask #165 (process everything the backfill
brings in through the AI pipelines), ask #167 (freshest first, then depth).

## Goal

A fresh install is useful in minutes **and** knows the last month. The first
daemon cycle stays as it is today (Slack: the onboarding depth, 3 days; Gmail
and IMAP: 7 days), so the first briefing, inbox and digests describe today.
After that a background step of the daemon walks each source back to 30 days,
newest chunk first, and runs the AI pipelines over what it brings in.

Success:

- On a fresh install the first cycle takes as long as today.
- Within a few hours (workspace size and plan limits permitting) every
  backfilled source has 30 days of history, channel digests and daily rollups
  cover those 30 days, and tracks, ideas, decisions, knowledge search,
  memory and people cards have consumed them.
- The owner can see the backfill's progress and that it finished.
- The backfill never eats the owner's Claude plan limit: it pauses when the
  plan is close to a limit.

## What exists today (facts the design rests on)

| Source | First-sync depth | Cursor after the first sync |
|---|---|---|
| Slack (search sync, daemon path) | `sync.initial_history_days` (onboarding writes 3, Go default 2) | `search_last_date`, forward only |
| Gmail (per Google account) | `gmail.initial_history_days` = 7 | per-account watermark, forward only; 100 messages per cycle |
| IMAP (per account) | `imap.initial_history_days` = 7 | last UID, forward only |
| Google Calendar / CalDAV | `calendar.history_days` = 14, re-synced every cycle | none (whole window each cycle) |
| Jira | full project scan on the first sync | `jira_sync_state` |
| Confluence (`extsync`) | full space from an empty cursor | per-stream cursors |

Raising a first-sync depth later never fetches older history: every cursor
moves forward only. Consumers fall into four groups by how they find work:

1. **Pick up new rows by id / rowid / `created_at`** — they see backfilled rows
   with no change: tracks (digests by `created_at` since the last run), the
   ideas consolidator (digest id floors), the knowledge index (Slack by
   `rowid`, mail by `updated_at`, digests by `created_at`).
2. **Forward timestamp mark, time-critical** — older rows inserted later are
   invisible to them: channel digests (per-channel `period_to` /
   `digest_considered_ts`), daily rollups (current UTC day only), inbox
   detection (`inbox_last_processed_ts`), Gmail/Jira stream digests (floors by
   message time).
3. **Forward timestamp mark, not time-critical** — memory extraction
   (`ts_unix > watermark`, oldest first).
4. **About "now" only** — briefing, day plan, next step, catch-up (on demand).

Existing window-shaped entry points the backfill reuses:
`digest.Pipeline.runChannelWindows(windows, upperBound)`,
`runDailyRollupForDate(day)`, `ideas.Pipeline.Backfill(from, to)` (stage-1
Gmail/Jira stream digests plus the consolidator over a window, idempotent per
IDEA-05, behind `ideas.AcquireBackfillLock`), `inbox.Pipeline.BackfillMentions(since)`
(watermark untouched, idempotent), `guide.Pipeline.RunForWindow(from, to)`.

## Design

### Which sources backfill, and when it starts

A backfill belongs to one **source**: a Slack account, a Google account's
Gmail, or an IMAP account. It starts when that source's first sync completes
(the sync that ran with no cursor), so it covers both a fresh install and a
source connected later. A source that already had a cursor when this ships
never gets a backfill — existing installs are untouched, and nothing can
re-digest a period that was already digested.

- **Calendar** needs no backfill: `calendar.history_days` default goes from 14
  to 30. It is re-synced every cycle, so this is one constant.
- **Jira and Confluence** already take everything on their first sync.
- **Meetings** have no history to fetch.

Depth: `sync.backfill_days`, default 30; `0` turns the backfill off for
sources that start after the change. The backfill goes from the source's
first instant its first sync covered (its **upper bound**, recorded at start; for Slack the day after the exclusive `after:` date) down to
`first sync time − backfill_days` (its **floor**). A source whose first sync
already reached the floor (depth ≥ 30) gets no backfill row.

### State

Migration: one table.

```sql
CREATE TABLE history_backfill (
    id          INTEGER PRIMARY KEY,
    source_kind TEXT    NOT NULL CHECK (source_kind IN ('slack', 'gmail', 'imap')),
    account_id  INTEGER NOT NULL,
    floor_ts    REAL    NOT NULL,  -- oldest instant to reach
    upper_ts    REAL    NOT NULL,  -- the first sync's window start
    reached_ts  REAL    NOT NULL,  -- fetched and processed down to here
    status      TEXT    NOT NULL DEFAULT 'running'
                CHECK (status IN ('running', 'paused', 'done', 'off')),
    waiting     TEXT    NOT NULL DEFAULT '' CHECK (waiting IN ('', 'plan_limit')),
    chunk_failures INTEGER NOT NULL DEFAULT 0,
    last_error  TEXT    NOT NULL DEFAULT '',
    started_at  TEXT    NOT NULL,
    updated_at  TEXT    NOT NULL,
    done_at     TEXT,
    UNIQUE (source_kind, account_id)
);
```

`reached_ts` starts at `upper_ts` and only moves down. `paused` is set when the
source's auth is revoked (the existing auth-error writers) and cleared when it
is reconnected; `off` when the source is removed. `waiting = 'plan_limit'`
while the plan-limit gate holds the row (the Desktop shows it).

### The daemon phase

`phaseHistoryBackfill` runs last in `runSync`, after briefing and day plan, so
a cycle's normal work always finishes first. Per cycle it takes **one chunk per
running source**, chunk = 2 days, newest first:
`[max(reached − 2d, floor), reached)`. The phase has a wall-clock budget
(5 minutes per cycle); a source not reached this cycle waits for the next.

For each chunk:

1. **Fetch** the chunk's raw data, writing no cursor:
   - Slack: `search.messages` with `after:<A−1d> before:<B+1d>` (Slack's date
     operators are exclusive and day-granular), saved through the existing
     search-sync save path; the shared rate limiter applies.
   - Gmail: `in:inbox after:<A> before:<B>`, all pages, through the existing
     message fetch/save code, ignoring `gmail.max_messages_per_sync`.
   - IMAP: `SEARCH SINCE <A> BEFORE <B>`.
2. **Process** the chunk:
   - Slack, if digests are on: channel digests over `[A, B)` for the account's
     channels with messages in it (`runChannelWindows` with upper bound `B`),
     then daily rollups for each UTC day the chunk covers.
   - Gmail: `ideas.Backfill(A, B)` — Gmail and Jira stream digests plus the
     consolidator over the window (stage-1 streams are not gated on
     `ideas.enabled`; the consolidator keeps its own gate).
   - IMAP: fetch only (IMAP feeds the inbox detector and knowledge index;
     see "Not backfilled").
3. **Advance** `reached_ts = A`; at `reached_ts <= floor_ts` set `done`.

Once **every** Slack backfill is `done`:

- `inbox.BackfillMentions(floor)` once — older mentions land as items and the
  normal auto-archive rules (ambient after 7 days, actionable after 14) close
  the old ones on the next inbox pass.
- one people-card run over `[floor, now]` (`RunForWindow`), so the current
  cards rest on a month of signal; the normal 7-day cadence continues after it.

Group 1 consumers (tracks, ideas consolidator, knowledge index) pick up the new
digests and messages on their own next runs.

### Memory

Memory extraction is oldest-first behind a timestamp watermark, so it would
skip backfilled messages. While any backfill row is `running` or `paused`,
`phaseMemory` skips extraction (it logs once per cycle). When the last one
finishes, memory starts from its watermark — on a fresh install that is 0, so it
reads the whole month oldest first. Memory is not first-day critical, and this
needs no new memory code. A source connected later on an install whose memory
watermark has already moved does not get its older month into memory (limit,
below).

### Digest windows inside a chunk

A channel can hold more than one load (500 messages) in a chunk, and one run
digests at most 25 batches. So a chunk's digest step resolves each channel's
window like the forward path does, scoped to the chunk: start =
`max(A, the channel's newest digest period_to inside [A, B))`, upper bound `B`,
and the step repeats until no channel has undigested messages in `[A, B)` or
the phase budget runs out (the chunk then stays current next cycle). A backfill
digest's `period_to` is below every forward window, so the forward
`max(period_to)` mark is unaffected, and `SetChannelDigestConsideredTS` already
only raises its mark. The FEAT-03 fast-forward floor applies to backfill
windows like any other.

### Plan-limit gate

Before the AI steps of a chunk, the phase reads `plan_usage_status`. If the
5-hour or weekly window is `will_hit` or `hit`, the chunk's fetch still runs
but its processing waits: the chunk is not advanced and the phase stops for
this cycle. A stale or missing status (planusage off, Codex provider, an
unreadable endpoint) does not block — the existing per-step budgets still hold.
The tray/Usage surfaces already show plan usage, so the owner sees why.

### Failures

A chunk whose fetch or processing fails keeps `reached_ts`, records
`last_error`, and is retried next cycle. After 3 failures of the same chunk it
is skipped (`reached_ts` moves past it, the error stays in `last_error` and the
log) so one bad window cannot stall the month. An auth error pauses the row.
A daemon restart resumes from `reached_ts`.

### Progress and visibility

- `watchtower backfill status [--json]` lists the rows: source, days done of
  total, status, last error.
- Desktop: one line in the existing sync status area of the sidebar footer and
  the tray menu — "Loading history: 12 of 30 days" while any row runs,
  "Paused — Claude plan limit" when gated, "Loading history paused — reconnect
  the account" when every active row is paused (amended by R22; paused rows
  are not counted in N of M), gone when everything is done.
  Read from `history_backfill` (`BackfillQueries` in WatchtowerCore).
- `FeatureReadiness` is unchanged: a feature that has data stays `ready`.

## Not backfilled (v1 limits)

- Briefing, day plan, next step: they describe today.
- Gmail and IMAP inbox detection: anything older than the first-sync week would
  be auto-archived within days anyway; Slack mentions are backfilled (above).
- Existing installs and sources that already had a cursor.
- Memory for a source connected after the memory watermark moved.

## Testing

- Go: `historybackfill` package (state transitions, chunk math incl. the floor
  and day-granular Slack dates, the 3-strike skip, the plan gate with fresh,
  stale and missing status), chunk-scoped digest windows (a channel over the
  500-message load, resume after the budget cut, forward windows untouched), memory skip
  while a row runs, the start trigger (first sync creates a row, an existing
  cursor does not), migration + `TestAllTablesExist` + golden schema.
- Daemon: phase ordering (last in `runSync`), the 5-minute budget.
- Swift: `BackfillQueries` and the status line text, in `Tests/Core`.

## Docs and inventory

New `docs/features/history-backfill.md` and its CLAUDE.md line; first-run.md
and onboarding-v2.md cross-links; inventory entries for the start trigger,
"backfill digests never move forward marks" and the plan gate.
