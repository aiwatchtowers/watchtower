# Revoked access wipes the account's data (board #601)

Goal: when a company revokes the owner's Slack, Google, Jira or Linear access,
or an install has not reached a source for 30 days, the account's synced data
deletes itself after a 72 h notice, unless the owner reconnects first. Part of
board group #595 (corporate data on the Mac). Spec:
`docs/superpowers/specs/2026-10-21-revoke-purge-design.md`, approved
2026-10-21 (ask #474) with the recommended answers: Q1 on in the corp build
(and under a future MDM policy), opt-in elsewhere; Q2 (a); Q3 72 h; Q4 30-day
lease with the same notice; the LINEAR-03 amendment.

## Global Constraints

- Inner loop only, per task: `go test ./internal/<pkg>` for the touched
  packages (plus the extra packages a task names), `make lint-diff` for Go;
  `make test-swift FILTER=<Class>` and `make lint-swift` for Swift (lint-diff is
  Go-only). The full gate (`make test`, `make test-swift`, `make lint-all`,
  `go test ./cmd/...`) runs once, by the controller, before the PR.
- Public repo hygiene (CLAUDE.md): no live-install data in tests, fixtures,
  docs or commits — `acme`, `example.com`, `<corp-workspace>` only.
- Behavior inventory: read `docs/inventory/README.md`, `linear.md`
  (LINEAR-03) and `slack-accounts.md` (SLACK-01, unchanged: `slack remove`
  stays soft) before touching account code; never weaken a guard test.
  New contracts PURGE-01/PURGE-02 are written in Task 10, their guards in the
  tasks that build the code (`TestPurge01_…`, `TestPurge02_…`).
- Write transactions stay short (CLAUDE.md, db-lock-metrics): no network, file
  I/O or token deletion inside one; every purge transaction deletes at most
  500 rows of its driving table.
- Off means off: with purge disabled nothing is scheduled and nothing is
  deleted (open rows are cancelled). LINEAR-03's existing guards keep covering
  that path.
- No MDM (#608), no "purge now" command, no export. `purge.Enabled` is the one
  seam a policy feeds later.
- Swift: read `docs/review/review-rules.md` "Swift / Desktop conventions" and
  `docs/design/desktop-style-guide.md`; build from `WatchtowerDesktop/Sources/DesignKit/`;
  pure logic in `WatchtowerCore` with tests in `Tests/Core`.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Decisions fixed by this plan

- **Sources and tables.** `source` ∈ `slack|google|jira|linear`, one per
  account table. Confluence (`ext_*` under a Jira account) is purged with its
  Jira account; its own `ext_sources.status` does not schedule anything (one
  Atlassian grant, the Jira row carries it). IMAP and CalDAV are out of scope.
- **`revoked_at`** is maintained by the `Set*AccountAuthState` writers
  themselves, so every existing writer (sync phases, `slack/google/jira/linear`
  login paths: `cmd/slack.go:165`, `cmd/google.go:484,588`,
  `cmd/jira.go:593`, `cmd/linear.go:331,484`) is covered without new calls:
  `revoked` sets it when empty (kept on a repeat), `ok` clears it, `error`
  keeps it.
- **`access_ok_at`** is set by the same writers on `ok` (Slack and Google
  write `ok` after a clean sync: `internal/sync/orchestrator.go:265`,
  `internal/gmail/sync.go:310`, `internal/calendar/sync.go:233`). Jira and
  Linear passes never write `ok` (LINEAR-03), so the daemon calls a separate
  `db.MarkAccountAccessOK` after a nil `Sync` error — it touches
  `access_ok_at` only, never `status`.
- **Schedule.** Revoked: a row is scheduled as soon as an account is
  `revoked` (the notice must show during the grace period), with
  `due_at = revoked_at + 72h`. Lease: for a source whose live accounts (status
  not `removed`/`purged`) all have `access_ok_at` older than
  `30d − 72h`, every live account of it gets a row with
  `due_at = max(access_ok_at) + 30d`. Disabled-but-not-removed accounts count
  (owner decision, ask #477). An empty `access_ok_at` is no evidence of
  staleness: a source with any live account whose `access_ok_at` is empty is
  never lease-scheduled. Removed (ask #477): a `removed` account whose
  `access_ok_at` is non-empty and older than 30 days gets its own row
  (`reason = 'lease'`) with `due_at = now + 72h`; removed accounts are not
  part of their source's live set.
- **Cancel.** A scheduled revoked row is cancelled when the account's status is
  `ok`. A scheduled lease row is cancelled when the source's
  `max(access_ok_at) + 30d` moves past the row's `due_at`. A scheduled lease
  row of a removed account is cancelled when its `access_ok_at` is fresh
  again (younger than 30 days) or the account is no longer `removed` (it
  joined the live set again; the source rule then applies). Every scheduled row
  is cancelled when purge is turned off. A `running` row is never cancelled: it
  finishes and the account ends `purged`.
- **Run.** A due revoked row runs only if the account is still `revoked`
  (an `error` status waits — it is "not still revoked on the latest attempt",
  and not proof of access either). A due lease row re-checks staleness (the
  removed-account rule for a removed account).
- **After a purge** the account row stays with `status = 'purged'`, `error`
  cleared, `enabled = 0` (Google: `gmail_enabled = 0, calendar_enabled = 0`),
  its token files deleted, its `history_backfill` rows deleted. A purged row
  accepts only an `ok` write (a later Re-login), which re-enables it and starts
  over as a first sync.
- **Setting.** Config key `privacy.purge_revoked_data` (tri-state: absent =
  build default). Effective value: policy (seam, unset today) > config key >
  build default `purge.BuildDefault` (ldflags, `"on"` in the corp profile).
  Desktop reads the effective value and its origin from
  `watchtower accounts purges --json`, so the rule lives in Go only.
- **Notifications** are sent by the Desktop (a center observing
  `account_purges`), once per row per state (`scheduled`, `done`), deduped in
  `UserDefaults` — the `PlanUsageCenter` precedent.

## Task 1: Migration — access facts and the purge ledger

Depends on: none.

Follow `.claude/skills/add-migration`. Next free number: `00147` (last is
`00146_automation_run_replay.sql`; renamed from 00146 at the merge with main) — recheck before naming.

- `internal/db/migrations/00147_account_purge.sql`, Up:
  - `ALTER TABLE {slack,google,jira,linear}_accounts ADD COLUMN access_ok_at TEXT NOT NULL DEFAULT ''`
    and `ADD COLUMN revoked_at TEXT NOT NULL DEFAULT ''`.
  - Backfill so an upgrade starts every clock at the upgrade, never in the
    past: `UPDATE <t> SET access_ok_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')` for
    every row, removed ones included (ask #477: a removed account's lease
    clock starts at the upgrade too);
    `UPDATE <t> SET revoked_at = <now> WHERE status = 'revoked'`.
  - Ledger:
    ```sql
    CREATE TABLE IF NOT EXISTS account_purges (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        source       TEXT NOT NULL CHECK (source IN ('slack','google','jira','linear')),
        account_id   INTEGER NOT NULL,
        reason       TEXT NOT NULL CHECK (reason IN ('revoked','lease')),
        scheduled_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
        due_at       TEXT NOT NULL,
        state        TEXT NOT NULL DEFAULT 'scheduled'
                     CHECK (state IN ('scheduled','running','done','cancelled')),
        started_at   TEXT NOT NULL DEFAULT '',
        finished_at  TEXT NOT NULL DEFAULT '',
        rows_deleted INTEGER NOT NULL DEFAULT 0,
        error        TEXT NOT NULL DEFAULT ''
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_account_purges_open
        ON account_purges(source, account_id) WHERE state IN ('scheduled','running');
    ```
    No foreign key: four parent tables, and the row must outlive nothing.
  - Down: drop the index and table, `DROP COLUMN` the eight columns.
- `status` has no CHECK on any of the four tables (verified in
  `internal/db/schema.sql`), so `purged` needs no table recreation; update the
  four `-- ok | error | revoked | removed` comments to add `purged`.
- Mirror into `internal/db/schema.sql` (columns with comments, the ledger with
  a "see 00147" header), add `account_purges` to `TestAllTablesExist`
  (`internal/db/db_test.go`), regenerate
  `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`.
- Tests (`internal/db`): migration backfill (an `ok` account gets
  `access_ok_at`, a `removed` one too, a `revoked` one gets `revoked_at`);
  the open-row unique index refuses a second scheduled row for one account and
  allows one after `done`.

## Task 2: Access facts writers

Depends on: Task 1.

- `internal/db/{slack,google,jira,linear}_accounts.go`: `Set*AccountAuthState`
  (`slack_accounts.go:157`, `google_accounts.go:129`, `jira_accounts.go:151`,
  `linear_accounts.go:130`) write, in their single UPDATE:
  - `revoked_at = CASE WHEN ?status='revoked' THEN CASE WHEN revoked_at='' THEN <now> ELSE revoked_at END WHEN ?status='ok' THEN '' ELSE revoked_at END`;
  - `access_ok_at = CASE WHEN ?status='ok' THEN <now> ELSE access_ok_at END`;
  - purged guard: `WHERE id = ? AND (status != 'purged' OR ?status = 'ok')`, and
    on `ok` over `purged` also `enabled = 1` (Google: leave the two switches as
    the login path sets them). A refused write is not an error (0 rows on a
    purged row returns nil; a missing row still errors — distinguish with an
    `EXISTS` check or a second statement).
  - Keep one shared SQL fragment (`authStateSetSQL`) in a new
    `internal/db/account_access.go`, not four copies.
- `internal/db/account_access.go`: `func (db *DB) MarkAccountAccessOK(source string, id int64) error`
  — `UPDATE <table> SET access_ok_at = <now> WHERE id = ? AND status != 'purged'`,
  table from a fixed `source → table` map (unknown source = error; no string
  building from input).
- `internal/daemon/daemon.go`: `phaseJiraSync` (~953) and `phaseLinearSync`
  (~1038) call `d.db.MarkAccountAccessOK("jira"|"linear", s.AccountID())` on a
  nil `Sync` error, next to `anyClean = true`. First verify that a nil return
  implies at least one authenticated request in `jira.Syncer.Sync` /
  `linear.Syncer.Sync`; if a pass can return nil without a request (no boards /
  teams selected), mark only when it made one and say so in the code comment.
  The LINEAR-03 rule "a nil error never writes a blanket ok" stays true —
  `status` is untouched.
- Tests: `internal/db` table tests per source — revoked sets once and keeps on
  repeat, error keeps, ok clears and stamps `access_ok_at`, `purged` refuses
  `error`/`revoked` and accepts `ok` (re-enables):
  `TestPurge01_PurgedRowAcceptsOnlyOK`. `internal/daemon`: a clean Linear/Jira
  pass stamps `access_ok_at` and leaves `status`; extend
  `TestLinear03_RevokedMarksAccount` only by an extra assertion that
  `revoked_at` is set (no assertion removed).
- Run also: `go test ./internal/sync ./internal/gmail ./internal/calendar ./cmd -run 'Slack|Google|Jira|Linear'`
  (their auth-state tests read these rows).

## Task 3: Enabled seam, config key and the corp build default

Depends on: none.

- New package `internal/purge`, file `enabled.go`:
  - `var BuildDefault = ""` (set by ldflags; `"on"` = on).
  - `type Origin string` = `"policy" | "setting" | "build" | "default"`.
  - `func Enabled(cfg *config.Config) (bool, Origin)`: `policy()` first (a
    package var `policy = func() (on, set bool) { return false, false }` — the
    #608 seam, commented as such), then `cfg.Privacy.PurgeRevokedData` when
    non-nil, then `BuildDefault == "on"`, else `false, "default"`.
  - Constants `Grace = 72 * time.Hour`, `Lease = 30 * 24 * time.Hour`,
    `ChunkRows = 500`.
- `internal/config/config.go`: `Privacy PrivacyConfig \`mapstructure:"privacy"\``
  with `PurgeRevokedData *bool \`mapstructure:"purge_revoked_data"\`` — no
  `SetDefault` (absent must stay nil). Verify viper leaves a `*bool` nil when the
  key is absent and sets it for `true`/`false` (config test).
- Build: `Makefile` — `PURGE_DEFAULT ?= $(WATCHTOWER_PURGE_DEFAULT)`, add
  `WATCHTOWER_PURGE_DEFAULT` to the `export` line (23), and
  `-X watchtower/internal/purge.BuildDefault=$(PURGE_DEFAULT)` in `LDFLAGS`
  (36). `scripts/build-app.sh` — `PURGE_DEFAULT="${WATCHTOWER_PURGE_DEFAULT:-}"`
  next to the client ids (~254) and the same `-X` in its ldflags (265). The corp
  profile file (`.env.<corp>`, not in the repo) gets
  `WATCHTOWER_PURGE_DEFAULT=on`; document that line in the feature note, not
  the profile itself.
- Tests (`internal/purge`): `TestPurge01_EnabledOrder` — policy > setting >
  build > default, a setting `false` beats build `on`.

## Task 4: Ledger reads/writes and the scheduler

Depends on: Task 1, Task 3.

- `internal/db/account_purges.go`:
  - `type AccountPurge struct` (all ledger columns) and
    `type PurgeAccount struct { Source string; ID int64; Label string; Status string; Enabled bool; AccessOKAt, RevokedAt string }`.
  - `ListPurgeAccounts() ([]PurgeAccount, error)` — one `UNION ALL` over the
    four tables, every status (removed accounts take part in the lease, ask
    #477; labels via the existing label columns).
  - `ScheduleAccountPurge(source, id, reason, dueAt)` — `INSERT … ON CONFLICT DO NOTHING`
    on the open-row index; returns whether a row was inserted.
  - `CancelAccountPurge(id)` (only `state='scheduled'`), `CancelAllScheduledPurges()`,
    `ListAccountPurges(openOnly bool)` (newest first),
    `UpdateAccountPurgeDue(id, dueAt)` is NOT added — a changed due date means
    cancel and reschedule (simpler, one rule).
- `internal/purge/schedule.go`: pure
  `func Plan(accounts []db.PurgeAccount, open []db.AccountPurge, enabled bool, now time.Time) Actions`
  returning `{Schedule []ScheduleItem; Cancel []int64; Due []db.AccountPurge}`
  per the "Schedule / Cancel / Run" decisions above. No DB access in `Plan`.
  `func Apply(ctx, d *db.DB, enabled bool, now time.Time) (Actions, error)` reads
  the two lists, calls `Plan`, writes the cancels and schedules (each its own
  short statement), returns `Due` for Task 6.
- Tests (`internal/purge`, table-driven over `Plan`, plus one `Apply` on a
  temp DB): `TestPurge01_RevokedSchedulesAtRevokedPlusGrace`,
  `TestPurge01_ReconnectCancels` (status `ok` cancels a scheduled row),
  `TestPurge01_ErrorStatusWaits` (due + status `error` → not in `Due`, not
  cancelled), `TestPurge01_LeaseSchedulesWhenAllStale` (one fresh account of
  the source blocks it), `TestPurge01_LeaseCancelledByFreshAccess`,
  `TestPurge01_OffCancelsScheduledKeepsRunning`, `TestPurge01_RunningNeverCancelled`,
  `TestPurge01_RemovedAccountLease` (a removed account stale for 30 days is
  scheduled at now + 72 h, a fresh one is not, and a removed account never
  blocks or joins its source's live lease),
  `TestPurge01_RemovedLeaseCancelledWhenReadded`.

## Task 5: Chunked purge executor

Depends on: Task 1. (Parallel with Task 4: separate files
`internal/db/account_purge_steps.go` and `internal/purge/run.go`.)

- `internal/db/account_purge_steps.go`:
  - `type PurgeStep struct { Name string; SQL string; Args []any }` — each SQL
    deletes (or updates) at most `?limit` rows via
    `WHERE rowid IN (SELECT rowid FROM <t> WHERE <scope> LIMIT ?)`
    (or the PK for `WITHOUT ROWID` tables); idempotent, so a crashed purge
    simply restarts its list.
  - `func PurgeSteps(source string, accountID int64) ([]PurgeStep, error)`, the
    heaviest tables first and dependents before parents. Scope per source
    (verify every column name against `schema.sql`; Slack ids are
    `<acct>:<raw>`, prefix `<acct>:`):
    - **slack**: `messages` by `channel_id` (FTS follows via `messages_ad`);
      `reactions`, `files`, `sync_state`, `watch_list`, `channel_settings`,
      `user_checkpoints`, `custom_emojis`, `user_interactions`,
      `issue_slack_links`, `reaction_events`/reaction-command ledgers by their
      namespaced column; `inbox_items` of Slack trigger types whose
      `channel_id` has the prefix (not `channel_id='memory'`), preceded by the
      situations whose every signal is such an item and by `feedback` on the
      deleted ids; `inbox_learned_rules` with `scope_key` `channel:<acct>:%` /
      `sender:<acct>:%`; digests with `channel_id` in the namespace (children
      cascade) and their `feedback`; `tracks` whose `channel_ids` is non-empty
      and every `json_each` value has the prefix (children cascade);
      `people_cards`, `people_card_summaries`, `user_analyses` by `user_id`;
      then `users`, `channels`. Cross-channel digests (`channel_id=''`) and
      cross-account tracks stay. Take the table list from `ClearSlackData`
      (`internal/db/slack_purge.go`) and scope each entry; `ClearSlackData`
      itself is not changed.
    - **google**: `gmail_messages` by `account_id`; Gmail `inbox_items`
      (`GmailChannelPrefix`, situations and learned rules as in
      `ClearGmailData`, `internal/db/gmail.go:79`); calendar events and
      calendars by `purgeGoogleAccountCalendarsTx`'s rules
      (`internal/db/calendar.go:400`: events linked to a transcript/recap are
      kept, their calendar detached) — reshape into chunked steps sharing its
      predicates (extract the predicates as constants; keep that function's
      behaviour for `DeleteGoogleAccount`); calendar inbox items of the
      deleted events.
    - **jira**: every table with `account_id REFERENCES jira_accounts` (issues,
      comments, changelog, links, boards, sprints, releases, sync state, …),
      `ext_sources WHERE jira_account_id = ?` children first (the account's
      Confluence pages), Jira inbox items attributable to the account (verify
      how `jira_*` triggers encode it; an unattributable type is kept and
      listed in the feature note).
    - **linear**: every table with `account_id REFERENCES linear_accounts`,
      Linear inbox items by their account attribution.
    - **all**: `kb_documents` whose `id` starts with the source's per-account
      key prefix (`slack:thread:<acct>:`, `slack:day:<acct>:`,
      `gmail:<acct>:`, `jira:<acct>:`, `linear:<acct>:`, `confluence:<ext source>:`
      — verify each in `internal/kb/source_*.go`); `kb_chunks` cascade and
      `kb_fts` follows `kb_chunks_ad`. Delete directly: the `kb_dirty` trigger
      on `messages` fires on UPDATE only (migration 00139), so a DELETE would
      leave Slack documents behind. Also their `kb_dirty` rows, and
      `history_backfill` rows of the account.
  - `RunPurgeStep(ctx, step PurgeStep, limit int) (int64, error)` — one
    `BEGIN IMMEDIATE` transaction, one statement, returns rows affected.
  - Ledger transitions: `StartAccountPurge(id)` (`scheduled → running`,
    `started_at`), `AddPurgeRows(id, n)`, `FinishAccountPurge(id, source, accountID)`
    (one tx: ledger `done` + `finished_at`, account row `status='purged'`,
    `error=''`, disable as in Decisions), `FailAccountPurge(id, err)` (keeps
    `running`, records `error`; the next cycle resumes).
- `internal/purge/run.go`: `func Run(ctx, d *db.DB, workspaceDir string, p db.AccountPurge, budget time.Duration) (done bool, err error)`:
  start (if scheduled) → for each step loop `RunPurgeStep` until 0 rows,
  `AddPurgeRows` per chunk, stop at `budget` or `ctx` (returns `done=false`,
  resumes next cycle) → delete the token files outside any transaction
  (`slack.NewTokenStore(dir, id).Delete()`; Google
  `calendar.NewAccountTokenStore`, `calendar.NewCredentialStore`, the Gmail
  token store; `jira`/`linear` token stores — `linear` under its token lock;
  mirror the `remove` commands in `cmd/`; a missing file is fine) →
  `FinishAccountPurge`. No remote revoke call (the grant is already dead, or
  there is no network).
- Tests:
  - `internal/db`: `TestPurge02_EveryAccountTableCovered` — schema-driven:
    every table with a foreign key to one of the four account tables
    (`pragma_foreign_key_list`) appears in `PurgeSteps` of its source or in an
    explicit `purgeKeptTables` list with a reason; fails when a later
    migration adds an account-scoped table and forgets the purge.
  - `internal/db`: `TestPurge02_ChunkedResumable` — 1 200 messages of account
    1 and 10 of account 2: each `RunPurgeStep` deletes ≤ 500, a restart after a
    partial run completes, account 2 untouched (messages, FTS hits, KB docs).
  - `internal/db`: `TestPurge02_ScopeKeepsCrossAccount` — a cross-channel
    digest, a track spanning two accounts and a transcript-linked calendar
    event survive; account-only digest/track/people card are gone.
  - `internal/purge`: `TestPurge02_RunFinishesPurged` (row `purged`,
    `enabled=0`, token files gone, ledger `done` with `rows_deleted`),
    `TestPurge02_BudgetStopsAndResumes`.

## Task 6: Daemon phase

Depends on: Task 2, Task 4, Task 5.

- `internal/daemon/account_purge.go`: `func (d *Daemon) phaseAccountPurge(ctx context.Context)`,
  called first in `runSync` (`internal/daemon/daemon.go:509`, before
  `phaseSlackSync`): `on, _ := purge.Enabled(d.config)`;
  `actions, err := purge.Apply(ctx, d.db, on, time.Now())`; if `on`, run each
  `Due` row with `purge.Run(…, budget = 5 * time.Minute total per cycle)`;
  log one line per scheduled/cancelled/finished row. Errors are logged, never
  abort the cycle.
- Skip purged and purging accounts in the sync fan-out: the phase keeps
  `d.purgeHold map[string]map[int64]bool` (accounts with a `running` row or
  status `purged`), and `phaseSlackSync`/`phaseGmailSync`/`phaseCalendarSync`/
  `phaseJiraSync`/`phaseLinearSync` skip a syncer whose account is held. This
  stops a syncer that was wired at daemon start from re-filling a purged
  account (the `Set*AccountAuthState` guard from Task 2 already keeps its
  status `purged`).
- Tests (`internal/daemon`): phase with purge off writes nothing and cancels
  open scheduled rows; with purge on a due revoked account is purged and its
  syncer skipped on the same cycle; `TestLinear03_PurgeOffKeepsData` (revoked
  for > 72 h with purge off: every `linear_*` row stays) and
  `TestLinear03_PurgeScheduledCancelledByReconnect`.

## Task 7: CLI `watchtower accounts purges`

Depends on: Task 3, Task 4.

- `cmd/accounts.go`: top-level `accounts` command (none exists today; the
  per-source `accounts` subcommands stay) with `purges [--json]`. Text: one
  line per row — source, account label, reason, state, due/finished date,
  rows deleted, error — plus a header line `Purge on revoked access: on (corp build)`.
- `--json`, pinned keys (one object):
  `{"enabled": bool, "enabled_by": "policy|setting|build|default", "grace_hours": 72, "lease_days": 30, "purges": [{"id", "source", "account_id", "account_label", "reason", "state", "scheduled_at", "due_at", "started_at", "finished_at", "rows_deleted", "error"}]}`,
  newest first, every row (not only open ones).
- Tests (`cmd`): `TestAccountsPurgesJSONKeys` pins the key set; text output for
  an empty ledger. Run `go test ./cmd -run AccountsPurges`.

## Task 8: Desktop core — models, queries, notice policy

Depends on: Task 1.

All in `WatchtowerDesktop/Sources/WatchtowerCore/`, tests in `Tests/Core`.

- Models: add `accessOkAt`/`revokedAt` (decode `''` as nil) to
  `SlackAccount`, `GoogleAccount`, `JiraAccount`, the Linear account model; add
  `isPurged` next to each `isRevoked`; grep every Swift `status` switch over
  these models and handle `purged` (shown as "Data deleted", never as healthy).
- `Models/AccountPurge.swift` (GRDB record over `account_purges`) and
  `Database/Queries/AccountPurgeQueries.swift`: `open(db)` (scheduled/running)
  and `recent(db, since:)` (done within 7 days), joined to the account label.
- `Services/AccountPurgeNoticePolicy.swift` (pure): the red-line text
  "Access to <account> was revoked. Its data will be deleted on <date> unless you reconnect."
  (lease: "Watchtower has not reached <source> since <date>. …"), the done line
  "<account>'s data was deleted on <date>.", and
  `notices(rows:, sent: Set<String>) -> [Notice]` deduping on
  `"<id>:scheduled"` / `"<id>:done"`.
- `AccountPurgeStatus` decoder for the Task 7 JSON (`enabled`, `enabled_by`,
  `purges`) — the setting's state comes from Go, no Swift copy of the rule.
- Tests: `AccountPurgeQueriesTests`, `AccountPurgeNoticePolicyTests` (dedupe,
  revoked vs lease copy, date formatting in a fixed zone),
  `AccountPurgeStatusDecodingTests` against a pinned JSON sample.

## Task 9: Desktop UI — setting, red lines, Home, notifications

Depends on: Task 7, Task 8.

- `Services/ConfigService.swift`: `purgeRevokedData: Bool?` read from and saved
  to `privacy.purge_revoked_data` (absent stays absent until the owner
  toggles).
- `Views/Settings/SystemSettings.swift`: a `Section("Privacy")` (DesignKit
  `SettingsRows`) with the toggle **Delete an account's data when its access is revoked**
  and a footnote: grace 72 h, lease 30 days, what is kept (briefings, recaps,
  ideas, memory, chats, transcripts). The toggle shows the effective value from
  `accounts purges --json`; `enabled_by == "policy"` disables it with
  "Set by your organisation". Saving goes through the existing
  `ConfigSaveBar`.
- `Services/AccountPurgeCenter.swift` on `AppState`: GRDB observation of
  `AccountPurgeQueries.open`/`recent`, hands new notices to
  `NotificationService` (one per row per state, `UserDefaults` set
  `accountPurges.noticesSent`), exposes `openRows`/`recentRows`.
- Red line component (DesignKit tone `.danger`, one view reused): in
  `SlackConnectionDetail`, `GoogleConnectionDetail`, `JiraConnectionDetail`,
  `LinearConnectionDetail` above the existing Re-login button for an open row;
  the done line for `purged`. On Home (`Views/Home/HomeView.swift`
  `HomeContent`) a banner above Getting ready with **Reconnect**, which sets
  `appState.settingsTab = .connections`, `settingsConnection` to the source
  and calls `openSettingsWindow` (`AppState.swift:82,86,163`).
- Tests: ViewInspector tests for `HomeContent` with an open row (banner,
  Reconnect closure) and without; a connection-detail test for the purged
  line. `make test-swift FILTER='AccountPurge|HomeContent|ConnectionDetail'`,
  `make lint-swift`; `make desktop-shots` to look at Settings and Home before
  review.

## Task 10: Docs, inventory and guide

Depends on: Task 6, Task 7, Task 9.

- `docs/inventory/account-purge.md`:
  - **PURGE-01 — Schedule and cancel**: Observable (notice from scheduling,
    72 h grace, 30-day lease — disabled accounts count, removed accounts get
    their own lease row due 72 h after scheduling (SLACK-01 unchanged: remove
    keeps the data) —, reconnect cancels, off = nothing scheduled and
    open rows cancelled, running finishes, purged accepts only `ok`),
    Mechanism (`purge.Plan`/`Apply`, `Set*AccountAuthState` SQL,
    `MarkAccountAccessOK`, `purge.Enabled` order), guards from Tasks 2–4 and 6.
  - **PURGE-02 — Chunked delete and ledger**: ≤ 500 rows per transaction,
    resumable, scope (attributable rows only, AI text kept, cross-account kept,
    transcript-linked events kept), KB documents deleted directly, token files
    deleted outside transactions, account row kept as `purged`; guards from
    Task 5 incl. the schema-driven coverage test.
  - Add the module row to `docs/inventory/README.md` (code paths:
    `internal/purge/`, `internal/db/account_purges.go`,
    `internal/db/account_purge_steps.go`, `internal/db/account_access.go`,
    `internal/daemon/account_purge.go`, `cmd/accounts.go`,
    `WatchtowerDesktop/Sources/Services/AccountPurgeCenter.swift`,
    `WatchtowerDesktop/Sources/WatchtowerCore/Services/AccountPurgeNoticePolicy.swift`).
- `docs/inventory/linear.md`: amend LINEAR-03 — title "Auth loss marks the
  account revoked; data is deleted only by an enabled purge"; Observable adds
  "when purge on revoked access is enabled (PURGE-01), a revoked account's
  data is deleted after the 72 h grace unless the owner logs in again";
  Mechanism notes the `revoked_at`/`access_ok_at` columns and that a pass still
  never writes `status = ok`; Observable also notes that a removed workspace's
  rows are kept by the remove and deleted only by an enabled lease purge
  30 days after its last confirmed access; guards gain `TestLinear03_PurgeOffKeepsData` and
  `TestLinear03_PurgeScheduledCancelledByReconnect`; an amendment-log line
  (2026-10-21, board #601, ask #474). SLACK-01 untouched — add a note line in
  `slack-accounts.md` that revocation is not removal and that a removed
  account's data, kept by the remove, is deleted by an enabled lease purge
  30 days after its last confirmed access (PURGE-01).
- `docs/features/revoke-purge.md`: the decisions above, the step order per
  source and what each source keeps, the corp-profile line
  `WATCHTOWER_PURGE_DEFAULT=on`, the `--json` keys, the policy seam for #608,
  and "Later" (#603 key release). Add its line to CLAUDE.md "Feature Notes".
- Guide: new page `docs/guide/concepts/revoked-access.md` (WRITING.md shape,
  under 8 KB: why, how it works with the dates, turning it on, what is kept,
  "My data was deleted"), linked from `concepts/privacy.md` ("Removing an
  account…" paragraph), `concepts/sources-and-accounts.md`,
  `reference/settings.md` (Privacy row), `reference/cli.md`
  (`accounts purges`) and the guide index. Run
  `go test ./docs/guide/ ./internal/kb/ ./internal/chat/` and regenerate the
  prompt golden with `go test ./internal/chat -run TestBuildSystemPrompt_Golden -update`.

## Open questions

- Resolved 2026-10-21 (ask #477): the lease counts disabled (not removed)
  accounts, and removed accounts are covered by the lease too (Decisions,
  Schedule/Cancel). `remove` stays soft; SLACK-01 is unchanged.
