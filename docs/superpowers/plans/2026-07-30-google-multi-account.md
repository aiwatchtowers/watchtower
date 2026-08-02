# Google Multi-Account Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** N Google accounts (Calendar + Gmail) per workspace in one shared DB — account rows, per-account tokens/OAuth clients/watermarks/auth-state, syncer fan-out, account-scoped inbox items, Desktop account list.

**Architecture:** Copy the proven `email_accounts` pattern (`internal/db/email_accounts.go`, `wireImapSyncers`, `DetectImapAccounts`, `EmailAccountsViewModel`) onto Google: new `google_accounts` table replaces the `calendar_auth_state`/`gmail_auth_state` singletons and the workspace-row Gmail watermarks; `calendar.Syncer`/`gmail.Syncer` gain an `accountID` and are wired as slices; inbox `channel_id` becomes `gmail:<accountID>:<threadID>`; the Desktop Settings Google block becomes an account list. Existing single-account installs migrate in place (account #1).

**Tech Stack:** Go 1.25, goose migrations, modernc.org/sqlite, SwiftUI + GRDB (WatchtowerDesktop).

**Spec:** `docs/superpowers/specs/2026-07-30-google-multi-account-design.md`

## Global Constraints

- Branch: `feature/multi-account`. All commits land there. Commit messages in English.
- New migration number: **00043** (`internal/db/migrations/00043_google_accounts.sql`). Do NOT bump `CurrentSchemaFormat`.
- Every schema change must be mirrored in `internal/db/schema.sql`, `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift`, added to `TestAllTablesExist` (`internal/db/db_test.go:93`) if a new table, and the golden regenerated: `go test ./internal/db/ -run TestSchemaGolden -update`.
- Table-recreation dances must wrap in `PRAGMA foreign_keys = OFF` / `ON` outside any transaction (guarded by `TestMigration_TableRecreationPreservesCascadeChildren`).
- No behavioral-contract weakening: read `docs/inventory/inbox-pulse.md` before touching `internal/inbox`; INBOX-09 semantics stay intact, applied per account watermark.
- Secrets never in the DB and never in argv — credential files (0600) + stdin, like IMAP.
- Go verification per task: `go build ./... && go vet ./...` plus the named tests. Swift: `cd WatchtowerDesktop && swift build && swift test` — capture real exit codes (redirect to a log file, check `$?`; never pipe through `tail`).
- The daemon may be running during development (Desktop respawns it). Don't rely on killing it; run CLI syncs manually for verification.

---

### Task 1: Migration 00043 — `google_accounts` + account scoping + in-place data migration

**Files:**
- Create: `internal/db/migrations/00043_google_accounts.sql`
- Create: `internal/db/google_accounts_migration_test.go`
- Modify: `internal/db/schema.sql` (workspace block ~:5, calendar_calendars :835, gmail_messages :1051, calendar_auth_state :1042, gmail_auth_state :1072, calendar_events :845; new google_accounts block before email_accounts :1084)
- Modify: `internal/db/db_test.go:93` (`TestAllTablesExist`: add `"google_accounts"`, remove `"gmail_auth_state"`)
- Modify: `internal/db/testdata/schema_v73.golden` (regenerate)

**Interfaces:**
- Produces: table `google_accounts(id, email, label, client_id, calendar_enabled, gmail_enabled, status, error, gmail_last_internal_date, memory_gmail_last_extracted_ts, created_at, updated_at)`; `gmail_messages` with `account_id` and `PRIMARY KEY (account_id, id)`; `calendar_calendars.account_id` (NULL for caldav/ics); `calendar_events.ical_uid`; NO `calendar_auth_state`/`gmail_auth_state` tables; NO `workspace.gmail_last_internal_date`/`workspace.memory_gmail_last_extracted_ts` columns.

- [ ] **Step 1: Write the failing migration test**

`internal/db/google_accounts_migration_test.go`:

```go
package db

import "testing"

// TestMigration00043GoogleAccounts covers the schema half: table exists,
// singletons gone, new columns present, workspace watermark columns dropped.
func TestMigration00043GoogleAccounts(t *testing.T) {
	d := OpenTestDB(t)

	assertTableExists(t, d, "google_accounts")
	assertTableGone(t, d, "gmail_auth_state")
	assertTableGone(t, d, "calendar_auth_state")

	// gmail_messages carries account_id in a composite PK.
	if _, err := d.Exec(`INSERT INTO google_accounts (email, label) VALUES ('a@x.com', 'A')`); err != nil {
		t.Fatalf("insert google account: %v", err)
	}
	if _, err := d.Exec(`INSERT INTO gmail_messages (account_id, id, thread_id) VALUES (1, 'm1', 'th1')`); err != nil {
		t.Fatalf("insert gmail message: %v", err)
	}
	// Same message id under a second account must NOT conflict.
	if _, err := d.Exec(`INSERT INTO google_accounts (email, label) VALUES ('b@y.com', 'B')`); err != nil {
		t.Fatalf("insert second account: %v", err)
	}
	if _, err := d.Exec(`INSERT INTO gmail_messages (account_id, id, thread_id) VALUES (2, 'm1', 'th1')`); err != nil {
		t.Fatalf("same message id under second account should insert: %v", err)
	}

	// calendar_calendars.account_id and calendar_events.ical_uid columns exist.
	if _, err := d.Exec(`INSERT INTO calendar_calendars (id, name, account_id) VALUES ('cal1', 'Cal', 1)`); err != nil {
		t.Fatalf("calendar_calendars.account_id: %v", err)
	}
	if _, err := d.Exec(`INSERT INTO calendar_events (id, calendar_id, start_time, end_time, ical_uid)
	                     VALUES ('e1', 'cal1', '2026-01-01T00:00:00Z', '2026-01-01T01:00:00Z', 'uid1')`); err != nil {
		t.Fatalf("calendar_events.ical_uid: %v", err)
	}

	// Workspace watermark columns are gone.
	if _, err := d.Exec(`UPDATE workspace SET gmail_last_internal_date = 1`); err == nil {
		t.Fatal("workspace.gmail_last_internal_date should be dropped")
	}
	if _, err := d.Exec(`UPDATE workspace SET memory_gmail_last_extracted_ts = 1`); err == nil {
		t.Fatal("workspace.memory_gmail_last_extracted_ts should be dropped")
	}

	// Deleting an account cascades its gmail messages.
	if _, err := d.Exec(`DELETE FROM google_accounts WHERE id = 2`); err != nil {
		t.Fatalf("delete account: %v", err)
	}
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM gmail_messages WHERE account_id = 2`).Scan(&n); err != nil || n != 0 {
		t.Fatalf("cascade delete failed: n=%d err=%v", n, err)
	}
}
```

If `assertTableExists`/`assertTableGone` are unexported helpers in another test file of the same package (`internal/db/db_test.go:147`+), reuse them; otherwise inline a `sqlite_master` probe.

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/db/ -run TestMigration00043GoogleAccounts -v 2>&1 | tee /tmp/t1.log; echo "exit=$?"`
Expected: FAIL (table `google_accounts` missing).

- [ ] **Step 3: Write the migration**

`internal/db/migrations/00043_google_accounts.sql`. Notes: `calendar_calendars` has an inbound FK from `calendar_events`, and `gmail_messages` changes its PK — both need the recreation dance under `PRAGMA foreign_keys = OFF` (goose: use `-- +goose NO TRANSACTION` semantics are NOT needed; goose sqlite runs statements in a tx — pragma foreign_keys is a no-op inside a tx, so mark the migration `-- +goose NO TRANSACTION` and manage explicitly, matching the pattern in the FK-recreation guard test):

```sql
-- +goose NO TRANSACTION
-- +goose Up
PRAGMA foreign_keys = OFF;

-- 1. Account table (the Google analog of email_accounts; status/error here
--    replace the calendar_auth_state / gmail_auth_state singletons).
CREATE TABLE IF NOT EXISTS google_accounts (
    id                             INTEGER PRIMARY KEY AUTOINCREMENT,
    email                          TEXT NOT NULL DEFAULT '',
    label                          TEXT NOT NULL DEFAULT '',
    client_id                      TEXT NOT NULL DEFAULT '',  -- non-secret half of a custom OAuth client; '' = build-time default
    calendar_enabled               INTEGER NOT NULL DEFAULT 0,
    gmail_enabled                  INTEGER NOT NULL DEFAULT 0,
    status                         TEXT NOT NULL DEFAULT 'ok',  -- ok | error | revoked
    error                          TEXT NOT NULL DEFAULT '',
    gmail_last_internal_date       REAL NOT NULL DEFAULT 0,   -- per-account Gmail sync watermark (was workspace.gmail_last_internal_date)
    memory_gmail_last_extracted_ts REAL NOT NULL DEFAULT 0,   -- per-account memory extraction watermark (was workspace.memory_gmail_last_extracted_ts)
    created_at                     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at                     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- 2. Seed account #1 when legacy Google data exists (token-only installs are
--    seeded in Go by ensureLegacyGoogleAccount — SQL can't see token files).
INSERT INTO google_accounts (email, label, calendar_enabled, gmail_enabled,
                             gmail_last_internal_date, memory_gmail_last_extracted_ts)
SELECT '', '',
       CASE WHEN EXISTS (SELECT 1 FROM calendar_calendars
                         WHERE id NOT LIKE 'caldav:%' AND id NOT LIKE 'ics:%') THEN 1 ELSE 0 END,
       CASE WHEN EXISTS (SELECT 1 FROM gmail_messages) THEN 1 ELSE 0 END,
       COALESCE((SELECT gmail_last_internal_date FROM workspace LIMIT 1), 0),
       COALESCE((SELECT memory_gmail_last_extracted_ts FROM workspace LIMIT 1), 0)
WHERE EXISTS (SELECT 1 FROM gmail_messages)
   OR EXISTS (SELECT 1 FROM calendar_calendars WHERE id NOT LIKE 'caldav:%' AND id NOT LIKE 'ics:%')
   OR COALESCE((SELECT gmail_last_internal_date FROM workspace LIMIT 1), 0) > 0;

-- 3. gmail_messages: add account_id, PK becomes (account_id, id).
CREATE TABLE gmail_messages_new (
    account_id     INTEGER NOT NULL REFERENCES google_accounts(id) ON DELETE CASCADE,
    id             TEXT NOT NULL,
    thread_id      TEXT NOT NULL DEFAULT '',
    from_email     TEXT NOT NULL DEFAULT '',
    from_name      TEXT NOT NULL DEFAULT '',
    to_json        TEXT NOT NULL DEFAULT '[]',
    cc_json        TEXT NOT NULL DEFAULT '[]',
    subject        TEXT NOT NULL DEFAULT '',
    snippet        TEXT NOT NULL DEFAULT '',
    body_text      TEXT NOT NULL DEFAULT '',
    internal_date  TEXT NOT NULL DEFAULT '',
    labels_json    TEXT NOT NULL DEFAULT '[]',
    is_unread      INTEGER NOT NULL DEFAULT 0,
    permalink      TEXT NOT NULL DEFAULT '',
    synced_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (account_id, id)
);
INSERT INTO gmail_messages_new
SELECT 1, id, thread_id, from_email, from_name, to_json, cc_json, subject, snippet,
       body_text, internal_date, labels_json, is_unread, permalink, synced_at, updated_at
FROM gmail_messages;
DROP TABLE gmail_messages;
ALTER TABLE gmail_messages_new RENAME TO gmail_messages;
CREATE INDEX IF NOT EXISTS idx_gmail_messages_thread ON gmail_messages(thread_id);
CREATE INDEX IF NOT EXISTS idx_gmail_messages_synced ON gmail_messages(synced_at);

-- 4. calendar_calendars: add account_id (NULL for caldav/ics rows).
ALTER TABLE calendar_calendars ADD COLUMN account_id INTEGER REFERENCES google_accounts(id);
UPDATE calendar_calendars SET account_id = 1
WHERE id NOT LIKE 'caldav:%' AND id NOT LIKE 'ics:%'
  AND EXISTS (SELECT 1 FROM google_accounts WHERE id = 1);

-- 5. calendar_events: dedup enabler.
ALTER TABLE calendar_events ADD COLUMN ical_uid TEXT NOT NULL DEFAULT '';

-- 6. Inbox rewrite: Gmail items get account-scoped channel ids.
UPDATE inbox_items SET channel_id = 'gmail:1:' || channel_id
WHERE trigger_type IN ('email_received', 'email_cc')
  AND channel_id NOT LIKE 'imap:%' AND channel_id NOT LIKE 'gmail:%';
UPDATE inbox_learned_rules SET scope_key = 'channel:gmail:1:' || substr(scope_key, 9)
WHERE scope_key LIKE 'channel:%'
  AND EXISTS (SELECT 1 FROM inbox_items
              WHERE inbox_items.channel_id = 'gmail:1:' || substr(inbox_learned_rules.scope_key, 9)
                AND inbox_items.trigger_type IN ('email_received', 'email_cc'));

-- 7. Retire singletons and workspace scalars.
DROP TABLE IF EXISTS calendar_auth_state;
DROP TABLE IF EXISTS gmail_auth_state;
ALTER TABLE workspace DROP COLUMN gmail_last_internal_date;
ALTER TABLE workspace DROP COLUMN memory_gmail_last_extracted_ts;

PRAGMA foreign_keys = ON;

-- +goose Down
PRAGMA foreign_keys = OFF;
ALTER TABLE workspace ADD COLUMN gmail_last_internal_date REAL NOT NULL DEFAULT 0;
ALTER TABLE workspace ADD COLUMN memory_gmail_last_extracted_ts REAL NOT NULL DEFAULT 0;
UPDATE workspace SET
    gmail_last_internal_date = COALESCE((SELECT gmail_last_internal_date FROM google_accounts WHERE id = 1), 0),
    memory_gmail_last_extracted_ts = COALESCE((SELECT memory_gmail_last_extracted_ts FROM google_accounts WHERE id = 1), 0);
CREATE TABLE IF NOT EXISTS calendar_auth_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    status TEXT NOT NULL DEFAULT 'ok',
    error TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE TABLE IF NOT EXISTS gmail_auth_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    status TEXT NOT NULL DEFAULT 'ok',
    error TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
INSERT OR IGNORE INTO gmail_auth_state (id, status, error) VALUES (1, 'ok', '');
UPDATE inbox_learned_rules SET scope_key = 'channel:' || substr(scope_key, 17)
WHERE scope_key LIKE 'channel:gmail:1:%';
UPDATE inbox_items SET channel_id = substr(channel_id, 9)
WHERE channel_id LIKE 'gmail:1:%';
CREATE TABLE gmail_messages_old (
    id             TEXT PRIMARY KEY,
    thread_id      TEXT NOT NULL DEFAULT '',
    from_email     TEXT NOT NULL DEFAULT '',
    from_name      TEXT NOT NULL DEFAULT '',
    to_json        TEXT NOT NULL DEFAULT '[]',
    cc_json        TEXT NOT NULL DEFAULT '[]',
    subject        TEXT NOT NULL DEFAULT '',
    snippet        TEXT NOT NULL DEFAULT '',
    body_text      TEXT NOT NULL DEFAULT '',
    internal_date  TEXT NOT NULL DEFAULT '',
    labels_json    TEXT NOT NULL DEFAULT '[]',
    is_unread      INTEGER NOT NULL DEFAULT 0,
    permalink      TEXT NOT NULL DEFAULT '',
    synced_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
INSERT OR IGNORE INTO gmail_messages_old
SELECT id, thread_id, from_email, from_name, to_json, cc_json, subject, snippet,
       body_text, internal_date, labels_json, is_unread, permalink, synced_at, updated_at
FROM gmail_messages WHERE account_id = 1;
DROP TABLE gmail_messages;
ALTER TABLE gmail_messages_old RENAME TO gmail_messages;
CREATE INDEX IF NOT EXISTS idx_gmail_messages_thread ON gmail_messages(thread_id);
CREATE INDEX IF NOT EXISTS idx_gmail_messages_synced ON gmail_messages(synced_at);
-- calendar_calendars: SQLite can drop a column with an inbound-FK parent intact under foreign_keys=OFF
ALTER TABLE calendar_calendars DROP COLUMN account_id;
DROP TABLE IF EXISTS google_accounts;
ALTER TABLE calendar_events DROP COLUMN ical_uid;
PRAGMA foreign_keys = ON;
```

- [ ] **Step 4: Write the data-migration test** (second test in the same file — seeds a pre-00043 shape is impossible via `OpenTestDB`, so test the *seed conditions* on a migrated DB instead: fresh DB → no `google_accounts` row):

```go
func TestMigration00043_FreshDBHasNoSeedRow(t *testing.T) {
	d := OpenTestDB(t)
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM google_accounts`).Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 0 {
		t.Fatalf("fresh DB must have no google_accounts seed row, got %d", n)
	}
}
```

The upgrade path (legacy rows → account #1 + rewritten channel ids) is covered by a raw-SQL fixture test: open `sql.Open("sqlite", ":memory:")`, `SetMaxOpenConns(1)`, replay `goose.UpTo(..., 42)`, seed `workspace` + `gmail_messages` + a bare-thread `inbox_items` row + a `channel:<thread>` learned rule, then `goose.UpByOne` and assert: one `google_accounts` row with copied watermark and `gmail_enabled=1`; `gmail_messages.account_id=1`; `inbox_items.channel_id='gmail:1:th1'`; scope_key `'channel:gmail:1:th1'`. Follow the harness shape of `TestMigration_TableRecreationPreservesCascadeChildren` (`internal/db/migration_fk_recreation_test.go:33`).

- [ ] **Step 5: Mirror into `internal/db/schema.sql`** — apply the same end-state: `google_accounts` CREATE TABLE (placed right before `email_accounts`, with a comment noting it replaces the two auth-state singletons), `gmail_messages` with `account_id` + composite PK, `calendar_calendars.account_id` column, `calendar_events.ical_uid`, delete the `calendar_auth_state` and `gmail_auth_state` blocks (and the gmail seed INSERT), delete the two workspace watermark columns.

- [ ] **Step 6: Update `TestAllTablesExist` + regenerate golden**

In `internal/db/db_test.go:93`: add `"google_accounts"`, remove `"gmail_auth_state"`.
Run: `go test ./internal/db/ -run TestSchemaGolden -update 2>&1 | tee /tmp/t1g.log; echo "exit=$?"`

- [ ] **Step 7: Run the package tests — expect failures ONLY in code still using dropped things** (`SetGmailAuthState` etc. still compile — tables are gone at runtime). Fix nothing yet; note the failing list for Task 2.

Run: `go test ./internal/db/ -run 'TestMigration00043|TestAllTablesExist|TestSchemaGolden|TestMigrationIdempotent' -v 2>&1 | tee /tmp/t1r.log; echo "exit=$?"`
Expected: PASS for these four.

- [ ] **Step 8: Commit**

```bash
git add internal/db/migrations/00043_google_accounts.sql internal/db/schema.sql internal/db/db_test.go internal/db/google_accounts_migration_test.go internal/db/testdata/schema_v73.golden
git commit -m "feat(db): google_accounts table + account-scoped gmail/calendar data (migration 00043)"
```

---

### Task 2: `internal/db` — google_accounts helpers, retire singleton accessors

**Files:**
- Create: `internal/db/google_accounts.go`
- Create: `internal/db/google_accounts_test.go`
- Modify: `internal/db/gmail.go` (drop `SetGmailAuthState`/`GetGmailAuthState`, `GetGmailLastInternalDate`/`SetGmailLastInternalDate`; add `accountID` to `UpsertGmailMessage` and reader queries)
- Modify: `internal/db/calendar.go` (drop `SetCalendarAuthState`/`GetCalendarAuthState` (:301,:315); `GetSelectedCalendarIDs` gains `accountID`; `UpsertCalendar` writes `account_id`)
- Modify: `internal/db/memory.go` (`MemoryGmailWatermark`/`SetMemoryGmailWatermark` gain `accountID`; `ListGmailThreadsForExtract` gains `accountID` filter)
- Modify: callers inside `internal/db` tests (`gmail_test.go`, `calendar_test.go`, `calendar_extra_test.go`)

**Interfaces:**
- Produces (exact signatures later tasks consume):

```go
type GoogleAccount struct {
	ID                         int64
	Email, Label, ClientID     string
	CalendarEnabled, GmailEnabled bool
	Status, Error              string
	GmailLastInternalDate      float64
	MemoryGmailLastExtractedTS float64
	CreatedAt, UpdatedAt       string
}
func (db *DB) CreateGoogleAccount(a GoogleAccount) (int64, error)
func (db *DB) ListGoogleAccounts() ([]GoogleAccount, error)              // ORDER BY id ASC
func (db *DB) GetGoogleAccount(id int64) (GoogleAccount, error)          // sql.ErrNoRows wrapped
func (db *DB) UpdateGoogleAccountConnection(id int64, email string, calendarEnabled, gmailEnabled bool) error
func (db *DB) DeleteGoogleAccount(id int64) error                        // tx: events of its calendars → calendars → account row (gmail_messages via CASCADE); no-op on missing
func (db *DB) SetGoogleAccountAuthState(id int64, status, errMsg string) error
func (db *DB) GetGmailAccountWatermark(id int64) (float64, error)
func (db *DB) SetGmailAccountWatermark(id int64, ts float64) error
func (db *DB) MemoryGmailWatermark(accountID int64) (float64, error)     // moved: reads google_accounts
func (db *DB) SetMemoryGmailWatermark(accountID int64, ts float64) error
func (db *DB) GetSelectedCalendarIDs(accountID int64) ([]string, error)  // WHERE is_selected=1 AND account_id=?
func (db *DB) UpsertGmailMessage(accountID int64, m GmailMessage) error  // was account-less
func (db *DB) GmailMessagesSyncedAfter(accountID int64, sinceISO string) ([]GmailMessage, error)
func (db *DB) ListGmailThreadsForExtract(accountID int64, sinceTS float64, limit int) ([]GmailExtractMessage, error)
```

(If the current reader used by the inbox detector has a different name — find it with `grep -rn "gmail_messages" internal/db/gmail.go` — keep its name and add the `accountID` first parameter. Same rule for `UpsertCalendar`.)

- [ ] **Step 1: Write failing tests** in `internal/db/google_accounts_test.go` (mirror `internal/db/email_accounts` test shape): create→list→get roundtrip; `SetGoogleAccountAuthState` on a missing row returns error (`RowsAffected()==0` check, copy `SetEmailAccountAuthState` body shape at `email_accounts.go:195`); watermark get on missing row returns `(0, nil)` (copy `GetImapWatermark` shape at `:167`); `DeleteGoogleAccount` in one transaction removes the account's `calendar_calendars` rows + their `calendar_events` and leaves ANOTHER account's calendars untouched — seed two accounts, two calendars (`account_id` 1 and 2), one event each, delete account 1, assert calendar/event of account 2 intact (copy `DeleteCalendarAccount` tx shape at `calendar_accounts.go:90`); `GetSelectedCalendarIDs(2)` returns only account 2's selected calendars and never `caldav:`/`ics:` rows (they have NULL account_id).

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/db/ -run TestGoogleAccount -v 2>&1 | tee /tmp/t2.log; echo "exit=$?"`
Expected: FAIL (undefined functions).

- [ ] **Step 3: Implement `internal/db/google_accounts.go`** with the signatures above. `DeleteGoogleAccount` transaction body:

```go
func (db *DB) DeleteGoogleAccount(id int64) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("deleting google account %d: %w", id, err)
	}
	defer tx.Rollback()
	if _, err := tx.Exec(`DELETE FROM calendar_events WHERE calendar_id IN
	        (SELECT id FROM calendar_calendars WHERE account_id = ?)`, id); err != nil {
		return fmt.Errorf("deleting google account %d events: %w", id, err)
	}
	if _, err := tx.Exec(`DELETE FROM calendar_calendars WHERE account_id = ?`, id); err != nil {
		return fmt.Errorf("deleting google account %d calendars: %w", id, err)
	}
	if _, err := tx.Exec(`DELETE FROM google_accounts WHERE id = ?`, id); err != nil {
		return fmt.Errorf("deleting google account %d: %w", id, err)
	}
	return tx.Commit()
}
```

(`gmail_messages` go via `ON DELETE CASCADE`. `calendar_events` deletion cascades `meeting_prep_cache` and SET-NULLs `meeting_transcripts` exactly as `DeleteCalendarAccount` already relies on.)

- [ ] **Step 4: Move the changed accessors.** In `gmail.go`: delete `GetGmailAuthState`/`SetGmailAuthState` and `GetGmailLastInternalDate`/`SetGmailLastInternalDate`; add `accountID` to `UpsertGmailMessage` + the detector reader. In `calendar.go`: delete `GetCalendarAuthState`/`SetCalendarAuthState`; `GetSelectedCalendarIDs(accountID int64)` adds `AND account_id = ?`; `UpsertCalendar` gains `accountID int64` and writes the column. In `memory.go`: watermark pair reads/writes `google_accounts` by id; `ListGmailThreadsForExtract`/`queryGmailExtractMessages` add `AND account_id = ?`.

- [ ] **Step 5: Chase compile errors across the repo** (`go build ./...` — expect breakage in `internal/gmail`, `internal/calendar`, `internal/daemon`, `internal/inbox`, `internal/memory`, `cmd`). For THIS task only stub the call sites minimally (pass account id `1` or a TODO-free direct threading where the surrounding code already has an account in scope) — Tasks 3–7 replace these call sites properly; the build must be green after every task.

- [ ] **Step 6: Run package tests**

Run: `go test ./internal/db/ 2>&1 | tee /tmp/t2r.log; echo "exit=$?"`
Expected: PASS.
Run: `go build ./... && go vet ./... 2>&1 | tee /tmp/t2b.log; echo "exit=$?"`
Expected: exit=0.

- [ ] **Step 7: Commit**

```bash
git add internal/db/ internal/gmail/ internal/calendar/ internal/daemon/ internal/inbox/ internal/memory/ cmd/
git commit -m "feat(db): google account helpers; retire gmail/calendar auth-state singletons"
```

---

### Task 3: Token & credential stores keyed by account

**Files:**
- Modify: `internal/calendar/auth.go` (add `NewAccountTokenStore`; keep `NewTokenStore` for the legacy path used by `ensureLegacyGoogleAccount`)
- Create: `internal/calendar/credentials.go`
- Create: `internal/calendar/credentials_test.go`
- Modify: `internal/gmail/auth.go` (add `NewAccountTokenStore` → same `google_token_<id>.json` file)

**Interfaces:**
- Produces:

```go
// internal/calendar/auth.go
func NewAccountTokenStore(workspaceDir string, accountID int64) *TokenStore // → google_token_<id>.json
// internal/calendar/credentials.go
type Credentials struct{ ClientID, ClientSecret string }
type CredentialStore struct{ path string }
func NewCredentialStore(workspaceDir string, accountID int64) *CredentialStore // → google_credentials_<id>.json
func (s *CredentialStore) Load() (*Credentials, error)
func (s *CredentialStore) Save(c *Credentials) error // 0o600, MkdirAll 0o700
func (s *CredentialStore) Delete() error             // IsNotExist → nil
func (s *CredentialStore) Exists() bool
// internal/gmail/auth.go
func NewAccountTokenStore(workspaceDir string, accountID int64) *TokenStore // → google_token_<id>.json (same file as calendar's)
```

- [ ] **Step 1: Failing test** (`credentials_test.go`): Save→Load roundtrip in `t.TempDir()`, file mode is 0600, `Delete` on missing file returns nil, `Exists` flips. Plus in the existing `auth_test.go` files: `NewAccountTokenStore(dir, 3).Path()` ends in `google_token_3.json` for BOTH packages.

- [ ] **Step 2: Run to verify failure** — `go test ./internal/calendar/ ./internal/gmail/ -run 'Credential|AccountTokenStore' -v 2>&1 | tee /tmp/t3.log; echo "exit=$?"` → FAIL.

- [ ] **Step 3: Implement.** Copy the `imap` credential-store shape (`internal/imap/credentials.go:13-31`). `NewAccountTokenStore` is a one-liner beside `NewTokenStore`: `filepath.Join(workspaceDir, fmt.Sprintf("google_token_%d.json", accountID))`.

- [ ] **Step 4: Run tests** — same command → PASS.

- [ ] **Step 5: Commit** — `git add internal/calendar/ internal/gmail/ && git commit -m "feat(google): per-account token and OAuth-credential stores"`

---

### Task 4: gmail.Syncer per-account

**Files:**
- Modify: `internal/gmail/sync.go` (`Syncer` gains `accountID int64`; `NewSyncer(client, database, cfg, logger, accountID)`; watermark via `GetGmailAccountWatermark`/`SetGmailAccountWatermark`; `recordAuthResult` → `SetGoogleAccountAuthState(s.accountID, ...)`; upserts pass `s.accountID`)
- Modify: `internal/gmail/sync_test.go` (harness passes an account id; watermark asserts read the account row)

**Interfaces:**
- Consumes: Task 2 DB helpers.
- Produces: `func NewSyncer(client *Client, database *db.DB, cfg *config.Config, logger *log.Logger, accountID int64) *Syncer` — Task 6 wires it.

- [ ] **Step 1: Update the harness + write the new failing test.** In each existing test, create the account first and pass its id:

```go
accountID, err := database.CreateGoogleAccount(db.GoogleAccount{Email: "me@x.com", Label: "T", GmailEnabled: true})
// ...
s := NewSyncer(c, database, cfg, nil, accountID)
```

Watermark asserts become `database.GetGmailAccountWatermark(accountID)`; seeding becomes `database.SetGmailAccountWatermark(accountID, 1700000000)`.

New test `TestSyncTwoAccountsIsolated`: two accounts, run a sync for account A only (same httptest mux), assert B's watermark stays 0 and all inserted `gmail_messages` rows carry `account_id = A`. New test `TestSyncAuthErrorMarksOnlyOwnAccount`: point the token endpoint at a handler returning `{"error":"invalid_grant"}`, run A's sync, assert `google_accounts.status='revoked'` for A and `'ok'` for B.

- [ ] **Step 2: Run to verify failure** — `go test ./internal/gmail/ -v 2>&1 | tee /tmp/t4.log; echo "exit=$?"` → FAIL (NewSyncer arity).

- [ ] **Step 3: Implement** — thread `accountID` through `Syncer`; keep the ordering discipline comment (list uncapped → reverse oldest-first → cap) untouched.

- [ ] **Step 4: Run** — same command → PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat(gmail): per-account syncer, watermark and auth state"`

---

### Task 5: calendar.Syncer per-account

**Files:**
- Modify: `internal/calendar/sync.go` (`Syncer.accountID`; `NewSyncer(..., accountID int64)`; selection via `GetSelectedCalendarIDs(s.accountID)`; upsert calendars with `s.accountID`; `recordAuthResult` → `SetGoogleAccountAuthState`)
- Modify: `internal/calendar/sync_test.go`

**Interfaces:**
- Consumes: Task 2 helpers.
- Produces: `func NewSyncer(client *Client, database *db.DB, cfg *config.Config, logger *log.Logger, accountID int64) *Syncer`.

- [ ] **Step 1: Failing tests.** Selection block change (replaces `sync.go:76` body): `cfg.Calendar.SelectedCalendars` (legacy config path) is honored ONLY when `s.accountID == 1`; otherwise DB-selection for the account, falling back to `[]string{"primary"}`. `dropNonGoogleCalendarIDs` keeps guarding the config path. New unit test `TestSelectedCalendarsScopedToAccount` (db-backed, no httptest — seed `calendar_calendars` rows for accounts 1 and 2 plus a `caldav:1` row, assert `GetSelectedCalendarIDs(2)` result). New stale-cleanup test `TestStaleCleanupDoesNotCrossAccounts`: seed two accounts sharing NO calendars, run the cleanup loop portion for account 1's calendar ids (the loop only ever iterates the account's own ids — assert account 2's event survives by construction: call `DeleteStaleCalendarEvents` with account 1's calendar list only).

- [ ] **Step 2: Run to verify failure** — `go test ./internal/calendar/ -v 2>&1 | tee /tmp/t5.log; echo "exit=$?"` → FAIL.

- [ ] **Step 3: Implement.** Also: when upserting fetched events, populate `ical_uid` from the Google event's `iCalUID` field (add to the event struct in `client.go` if absent: `ICalUID string \`json:"iCalUID"\``, threaded into `db.UpsertCalendarEvent`).

- [ ] **Step 4: Run** — PASS. Also `go build ./... 2>&1 | tee /tmp/t5b.log; echo "exit=$?"` → 0.

- [ ] **Step 5: Commit** — `git commit -am "feat(calendar): per-account syncer, account-scoped selection and cleanup"`

---

### Task 6: Wiring — `wireGoogleSyncers`, daemon slices

**Files:**
- Modify: `cmd/sync.go` (replace `wireCalendarSyncer` (:454) + `wireGmailSyncer` (:482) with one `wireGoogleSyncers`; call site updated)
- Modify: `cmd/calendar.go:430` (`resolveGoogleOAuthConfig` stays; add `resolveGoogleOAuthConfigForAccount`)
- Modify: `internal/daemon/daemon.go` (fields → `calendarSyncers []*calendar.Syncer`, `gmailSyncers []*gmail.Syncer`; setters `SetCalendarSyncers`/`SetGmailSyncers`; `phaseCalendarSync`/`phaseGmailSync` loop)
- Modify: `internal/daemon/daemon_test.go` (whatever pins the old setters)

**Interfaces:**
- Consumes: Tasks 3–5.
- Produces:

```go
// cmd/calendar.go — per-account creds: custom credential file wins, else env/build default.
func resolveGoogleOAuthConfigForAccount(workspaceDir string, accountID int64) calendar.GoogleOAuthConfig
// internal/daemon
func (d *Daemon) SetCalendarSyncers(s []*calendar.Syncer)
func (d *Daemon) SetGmailSyncers(s []*gmail.Syncer)
```

- [ ] **Step 1: Failing test** for the resolver (`cmd/cmd_helpers_extra_test.go`, beside the existing `resolveGoogleOAuthConfig` tests at :51): write a `google_credentials_7.json` into a temp dir → `resolveGoogleOAuthConfigForAccount(dir, 7)` returns its values; without the file → falls back to `resolveGoogleOAuthConfig()`.

- [ ] **Step 2: Run to verify failure** — `go test ./cmd/ -run ResolveGoogleOAuth -v 2>&1 | tee /tmp/t6.log; echo "exit=$?"` → FAIL.

- [ ] **Step 3: Implement wiring.**

```go
func wireGoogleSyncers(ctx context.Context, d *daemon.Daemon, cfg *config.Config, database *db.DB, logger *log.Logger) {
	accounts, err := database.ListGoogleAccounts()
	if err != nil {
		logger.Printf("google: failed to list accounts: %v", err)
		return
	}
	var calSyncers []*calendar.Syncer
	var gmSyncers []*gmail.Syncer
	for _, acct := range accounts {
		store := calendar.NewAccountTokenStore(cfg.WorkspaceDir(), acct.ID)
		if !store.Exists() {
			continue
		}
		token, err := store.Load()
		if err != nil {
			logger.Printf("google: account %d: failed to load token: %v", acct.ID, err)
			continue
		}
		googleCfg := resolveGoogleOAuthConfigForAccount(cfg.WorkspaceDir(), acct.ID)
		if acct.CalendarEnabled {
			calClient, err := calendar.NewClient(ctx, token.RefreshToken, googleCfg)
			if err != nil {
				recordGoogleWireError(database, logger, acct.ID, "calendar", err, errors.Is(err, calendar.ErrAuthRevoked))
			} else {
				calSyncers = append(calSyncers, calendar.NewSyncer(calClient, database, cfg, logger, acct.ID))
			}
		}
		if acct.GmailEnabled {
			gmClient, err := gmail.NewClient(ctx, token.RefreshToken,
				gmail.GoogleOAuthConfig{ClientID: googleCfg.ClientID, ClientSecret: googleCfg.ClientSecret})
			if err != nil {
				recordGoogleWireError(database, logger, acct.ID, "gmail", err, errors.Is(err, gmail.ErrAuthRevoked))
			} else {
				gmSyncers = append(gmSyncers, gmail.NewSyncer(gmClient, database, cfg, logger, acct.ID))
			}
		}
	}
	d.SetCalendarSyncers(calSyncers)
	d.SetGmailSyncers(gmSyncers)
}

func recordGoogleWireError(database *db.DB, logger *log.Logger, accountID int64, svc string, err error, revoked bool) {
	logger.Printf("%s: account %d: failed to create client: %v", svc, accountID, err)
	status := "error"
	if revoked {
		status = "revoked"
	}
	if dbErr := database.SetGoogleAccountAuthState(accountID, status, err.Error()); dbErr != nil {
		logger.Printf("%s: account %d: record auth state: %v", svc, accountID, dbErr)
	}
}
```

Daemon phases (mirror `phaseCalDAVSync` at daemon.go:381): loop the slice, per-syncer failure logged, never fatal. Call `wireGoogleSyncers` where the two old calls were; also call `ensureLegacyGoogleAccount` (Task 7) immediately before it.

- [ ] **Step 4: Run** — `go test ./cmd/ ./internal/daemon/ 2>&1 | tee /tmp/t6r.log; echo "exit=$?"` → PASS; `go build ./...` → 0.

- [ ] **Step 5: Commit** — `git commit -am "feat(daemon): google syncer fan-out, per-account clients and auth state"`

---

### Task 7: CLI — `google add/accounts/remove`, `--account`, legacy seed, alias rewiring

**Files:**
- Modify: `cmd/google.go` (new subcommands; `google login` gains `--account`)
- Create: `cmd/google_legacy.go` (`ensureLegacyGoogleAccount`)
- Create: `cmd/google_test.go`
- Modify: `cmd/gmail.go` (login/logout/sync/status become account-#1 aliases; DELETE `persistGmailAccountEmail` — email now stored on the account row; sync loops accounts or honors `--account`)
- Modify: `cmd/calendar.go` (same alias treatment; `calendar sync` loops accounts; `calendar list`/`select` display+toggle by account)
- Modify: `internal/config/config.go:106` (delete `Gmail.AccountEmail` field; viper key becomes ignored)

**Interfaces:**
- Consumes: everything above.
- Produces:

```go
// cmd/google_legacy.go — idempotent; called from wiring (Task 6) and every alias command.
// If google_accounts is empty and <ws>/google_token.json exists: create row #1
// (calendar_enabled/gmail_enabled from which legacy token files exist), rename
// google_token.json -> google_token_1.json (delete gmail_token.json — same grant),
// best-effort fill email via gmail GetProfile when gmail scope present.
func ensureLegacyGoogleAccount(ctx context.Context, cfg *config.Config, database *db.DB, logger *log.Logger) (int64, error)
```

`watchtower google add` flags: `--calendar`, `--gmail`, `--label`, `--client-id`, `--client-secret-stdin` (reads one line from stdin), `--no-open`, `--app-return`. Flow: validate ≥1 service → `CreateGoogleAccount` → if custom client: `calendar.NewCredentialStore(dir, id).Save(...)` → `calendar.Login` with `NewAccountTokenStore(dir, id)` and per-account OAuth config → on success set enabled flags from `token.GrantsScope(...)`, fetch email via `gmail.GetProfile` (gmail scope) else leave `''`, `UpdateGoogleAccountConnection` → print summary. On login failure: delete the just-created row + credential file (mirror `createEmailAccountWithCredentials` rollback at `cmd/imap.go:70`).

- [ ] **Step 1: Failing tests** (`cmd/google_test.go`): (a) `ensureLegacyGoogleAccount` — temp workspace dir with a fake `google_token.json` + empty test DB → returns id 1, file renamed to `google_token_1.json`, row exists; second call is a no-op (idempotent); with NO token file → returns 0, no row. (b) `google add` arg validation: neither `--calendar` nor `--gmail` → error mentioning both flags.

- [ ] **Step 2: Run to verify failure** — `go test ./cmd/ -run 'LegacyGoogleAccount|GoogleAdd' -v 2>&1 | tee /tmp/t7.log; echo "exit=$?"` → FAIL.

- [ ] **Step 3: Implement.** Alias mapping: `gmail login` = `google add --gmail` when no accounts exist, else `google login --account 1 --gmail`; `gmail logout` = disable gmail flag on account 1 (revoke only when account 1 has no calendar_enabled — replaces today's cross-file shared-grant check at `cmd/gmail.go:125`); `gmail sync`/`calendar sync` iterate `ListGoogleAccounts` (respecting the enabled flag) unless `--account` given; `gmail status`/`calendar status` print per-account lines (id, email/label, status). `google accounts` output: one line per account `#<id> <email|label> [calendar|gmail badges] <status>`.

- [ ] **Step 4: Run** — `go test ./cmd/ 2>&1 | tee /tmp/t7r.log; echo "exit=$?"` → PASS. `go build ./... && go vet ./...` → 0.

- [ ] **Step 5: Commit** — `git commit -am "feat(cli): google add/accounts/remove, per-account login, legacy account seed"`

---

### Task 8: Inbox — account-scoped Gmail detector + owner addresses

**Files:**
- Modify: `internal/inbox/gmail_detector.go` (→ `DetectGmailAccounts`, loop accounts, `gmail:<id>:<thread>` channel key)
- Modify: `internal/inbox/gmail_detector_test.go`
- Modify: `internal/inbox/pipeline.go` (call site; `SetCurrentUser` keeps uid+email — email no longer feeds the gmail detector)
- Modify: `internal/daemon/daemon.go:818` (`applyInboxCurrentUser` fallback: first `ListGoogleAccounts` row's email instead of `config.Gmail.AccountEmail`)
- Modify: `internal/inbox/prompt.go` or wherever `buildSecretaryBrief` lives (owner-addresses line)

**Interfaces:**
- Consumes: `ListGoogleAccounts`, `GmailMessagesSyncedAfter(accountID, sinceISO)`.
- Produces: `func DetectGmailAccounts(ctx context.Context, database *db.DB, sinceTS time.Time) (int, error)` — mirror of `DetectImapAccounts` (`imap_detector.go:26`).

- [ ] **Step 1: Failing tests.** Rework `gmail_detector_test.go`: seed TWO google accounts with emails `a@x.com`/`b@y.com` and messages addressed To each; assert items minted with `ChannelID == fmt.Sprintf("gmail:%d:%s", acctID, threadID)`; a message To `a@x.com` sitting in account B's mailbox still mints from B (matching is per source account's own email); a message FROM `a@x.com` in A's mailbox mints nothing (own-message suppression per account); account with empty email is skipped entirely (degenerate case, clean exit — no error).

- [ ] **Step 2: Run to verify failure** — `go test ./internal/inbox/ -run Gmail -v 2>&1 | tee /tmp/t8.log; echo "exit=$?"` → FAIL.

- [ ] **Step 3: Implement.** Body shape = `DetectImapAccounts`: list accounts, skip `!GmailEnabled` or empty email, per-account inner `detectGmailAccount(database, acct, sinceTS)` using `containsEmailFold(to, acct.Email)` / `cc`. Dedup query (`gmailInboxExists`) unchanged — it keys on the (now-scoped) `channel_id`. `applyInboxCurrentUser`: replace the `d.config.Gmail.AccountEmail` fallback with the first `ListGoogleAccounts` row that has a non-empty email (keep no-op semantics when DB nil). `buildSecretaryBrief`: append a line `Owner email addresses: a@x.com, b@y.com` built from `ListGoogleAccounts` + `ListEmailAccounts` emails when non-empty.

- [ ] **Step 4: Run** — `go test ./internal/inbox/ ./internal/daemon/ 2>&1 | tee /tmp/t8r.log; echo "exit=$?"` → PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat(inbox): per-account gmail detector, owner address list in secretary brief"`

---

### Task 9: Memory — per-account Gmail extraction

**Files:**
- Modify: `internal/memory/gmail_extract.go` (`runGmailExtract` loops accounts; watermark per account)
- Modify: `internal/memory/gmail_extract_test.go` (or wherever `runGmailExtract` is pinned — find via `grep -rn runGmailExtract internal/memory/*_test.go`)

**Interfaces:**
- Consumes: `ListGoogleAccounts`, `MemoryGmailWatermark(accountID)`, `SetMemoryGmailWatermark(accountID, ts)`, `ListGmailThreadsForExtract(accountID, wm, limit)`.

- [ ] **Step 1: Failing test:** two accounts with messages at different timestamps; run extraction with a generator stub; assert each account's `memory_gmail_last_extracted_ts` advanced independently (account B's watermark not advanced past its own newest message when only A had a successful batch).

- [ ] **Step 2: Run to verify failure** — `go test ./internal/memory/ -run Gmail -v 2>&1 | tee /tmp/t9.log; echo "exit=$?"` → FAIL.

- [ ] **Step 3: Implement:** wrap the existing body in `for _, acct := range accounts` (skip `!GmailEnabled`); `wm := p.db.MemoryGmailWatermark(acct.ID)`; `advanceGmailWatermark` closes over `acct.ID`. Thread-alias `gmailthread:<thread_id>` and `mail:<message_id>` provenance formats unchanged (spec: documented v1 limitation).

- [ ] **Step 4: Run** — `go test ./internal/memory/ 2>&1 | tee /tmp/t9r.log; echo "exit=$?"` → PASS. Full sweep: `go test ./... 2>&1 | tee /tmp/t9all.log; echo "exit=$?"` → PASS.

- [ ] **Step 5: Commit** — `git commit -am "feat(memory): per-account gmail episode extraction watermarks"`

---

### Task 10: Desktop — model, queries, ViewModel

**Files:**
- Create: `WatchtowerDesktop/Sources/Models/GoogleAccount.swift`
- Create: `WatchtowerDesktop/Sources/Database/Queries/GoogleAccountQueries.swift`
- Create: `WatchtowerDesktop/Sources/ViewModels/GoogleAccountsViewModel.swift`
- Create: `WatchtowerDesktop/Tests/GoogleAccountQueriesTests.swift`
- Create: `WatchtowerDesktop/Tests/GoogleAccountsViewModelTests.swift`
- Modify: `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift` (add `google_accounts` CREATE TABLE mirror + `insertGoogleAccount(...)` fixture; update `gmail_messages` mirror to the account_id/composite-PK shape; add `account_id` to `calendar_calendars` mirror; add `ical_uid` to `calendar_events` mirror; drop `gmail_auth_state` mirror)
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (hold `googleAccountsViewModel` beside `emailAccountsViewModel`)

**Interfaces:**
- Produces (Task 11 consumes):

```swift
struct GoogleAccount: FetchableRecord, Identifiable, Equatable {
    let id: Int
    let email, label, clientID, status, error: String
    let calendarEnabled, gmailEnabled: Bool
    var isOK: Bool { status == "ok" }
    var displayName: String { label.isEmpty ? (email.isEmpty ? "Google account #\(id)" : email) : label }
}
enum GoogleAccountQueries {
    static func fetchAll(_ db: Database) throws -> [GoogleAccount] // SELECT * FROM google_accounts ORDER BY id ASC
}
@MainActor @Observable final class GoogleAccountsViewModel {
    private(set) var accounts: [GoogleAccount]
    var isConnecting: Bool
    var error: String?
    func refresh()
    func addAccount(label: String, calendar: Bool, gmail: Bool, clientID: String, clientSecret: String)  // shells `google add --app-return` (+`--client-id`/`--client-secret-stdin` when non-empty; secret via stdin)
    func relogin(_ account: GoogleAccount)   // `google login --account <id> --app-return` + granted-service flags
    func remove(_ account: GoogleAccount) async // `google remove <id>`
    func cancelConnect()
    static func addArgs(label: String, calendar: Bool, gmail: Bool, hasCustomClient: Bool, clientID: String) -> [String] // pure, testable
}
```

- [ ] **Step 1: Failing tests.** `GoogleAccountQueriesTests`: insert two fixture rows via `insertGoogleAccount`, `fetchAll` returns both in id order with fields mapped. `GoogleAccountsViewModelTests`: `addArgs` builds `["google","add","--app-return","--label","L","--calendar","--gmail"]` (order-insensitive assert on Set where safe), plus `["--client-id","cid","--client-secret-stdin"]` when a custom client is set; `removeArgs`-analog dispatch (`["google","remove","3"]`).

- [ ] **Step 2: Run to verify failure** — `cd WatchtowerDesktop && swift test --filter GoogleAccount > /tmp/t10.log 2>&1; echo "exit=$?"` → non-zero.

- [ ] **Step 3: Implement** — copy `EmailAccountsViewModel` mechanics verbatim (runCLI/runProcess stdin-before-drain pattern at `EmailAccountsViewModel.swift:198`), `refresh()` reads via `dbPool.read { GoogleAccountQueries.fetchAll($0) }`, success path triggers `DaemonManager.restart()`.

- [ ] **Step 4: Run** — `cd WatchtowerDesktop && swift test > /tmp/t10r.log 2>&1; echo "exit=$?"` → 0.

- [ ] **Step 5: Commit** — `git add WatchtowerDesktop/ && git commit -m "feat(desktop): google account model, queries, view model"`

---

### Task 11: Desktop — Settings UI

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Settings/AddGoogleAccountView.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Settings/SettingsView.swift` (`calendarSettingsSection` :468 keeps only the global toggles — `Enable calendar sync`, `Sync days ahead`; connect/disconnect moves out; `gmailSettingsSection` :526 keeps `Enable Gmail sync`; NEW `googleAccountsSection` modeled on `emailAccountsSection` :585, placed before `calendarAccountsSection`)
- Modify: `WatchtowerDesktop/Sources/Views/Settings/AddEmailAccountView.swift:103` (gmailCard: replace `GoogleConnectFlow.shared.gmail` connect with a button opening the new sheet / or delegating to `appState.googleAccountsViewModel`)
- Modify: `WatchtowerDesktop/Sources/Views/Settings/AddCalendarAccountView.swift:96` (googleCard: same redirect)
- Modify: `WatchtowerDesktop/Sources/Services/GoogleConnectFlow.swift` (onboarding-era combined flow keeps working for the FIRST account: `connect()` now runs `google add --calendar --gmail --app-return` when no accounts exist; `checkStatus` file-stat in `GoogleAuthService`/`GmailAuthService` switches to `google_token_1.json` OR simply `accounts.contains { $0.isOK }` via the VM)
- Modify: `WatchtowerDesktop/Sources/Utilities/Constants.swift` (delete `gmailOAuthAvailable` and its three call sites — the internal-app build makes the gate moot; grep `gmailOAuthAvailable` to catch `GoogleConnectOptionsView.swift:16,24`, `SettingsView.swift:543`, `AddEmailAccountView.swift:130`)

**Interfaces:**
- Consumes: Task 10's `GoogleAccountsViewModel`.

- [ ] **Step 1: Build the section.** `googleAccountsSection` copies `emailAccountsSection`'s row layout: `ForEach(vm.accounts)` → displayName + service badges (`Label("Calendar", systemImage: "calendar")` when `calendarEnabled`, `Label("Gmail", systemImage: "envelope")` when `gmailEnabled`) + status dot (green ok / orange error / red revoked with `account.error` tooltip) + `Button("Re-login")` when not ok + `Button(role: .destructive) { pendingRemoval = account }`. `Button("Add Google Account") { showAddGoogleAccountSheet = true }`. Removal confirmation via the existing `confirmationDialog` pattern used by `calendarAccountPendingRemoval` (SettingsView :57).

`AddGoogleAccountView` (new sheet, 480×~420): label field, two Toggles (Calendar on, Gmail on), `DisclosureGroup("Advanced: custom OAuth client")` with client-id `TextField` + secret `SecureField` and a caption ("Needed when this account belongs to a different Google Workspace org than the built-in app"), Connect button → `vm.addAccount(...)`, spinner + Cancel while `vm.isConnecting`, error text.

- [ ] **Step 2: Verify by build + existing tests** — `cd WatchtowerDesktop && swift build > /tmp/t11.log 2>&1; echo "exit=$?"` → 0; `swift test > /tmp/t11t.log 2>&1; echo "exit=$?"` → 0.

- [ ] **Step 3: Manual smoke via dev app** — `make app-dev`, open Settings: account #1 (migrated) listed with email; Add flow opens browser; after consent the list refreshes and the daemon restarts. (Owner will do the real second-account test — note it in the PR description.)

- [ ] **Step 4: Update `docs/app-guide.md`** — the Settings→Google section text (account list, add/remove, custom OAuth client) — required by the app-guide maintenance rule.

- [ ] **Step 5: Commit** — `git add WatchtowerDesktop/ docs/app-guide.md && git commit -m "feat(desktop): google accounts settings UI, retire gmailOAuthAvailable gate"`

---

### Task 12: Docs, inventory, final sweep

**Files:**
- Modify: `docs/inventory/inbox-pulse.md` (INBOX-09 wording: watermark rules apply per Gmail account watermark; semantics unchanged — no new contract number, extension of an existing one)
- Modify: `docs/inventory/memory.md` (note per-account `memory_gmail_last_extracted_ts`, `mail:` collision limitation)
- Modify: `CLAUDE.md` (Feature Notes: short Google multi-account paragraph; correct the "gmail.account_email" mention)
- Modify: `docs/superpowers/specs/2026-07-30-google-multi-account-design.md` (status → implemented)

- [ ] **Step 1: Write the doc updates** (each is 3–6 lines; keep inventory wording extensions clearly marked as extensions, not new numbered contracts).

- [ ] **Step 2: Full verification**

```bash
go build ./... && go vet ./... 2>&1 | tee /tmp/t12a.log; echo "exit=$?"
go test ./... 2>&1 | tee /tmp/t12b.log; echo "exit=$?"
golangci-lint run ./... 2>&1 | tee /tmp/t12c.log; echo "exit=$?"
cd WatchtowerDesktop && swift build > /tmp/t12d.log 2>&1; echo "exit=$?"; swift test > /tmp/t12e.log 2>&1; echo "exit=$?"
```

All exit=0.

- [ ] **Step 3: Live migration check on a COPY of the real DB** — `cp ~/.local/share/watchtower/whitebit/watchtower.db /tmp/wt-migrate-test.db` then open it with a scratch config pointing at the copy (`WATCHTOWER_CONFIG_PATH` is Desktop-only; for Go use a temp config yaml with a temp workspace dir containing the copy) and assert: account #1 exists with the real email, counts of `gmail_messages` unchanged, `inbox_items` gmail rows rewritten. Never run against the live DB (the daemon may hold it).

- [ ] **Step 4: Commit** — `git add docs/ CLAUDE.md && git commit -m "docs: google multi-account inventory + guide updates"`

- [ ] **Step 5: Run the local-review skill** over the branch diff before the PR (per house process).

---

## Self-review notes

- Spec coverage: schema/creds/auth (T1–3), sync/daemon (T4–6), CLI+seed (T7), inbox/identity (T8), memory (T9), Desktop (T10–11), docs/tests sweep (T12). `ical_uid` persisted in T5. Legacy aliases in T7. Mute-scope rewrite in T1.
- Consistency: `NewSyncer(..., accountID int64)` in both packages; `SetGoogleAccountAuthState(id, status, errMsg)`; `GetGmailAccountWatermark`/`SetGmailAccountWatermark`; `MemoryGmailWatermark(accountID)`; token file `google_token_<id>.json`; credentials `google_credentials_<id>.json`; channel key `gmail:<accountID>:<threadID>`.
- Known deliberate deviations an implementer must NOT "fix": keeping `NewTokenStore` (legacy path) alive for `ensureLegacyGoogleAccount`; not deduping events across accounts; not renaming `mail:` provenance.
