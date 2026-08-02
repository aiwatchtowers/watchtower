# Google Multi-Account — Design

**Date:** 2026-07-30
**Branch:** `feature/multi-account`
**Status:** implemented (Tasks 1–12 complete, 2026-07-30)

Sub-project 1 of 3 of the multi-account initiative (Google → Slack → Jira). This
sub-project also establishes the cross-cutting conventions the later two reuse:
account rows instead of singleton token files, per-account auth state instead of
`CHECK (id = 1)` singletons, namespaced inbox `channel_id`s, and daemon syncer
fan-out slices.

## Goal

Allow connecting **N Google accounts** (corporate, personal, second job — any
mix) to one workspace, with Calendar and Gmail synced per account into the
single shared database. The secretary sees everything as one context: one
dashboard, one briefing, one memory. Accounts may live in different Google
Workspace organizations, so each account may need its **own OAuth client**
(an internal app only accepts accounts of its own org).

The existing single-account install migrates in place: current data becomes
account #1, nothing is lost, no re-sync required.

## Non-goals (v1)

- Cross-account event dedup (we only start persisting `ical_uid` so a later
  slice can dedup without re-syncing).
- Concurrent OAuth flows (one login at a time; the loopback port stays 18501).
- Per-account sync schedules (all accounts sync in the same daemon phase).
- Changing the `mail:<message_id>` memory provenance format (see Memory below).
- Multi-Slack and multi-Jira (sub-projects 2–3; they reuse the conventions
  established here but are specced separately).

## Data model (one goose migration)

New table `google_accounts` — the Google analog of `email_accounts`:

| column | notes |
|---|---|
| `id INTEGER PRIMARY KEY AUTOINCREMENT` | account discriminator everywhere |
| `email TEXT NOT NULL DEFAULT ''` | filled right after token exchange (one `gmail.users.getProfile('me')` or calendarList-primary call); empty until then |
| `label TEXT NOT NULL DEFAULT ''` | user-visible name ("Personal", "WhiteBIT") |
| `client_id TEXT NOT NULL DEFAULT ''` | non-secret half of a custom OAuth client; empty = use the build-time default |
| `calendar_enabled / gmail_enabled INTEGER NOT NULL` | set from the scopes actually granted; re-login can widen |
| `status TEXT NOT NULL DEFAULT 'ok'` + `error TEXT` | replaces the `calendar_auth_state` / `gmail_auth_state` singletons |
| `gmail_last_internal_date REAL NOT NULL DEFAULT 0` | per-account Gmail watermark (moves off the `workspace` row) |
| `memory_gmail_last_extracted_ts REAL NOT NULL DEFAULT 0` | per-account memory-extraction watermark (moves off `workspace`) |
| `created_at` | |

Changed tables:

- `gmail_messages` gains `account_id INTEGER NOT NULL REFERENCES
  google_accounts(id) ON DELETE CASCADE` (the `imap_messages` pattern). PK
  handling: Gmail message ids are unique per mailbox, so the PK becomes
  `(account_id, id)`.
- `calendar_calendars` gains `account_id INTEGER` — set for Google rows,
  `NULL` for CalDAV/ICS rows (those keep their `caldav:`/`ics:` id-prefix
  discipline).
- `calendar_events` gains `ical_uid TEXT NOT NULL DEFAULT ''` (dedup enabler,
  unused in v1).
- `calendar_auth_state` and `gmail_auth_state` singleton tables are dropped;
  all reads/writes route to `google_accounts.status/error`.

Migration of existing data: the goose migration inserts the account #1 row
itself whenever legacy Google data exists (any `gmail_messages` row, any
Google `calendar_calendars` row, or a non-zero `workspace` Gmail watermark) —
so the FK-carrying updates in the same migration are valid: stamp
`account_id = 1` on all existing `gmail_messages` and Google
`calendar_calendars` rows, copy both watermarks off the `workspace` row, and
rewrite inbox references (below). What SQL can't see is finished in Go — a
small idempotent `EnsureLegacyGoogleAccount` step run from syncer wiring and
the CLI aliases: create account #1 when a legacy `google_token.json` exists
but the table is still empty (token present, nothing synced yet), rename the
token files, and fill `email`. A DB that never connected Google gets no row.

As always: mirror into `internal/db/schema.sql`, extend `TestAllTablesExist`,
regenerate the schema golden, and mirror into the Swift `TestDatabase.swift`
schema (known drift trap).

## Credentials & token files

- Token per account: `<ws>/google_token_<id>.json`. The legacy pair
  `google_token.json` + `gmail_token.json` is renamed to
  `google_token_1.json` during the account-#1 seed (gmail file deleted; the
  calendar one wins — they hold the same grant today).
- Custom OAuth client secret per account: `<ws>/google_credentials_<id>.json`
  holding `{client_id, client_secret}` (the `imap_credentials_<id>.json`
  pattern — secrets never in the DB; the DB keeps only the non-secret
  `client_id` for display). Missing file = use build-time defaults
  (`calendar.DefaultGoogleClientID/Secret`).
- Account removal is transactional: delete the row (CASCADE takes
  `gmail_messages`; Google `calendar_calendars`/`calendar_events` cleaned by
  the same delete helper), then best-effort remove both files post-commit
  (missing file = success).

## Auth & login flow

- `watchtower google add [--calendar --gmail] [--client-id X --client-secret-stdin] [--label L] [--no-open] [--app-return]`
  — creates the row, writes the credentials file if a custom client is given,
  runs the existing loopback OAuth flow with that client, saves the token,
  fills `email` via one profile call, sets `calendar_enabled`/`gmail_enabled`
  from granted scopes (`validateGrantedScopes` unchanged; partial grants OK).
- `watchtower google login --account <id>` — re-consent for an existing
  account (widen scopes, fix a revoked grant).
- `watchtower google remove <id>`, `watchtower google accounts` (list).
- Existing `google login`, `gmail login/logout`, `calendar login/logout`
  become thin aliases operating on account #1 (create it if absent) — scripts
  and docs keep working.
- Config: `gmail.enabled` / `calendar.enabled` stay as global daemon-phase
  switches. `gmail.account_email` is retired (identity now lives on account
  rows); the config key is ignored, not migrated.

## Sync & daemon

- `wireGoogleSyncers` replaces `wireCalendarSyncer`+`wireGmailSyncer`:
  iterate `ListGoogleAccounts`, build a `calendar.Syncer` and/or
  `gmail.Syncer` per enabled account, each with its own token store and OAuth
  config. Daemon: `SetCalendarSyncers([]...)` / `SetGmailSyncers([]...)`;
  phases loop the slices; one account's failure sets *its* `status='error'`
  and never blocks the others (the `wireImapSyncers` pattern).
- Gmail watermark: each syncer reads/advances its own
  `google_accounts.gmail_last_internal_date`.
- Calendar stale-cleanup scoping: each Google syncer sees only
  `calendar_calendars` rows with its `account_id` — extends today's
  Google-vs-CalDAV `dropNonGoogleCalendarIDs` discipline to
  Google-vs-Google. Account A must never delete account B's calendars.
- Calendar selection stays per-calendar in the DB (rows now carry the
  account). `cfg.Calendar.SelectedCalendars` (config path) is legacy:
  honored for account #1 only.
- CLI: `calendar sync` / `gmail sync` sync all accounts; `--account <id>`
  restricts to one.

## Inbox, pipelines, owner identity

- **Gmail detector**: inbox `channel_id` changes from bare `thread_id` to
  `gmail:<accountID>:<threadID>` (the `imap:<acct>:...` precedent). The
  migration rewrites existing `inbox_items.channel_id` and the `channel:`
  mute-scope keys and learned-rule references to `gmail:1:...` — otherwise
  existing channel-scoped mutes silently stop matching. `sender:` mute-scope
  keys need no rewrite: they're keyed on the raw sender address (unaffected
  by the channel_id reshape), not on `channel_id`.
- **Own-message suppression** becomes per-account: compare sender against the
  *source account's* email (strictly better than today's single global
  `gmail.account_email`).
- **Owner identity**: one human, many addresses. `applyInboxCurrentUser`
  (the no-Slack fallback) uses the first active google account's email.
  `buildSecretaryBrief` gains one line listing all connected owner addresses
  so triage knows mail to the personal inbox is still "you".
  `secretary_profile` / `style_profile` untouched — the owner is one person.
- **Memory**: `mail:<message_id>` provenance format unchanged; the resolver
  checks existence across all accounts. Cross-mailbox message-id collision is
  a documented theoretical limitation of v1. Gmail episode extraction
  iterates accounts, each against its own
  `google_accounts.memory_gmail_last_extracted_ts` (a shared watermark would
  let an account added later swallow the others' windows). Calendar memory
  source (`calevent:<event_id>`) unchanged. No MEM contract is weakened;
  INBOX-09's watermark wording generalizes to "per account" in
  `docs/inventory/` (same semantics, applied per watermark).
- **UI attribution**: inbox rows / situation sources show the account label,
  resolved from the `channel_id` prefix.

## Desktop UI

- **Settings → Google**: account list replaces the single "Connect Google"
  block (pattern: `EmailAccountsViewModel` + `AddEmailAccountView`). Row =
  email/label + Calendar/Gmail badges + status + Remove. "Add Google
  Account" sheet: label, Calendar/Gmail toggles, collapsed "Advanced: custom
  OAuth client" (client_id + secret; secret passed to the CLI via stdin).
  Connect shells out to `watchtower google add --app-return`.
- `GoogleConnectFlow.shared` becomes the manager of the *current* login
  attempt (still one at a time); the account list itself is read from the DB
  via a new `GoogleAccountQueries` (GRDB).
- The Gmail card in `AddEmailAccountView` and the Google card in
  `AddCalendarAccountView` both open the same new sheet — two entry points,
  one flow. "Single Google account" copy is removed.
- Settings calendar checkboxes group by account section. The Events feed is
  unchanged (events already merge across `calendar_id`s).

## Testing

- Migration test: single-account DB → account #1 seeded, watermarks moved,
  `gmail_messages.account_id=1`, inbox channel_ids and mute scopes rewritten,
  legacy token files renamed.
- Fan-out test: two accounts, account A's auth failure marks only A's status
  and B still syncs (degenerate-input discipline: also cover the
  zero-accounts case exiting clean).
- Stale-cleanup isolation: account A's sync never touches B's calendars
  (extends the `dropNonGoogleCalendarIDs` test).
- Gmail detector with two accounts: each mailbox's own messages suppressed
  by its own email.
- OAuth client resolution: custom credentials file wins over build-time
  default; missing file falls back.
- Schema: `TestAllTablesExist`, schema golden regen, Swift `TestDatabase.swift`
  mirror.

## Implementation deviations

Two owner-approved changes from this design landed during implementation:

- **Task 5 (calendar accounts): "first owner + real primary id" replaces a shared `calendar_id` keyspace.** Review of Task 5 found a Critical defect: two Google accounts syncing the same shared calendar (e.g. a company calendar both accounts can see) would collide on `calendar_calendars`' `calendar_id` primary key, since the design as written let a later account's `UpsertCalendar` steal `account_id` ownership of a row the first account already owned. The owner's fix (no new migration): `UpsertCalendar` never re-parents an existing row's `account_id` — whichever account syncs a shared calendar first keeps it. The literal string `'primary'` id (used as a fallback for the primary calendar before its real id was known) is replaced by the real primary calendar id resolved from the calendarList call, and stale-calendar deletion is skipped whenever that resolution is unavailable (better to leave a stale row than delete a calendar out from under the wrong account).
- **Task 8 (inbox/identity): own-message suppression is NEW behavior, not a carry-over.** The design's Inbox section states own-message suppression "becomes per-account… strictly better than today's single global `gmail.account_email`" — phrasing that reads as if a global version already existed. It did not: pre-multi-account Gmail detection had no owner-sent-message filter at all. The per-account suppression (comparing a message's sender against the *source account's own* email) shipped in Task 8 as new behavior, confirmed spec-mandated and owner-approved (design §4), not scope creep — see the SDD ledger for Task 8.

## Rollout

Land as a PR chain into `feature/multi-account`; final merge to `main` after
sub-project 1 is verified live (owner connects a second, personal Google
account through the old public OAuth client). Sub-projects 2 (Slack) and 3
(Jira) then proceed in parallel worktrees, with migration numbers reserved
up front.
