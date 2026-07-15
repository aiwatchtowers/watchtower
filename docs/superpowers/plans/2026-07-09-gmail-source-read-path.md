# Gmail Source (Read-Path) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect Gmail as an inbox source: messages from the Gmail Inbox are synced locally and flow into inbox/situations through the existing AI pipeline.

**Architecture:** A self-contained package `internal/gmail/` (OAuth + API client + Syncer), modeled on `internal/calendar/`, writes messages to the `gmail_messages` table. The detector `internal/inbox/gmail_detector.go` reads that table and creates `inbox_items` (`email_received`/`email_cc`); the existing pipeline continues from there unchanged. The daemon gets a `phaseGmailSync` phase; Desktop gets a Connect Gmail button.

**Tech Stack:** Go 1.25, `database/sql` + `modernc.org/sqlite`, goose migrations, raw `net/http` for the Gmail REST v1 API, SwiftUI + GRDB (Desktop).

**Spec:** `docs/superpowers/specs/2026-07-09-gmail-source-design.md`

## Global Constraints

- Go 1.25; SQLite via `modernc.org/sqlite` (`database/sql`), no CGO drivers.
- `MaxOpenConns(1)` for in-memory SQLite: detectors must **fully drain `rows` into a slice before issuing any next query** (otherwise deadlock) — see `calendar_detector.go`.
- Expanding an enum CHECK (`inbox_items.trigger_type`) requires the "table-recreation dance" (SQLite can't do `ALTER TABLE ... ADD CONSTRAINT`) — see `internal/db/migrations/00002_target_due_inbox.sql` for the pattern.
- Any schema change is mirrored into `internal/db/schema.sql`, new tables are added to `TestAllTablesExist`, and the golden snapshot is regenerated: `go test ./internal/db/ -run TestSchemaGolden -update`.
- The `internal/gmail` package **does not import** `internal/calendar` (Google credentials are wired together at the `cmd` level).
- Gmail OAuth scope: `https://www.googleapis.com/auth/gmail.modify` (write-back is a separate plan, but the scope is requested up front).
- Noise filter before AI: messages labeled `CATEGORY_PROMOTIONS`/`CATEGORY_SOCIAL` are not synced.
- Config defaults: `InitialHistoryDays=7`, `MaxMessagesPerSync=100`, `MaxBodyBytes=51200`.
- Check the actual test exit code (don't pipe through `tail`); Swift: `cd WatchtowerDesktop && swift build && swift test`.
- All commit messages end with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File Structure

**Created:**
- `internal/db/migrations/00016_gmail_source.sql` — schema (tables + watermark + trigger_type).
- `internal/db/gmail.go` — DB layer (model, upsert, detector reads, watermark, auth state).
- `internal/gmail/auth.go` — OAuth (TokenStore `gmail_token.json`, Login/Prepare/Complete).
- `internal/gmail/client.go` — Gmail REST v1 client (list/get, refresh).
- `internal/gmail/models.go` — domain type for a message.
- `internal/gmail/sync.go` — Syncer (initial/incremental, filter, upsert, watermark).
- `internal/inbox/gmail_detector.go` — `DetectGmail`.
- `cmd/gmail.go` — CLI `gmail login/logout/sync/status`.
- `WatchtowerDesktop/Sources/Services/GmailAuthService.swift` — Desktop connect service.
- Tests: `internal/db/gmail_test.go`, `internal/gmail/*_test.go`, `internal/inbox/gmail_detector_test.go`.

**Modified:**
- `internal/db/schema.sql` — schema mirror.
- `internal/db/db_test.go` — `TestAllTablesExist` (+`gmail_messages`, `gmail_auth_state`).
- `internal/db/testdata/schema_golden.sql` (or whatever the snapshot is named) — regeneration.
- `internal/config/config.go` — `GmailConfig` + field on `Config` + `SetDefault` in `Load`.
- `internal/config/defaults.go` — Gmail defaults.
- `internal/inbox/classifier.go` — `defaultClasses` (+email types).
- `internal/inbox/pipeline.go` — `detectAll` + `Run` + `RunFastDetection`.
- `internal/daemon/daemon.go` — Gmail field/setter/phase.
- `cmd/sync.go` — wiring the Gmail syncer into the daemon.
- `cmd/root.go` — registering the `gmail` command (if not done via `init()`).
- `WatchtowerDesktop/Sources/Views/Settings/SettingsView.swift` — `gmailSettingsSection`.
- `WatchtowerDesktop/Sources/Views/Inbox/InboxCardView.swift` — email-type `case`s.
- `WatchtowerDesktop/Tests/.../TestDatabase.swift` — schema sync.

---

## Task 1: Migration 00016 — schema

**Files:**
- Create: `internal/db/migrations/00016_gmail_source.sql`
- Modify: `internal/db/schema.sql`, `internal/db/db_test.go` (TestAllTablesExist)
- Test: `internal/db/migration_test.go` (or the existing migration test), `internal/db/schema_snapshot_test.go`

**Interfaces:**
- Produces: tables `gmail_messages`, `gmail_auth_state`; column `workspace.gmail_last_internal_date REAL NOT NULL DEFAULT 0`; `trigger_type` values `email_received`, `email_cc`.

- [ ] **Step 1: Write the migration**

Create `internal/db/migrations/00016_gmail_source.sql`. Up section: create the two tables, add the watermark column, then run the recreation dance for `inbox_items`. **Important:** the `CREATE TABLE inbox_items_new (...)` block copies the CURRENT definition of `inbox_items` from `schema.sql:447-485` in full (all columns through `composed_at` + `UNIQUE(channel_id, message_ts)`), changing only the `trigger_type` list, and reproduces all 7 indexes.

```sql
-- +goose Up
-- Gmail as an inbox source: message store, auth telemetry, sync watermark,
-- and two new inbox trigger types (email_received / email_cc).

CREATE TABLE IF NOT EXISTS gmail_messages (
    id             TEXT PRIMARY KEY,              -- Gmail message ID
    thread_id      TEXT NOT NULL DEFAULT '',
    from_email     TEXT NOT NULL DEFAULT '',
    from_name      TEXT NOT NULL DEFAULT '',
    to_json        TEXT NOT NULL DEFAULT '[]',    -- JSON array of recipient emails (To)
    cc_json        TEXT NOT NULL DEFAULT '[]',    -- JSON array of recipient emails (Cc)
    subject        TEXT NOT NULL DEFAULT '',
    snippet        TEXT NOT NULL DEFAULT '',      -- Gmail-provided preview (~200 chars)
    body_text      TEXT NOT NULL DEFAULT '',      -- full plain-text body (truncated at sync)
    internal_date  TEXT NOT NULL DEFAULT '',      -- ISO8601 message time
    labels_json    TEXT NOT NULL DEFAULT '[]',    -- JSON array of Gmail label IDs
    is_unread      INTEGER NOT NULL DEFAULT 0,
    permalink      TEXT NOT NULL DEFAULT '',
    synced_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_gmail_messages_thread ON gmail_messages(thread_id);
CREATE INDEX IF NOT EXISTS idx_gmail_messages_synced ON gmail_messages(synced_at);

CREATE TABLE IF NOT EXISTS gmail_auth_state (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    status TEXT NOT NULL DEFAULT 'ok',
    error TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
INSERT OR IGNORE INTO gmail_auth_state (id, status, error) VALUES (1, 'ok', '');

ALTER TABLE workspace ADD COLUMN gmail_last_internal_date REAL NOT NULL DEFAULT 0;

-- Expand inbox_items.trigger_type CHECK (recreation dance; see 00002).
PRAGMA defer_foreign_keys = ON;

CREATE TABLE inbox_items_new (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id      TEXT NOT NULL,
    message_ts      TEXT NOT NULL,
    thread_ts       TEXT NOT NULL DEFAULT '',
    sender_user_id  TEXT NOT NULL,
    trigger_type    TEXT NOT NULL CHECK(trigger_type IN (
        'mention','dm','thread_reply','reaction',
        'jira_assigned','jira_comment_mention','jira_comment_watching','jira_status_change','jira_priority_change',
        'calendar_invite','calendar_time_change','calendar_cancelled',
        'decision_made','briefing_ready',
        'target_due',
        'stream',
        'email_received','email_cc'
    )),
    snippet         TEXT NOT NULL DEFAULT '',
    context         TEXT NOT NULL DEFAULT '',
    raw_text        TEXT NOT NULL DEFAULT '',
    permalink       TEXT NOT NULL DEFAULT '',
    status          TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','resolved','dismissed','snoozed')),
    priority        TEXT NOT NULL DEFAULT 'medium' CHECK(priority IN ('high','medium','low')),
    ai_reason       TEXT NOT NULL DEFAULT '',
    resolved_reason TEXT NOT NULL DEFAULT '',
    snooze_until    TEXT NOT NULL DEFAULT '',
    waiting_user_ids TEXT NOT NULL DEFAULT '[]',
    target_id       INTEGER,
    read_at         TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    item_class      TEXT NOT NULL DEFAULT 'actionable' CHECK(item_class IN ('actionable','ambient')),
    archived_at     TEXT,
    archive_reason  TEXT DEFAULT '' CHECK(archive_reason IN ('','resolved','seen_expired','stale','dismissed')),
    why_matters     TEXT NOT NULL DEFAULT '',
    thread_digest   TEXT NOT NULL DEFAULT '',
    draft_reply     TEXT NOT NULL DEFAULT '',
    card_status     TEXT NOT NULL DEFAULT 'none' CHECK(card_status IN ('none','ready','failed')),
    card_generated_at TEXT,
    composed_at     TEXT,
    UNIQUE(channel_id, message_ts)
);

INSERT INTO inbox_items_new SELECT * FROM inbox_items;
DROP TABLE inbox_items;
ALTER TABLE inbox_items_new RENAME TO inbox_items;

CREATE INDEX IF NOT EXISTS idx_inbox_items_status ON inbox_items(status);
CREATE INDEX IF NOT EXISTS idx_inbox_items_priority ON inbox_items(priority);
CREATE INDEX IF NOT EXISTS idx_inbox_items_updated ON inbox_items(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_inbox_items_sender ON inbox_items(sender_user_id);
CREATE INDEX IF NOT EXISTS idx_inbox_items_snooze ON inbox_items(snooze_until);
CREATE INDEX IF NOT EXISTS idx_inbox_items_class_status ON inbox_items(item_class, status);
CREATE INDEX IF NOT EXISTS idx_inbox_items_archived ON inbox_items(archived_at);

-- +goose Down
PRAGMA defer_foreign_keys = ON;

CREATE TABLE inbox_items_old (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_id      TEXT NOT NULL,
    message_ts      TEXT NOT NULL,
    thread_ts       TEXT NOT NULL DEFAULT '',
    sender_user_id  TEXT NOT NULL,
    trigger_type    TEXT NOT NULL CHECK(trigger_type IN (
        'mention','dm','thread_reply','reaction',
        'jira_assigned','jira_comment_mention','jira_comment_watching','jira_status_change','jira_priority_change',
        'calendar_invite','calendar_time_change','calendar_cancelled',
        'decision_made','briefing_ready',
        'target_due',
        'stream'
    )),
    snippet         TEXT NOT NULL DEFAULT '',
    context         TEXT NOT NULL DEFAULT '',
    raw_text        TEXT NOT NULL DEFAULT '',
    permalink       TEXT NOT NULL DEFAULT '',
    status          TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','resolved','dismissed','snoozed')),
    priority        TEXT NOT NULL DEFAULT 'medium' CHECK(priority IN ('high','medium','low')),
    ai_reason       TEXT NOT NULL DEFAULT '',
    resolved_reason TEXT NOT NULL DEFAULT '',
    snooze_until    TEXT NOT NULL DEFAULT '',
    waiting_user_ids TEXT NOT NULL DEFAULT '[]',
    target_id       INTEGER,
    read_at         TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    item_class      TEXT NOT NULL DEFAULT 'actionable' CHECK(item_class IN ('actionable','ambient')),
    archived_at     TEXT,
    archive_reason  TEXT DEFAULT '' CHECK(archive_reason IN ('','resolved','seen_expired','stale','dismissed')),
    why_matters     TEXT NOT NULL DEFAULT '',
    thread_digest   TEXT NOT NULL DEFAULT '',
    draft_reply     TEXT NOT NULL DEFAULT '',
    card_status     TEXT NOT NULL DEFAULT 'none' CHECK(card_status IN ('none','ready','failed')),
    card_generated_at TEXT,
    composed_at     TEXT,
    UNIQUE(channel_id, message_ts)
);

INSERT INTO inbox_items_old SELECT * FROM inbox_items WHERE trigger_type NOT IN ('email_received','email_cc');
DROP TABLE inbox_items;
ALTER TABLE inbox_items_old RENAME TO inbox_items;

CREATE INDEX IF NOT EXISTS idx_inbox_items_status ON inbox_items(status);
CREATE INDEX IF NOT EXISTS idx_inbox_items_priority ON inbox_items(priority);
CREATE INDEX IF NOT EXISTS idx_inbox_items_updated ON inbox_items(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_inbox_items_sender ON inbox_items(sender_user_id);
CREATE INDEX IF NOT EXISTS idx_inbox_items_snooze ON inbox_items(snooze_until);
CREATE INDEX IF NOT EXISTS idx_inbox_items_class_status ON inbox_items(item_class, status);
CREATE INDEX IF NOT EXISTS idx_inbox_items_archived ON inbox_items(archived_at);

ALTER TABLE workspace DROP COLUMN gmail_last_internal_date;
DROP TABLE IF EXISTS gmail_auth_state;
DROP TABLE IF EXISTS gmail_messages;
```

- [ ] **Step 2: Mirror into schema.sql**

In `internal/db/schema.sql`: (a) add two `CREATE TABLE` statements (`gmail_messages` with indexes, `gmail_auth_state` + `INSERT OR IGNORE`) next to `calendar_auth_state` (~line 1007); (b) add `gmail_last_internal_date REAL NOT NULL DEFAULT 0` as the last column in `CREATE TABLE workspace` (after `compose_last_run_ts` — don't forget the comma before it); (c) in `CREATE TABLE inbox_items`, append `'email_received','email_cc'` to the `trigger_type` list (after `'stream'`).

- [ ] **Step 3: Write/extend the migration test**

Add to the existing migration test (or create `internal/db/gmail_migration_test.go`) a check that after `Open()` the tables exist and the email trigger works:

```go
func TestMigration00016GmailSource(t *testing.T) {
    database := openTestDB(t) // helper used elsewhere in the package
    // gmail tables exist
    for _, tbl := range []string{"gmail_messages", "gmail_auth_state"} {
        var name string
        err := database.QueryRow(`SELECT name FROM sqlite_master WHERE type='table' AND name=?`, tbl).Scan(&name)
        if err != nil {
            t.Fatalf("table %s missing: %v", tbl, err)
        }
    }
    // workspace watermark column present
    if _, err := database.Exec(`UPDATE workspace SET gmail_last_internal_date = 123.0`); err != nil {
        t.Fatalf("gmail_last_internal_date column missing: %v", err)
    }
    // new trigger_type accepted
    _, err := database.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type)
        VALUES ('t1','m1','from@x.com','email_received')`)
    if err != nil {
        t.Fatalf("email_received rejected: %v", err)
    }
}
```

(Check how the test DB is opened elsewhere in the package — reuse the same helper as the neighboring tests.)

- [ ] **Step 4: Add the tables to TestAllTablesExist**

In `internal/db/db_test.go`, add `"gmail_messages"` and `"gmail_auth_state"` to the list of expected tables (`TestAllTablesExist`, ~line 92).

- [ ] **Step 5: Run the tests, confirm they fail/pass as expected**

```bash
go test ./internal/db/ -run 'TestMigration00016GmailSource|TestAllTablesExist' -v > /tmp/t1.log 2>&1; echo "exit=$?"; tail -30 /tmp/t1.log
```
Expected: PASS for both.

- [ ] **Step 6: Regenerate the golden snapshot and run the whole db package**

```bash
go test ./internal/db/ -run TestSchemaGolden -update > /tmp/t1g.log 2>&1; echo "exit=$?"
go test ./internal/db/ > /tmp/t1all.log 2>&1; echo "exit=$?"; tail -20 /tmp/t1all.log
```
Expected: both commands exit=0.

- [ ] **Step 7: Commit**

```bash
git add internal/db/migrations/00016_gmail_source.sql internal/db/schema.sql internal/db/db_test.go internal/db/*_test.go internal/db/testdata/
git commit -m "feat(db): migration 00016 — gmail_messages, gmail_auth_state, email trigger types

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: DB access layer (`internal/db/gmail.go`)

**Files:**
- Create: `internal/db/gmail.go`, `internal/db/gmail_test.go`

**Interfaces:**
- Consumes: tables from Task 1.
- Produces:
  - type `GmailMessage struct { ID, ThreadID, FromEmail, FromName, ToJSON, CcJSON, Subject, Snippet, BodyText, InternalDate, LabelsJSON string; IsUnread bool; Permalink, SyncedAt, UpdatedAt string }`
  - `func (db *DB) UpsertGmailMessage(m GmailMessage, syncedAt string) error`
  - `func (db *DB) GmailMessagesSyncedAfter(sinceISO string) ([]GmailMessage, error)`
  - `func (db *DB) GetGmailLastInternalDate() (float64, error)`
  - `func (db *DB) SetGmailLastInternalDate(ts float64) error`
  - `func (db *DB) GetGmailAuthState() (GmailAuthState, error)` / `func (db *DB) SetGmailAuthState(status, errMsg string) error`
  - type `GmailAuthState struct { Status, Error, UpdatedAt string }`

- [ ] **Step 1: Write the DB layer test**

`internal/db/gmail_test.go`:

```go
func TestGmailUpsertAndQuery(t *testing.T) {
    database := openTestDB(t)
    m := GmailMessage{
        ID: "msg1", ThreadID: "thr1", FromEmail: "a@x.com", FromName: "A",
        ToJSON: `["me@x.com"]`, CcJSON: `[]`, Subject: "Hi", Snippet: "preview",
        BodyText: "full body", InternalDate: "2026-07-09T10:00:00Z",
        LabelsJSON: `["INBOX","UNREAD"]`, IsUnread: true,
        Permalink: "https://mail.google.com/#inbox/msg1",
    }
    if err := database.UpsertGmailMessage(m, "2026-07-09T10:00:01Z"); err != nil {
        t.Fatalf("upsert: %v", err)
    }
    // upsert again (idempotent update)
    m.Subject = "Hi again"
    if err := database.UpsertGmailMessage(m, "2026-07-09T10:00:02Z"); err != nil {
        t.Fatalf("re-upsert: %v", err)
    }
    got, err := database.GmailMessagesSyncedAfter("2026-07-09T00:00:00Z")
    if err != nil {
        t.Fatalf("query: %v", err)
    }
    if len(got) != 1 || got[0].Subject != "Hi again" || !got[0].IsUnread {
        t.Fatalf("unexpected rows: %+v", got)
    }
}

func TestGmailWatermark(t *testing.T) {
    database := openTestDB(t)
    if err := database.SetGmailLastInternalDate(1720519200); err != nil {
        t.Fatalf("set: %v", err)
    }
    got, err := database.GetGmailLastInternalDate()
    if err != nil || got != 1720519200 {
        t.Fatalf("got %v err %v", got, err)
    }
}

func TestGmailAuthState(t *testing.T) {
    database := openTestDB(t)
    if err := database.SetGmailAuthState("revoked", "invalid_grant"); err != nil {
        t.Fatalf("set: %v", err)
    }
    s, err := database.GetGmailAuthState()
    if err != nil || s.Status != "revoked" {
        t.Fatalf("got %+v err %v", s, err)
    }
}
```

- [ ] **Step 2: Confirm the test fails to compile/fails**

```bash
go test ./internal/db/ -run 'TestGmail' > /tmp/t2.log 2>&1; echo "exit=$?"; tail -20 /tmp/t2.log
```
Expected: FAIL (undefined: UpsertGmailMessage etc.).

- [ ] **Step 3: Implement `internal/db/gmail.go`**

Model the auth-state and watermark methods on `internal/db/calendar.go:301-325` and `internal/db/workspace.go` (`GetComposeLastRunTS`/`SetComposeLastRunTS`).

```go
package db

import (
    "database/sql"
    "errors"
    "fmt"
    "time"
)

// GmailMessage is one row of gmail_messages.
type GmailMessage struct {
    ID           string
    ThreadID     string
    FromEmail    string
    FromName     string
    ToJSON       string
    CcJSON       string
    Subject      string
    Snippet      string
    BodyText     string
    InternalDate string
    LabelsJSON   string
    IsUnread     bool
    Permalink    string
    SyncedAt     string
    UpdatedAt    string
}

// GmailAuthState mirrors the singleton gmail_auth_state row.
type GmailAuthState struct {
    Status    string
    Error     string
    UpdatedAt string
}

// UpsertGmailMessage inserts or updates a message, stamping synced_at/updated_at.
func (db *DB) UpsertGmailMessage(m GmailMessage, syncedAt string) error {
    unread := 0
    if m.IsUnread {
        unread = 1
    }
    _, err := db.Exec(`INSERT INTO gmail_messages
        (id, thread_id, from_email, from_name, to_json, cc_json, subject, snippet,
         body_text, internal_date, labels_json, is_unread, permalink, synced_at, updated_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
         thread_id=excluded.thread_id, from_email=excluded.from_email, from_name=excluded.from_name,
         to_json=excluded.to_json, cc_json=excluded.cc_json, subject=excluded.subject,
         snippet=excluded.snippet, body_text=excluded.body_text, internal_date=excluded.internal_date,
         labels_json=excluded.labels_json, is_unread=excluded.is_unread, permalink=excluded.permalink,
         synced_at=excluded.synced_at, updated_at=excluded.updated_at`,
        m.ID, m.ThreadID, m.FromEmail, m.FromName, m.ToJSON, m.CcJSON, m.Subject, m.Snippet,
        m.BodyText, m.InternalDate, m.LabelsJSON, unread, m.Permalink, syncedAt, syncedAt)
    if err != nil {
        return fmt.Errorf("upserting gmail message %s: %w", m.ID, err)
    }
    return nil
}

// GmailMessagesSyncedAfter returns messages whose synced_at is strictly after sinceISO.
func (db *DB) GmailMessagesSyncedAfter(sinceISO string) ([]GmailMessage, error) {
    rows, err := db.Query(`SELECT id, thread_id, from_email, from_name, to_json, cc_json,
        subject, snippet, body_text, internal_date, labels_json, is_unread, permalink, synced_at, updated_at
        FROM gmail_messages WHERE synced_at > ? ORDER BY internal_date ASC`, sinceISO)
    if err != nil {
        return nil, fmt.Errorf("querying gmail messages: %w", err)
    }
    defer rows.Close()
    var out []GmailMessage
    for rows.Next() {
        var m GmailMessage
        var unread int
        if err := rows.Scan(&m.ID, &m.ThreadID, &m.FromEmail, &m.FromName, &m.ToJSON, &m.CcJSON,
            &m.Subject, &m.Snippet, &m.BodyText, &m.InternalDate, &m.LabelsJSON, &unread,
            &m.Permalink, &m.SyncedAt, &m.UpdatedAt); err != nil {
            return nil, fmt.Errorf("scanning gmail message: %w", err)
        }
        m.IsUnread = unread != 0
        out = append(out, m)
    }
    return out, rows.Err()
}

// GetGmailLastInternalDate returns the sync watermark (unix seconds, 0 if unset).
func (db *DB) GetGmailLastInternalDate() (float64, error) {
    var ts float64
    err := db.QueryRow(`SELECT COALESCE(gmail_last_internal_date, 0) FROM workspace LIMIT 1`).Scan(&ts)
    if err != nil {
        if errors.Is(err, sql.ErrNoRows) {
            return 0, nil
        }
        return 0, fmt.Errorf("getting gmail watermark: %w", err)
    }
    return ts, nil
}

// SetGmailLastInternalDate advances the sync watermark.
func (db *DB) SetGmailLastInternalDate(ts float64) error {
    res, err := db.Exec(`UPDATE workspace SET gmail_last_internal_date = ? WHERE id = (SELECT id FROM workspace LIMIT 1)`, ts)
    if err != nil {
        return fmt.Errorf("setting gmail watermark: %w", err)
    }
    if n, _ := res.RowsAffected(); n == 0 {
        return fmt.Errorf("setting gmail watermark: no workspace row exists")
    }
    return nil
}

// GetGmailAuthState reads the singleton auth telemetry row.
func (db *DB) GetGmailAuthState() (GmailAuthState, error) {
    var s GmailAuthState
    err := db.QueryRow(`SELECT status, error, updated_at FROM gmail_auth_state WHERE id = 1`).
        Scan(&s.Status, &s.Error, &s.UpdatedAt)
    if err != nil {
        if errors.Is(err, sql.ErrNoRows) {
            return GmailAuthState{Status: "ok"}, nil
        }
        return GmailAuthState{}, fmt.Errorf("reading gmail_auth_state: %w", err)
    }
    return s, nil
}

// SetGmailAuthState upserts auth telemetry. status is one of "ok", "revoked", "error".
func (db *DB) SetGmailAuthState(status, errMsg string) error {
    now := time.Now().UTC().Format(time.RFC3339)
    _, err := db.Exec(`INSERT INTO gmail_auth_state (id, status, error, updated_at)
        VALUES (1, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET status=excluded.status, error=excluded.error, updated_at=excluded.updated_at`,
        status, errMsg, now)
    if err != nil {
        return fmt.Errorf("upserting gmail_auth_state: %w", err)
    }
    return nil
}
```

- [ ] **Step 4: Run the tests**

```bash
go test ./internal/db/ -run 'TestGmail' > /tmp/t2.log 2>&1; echo "exit=$?"; tail -20 /tmp/t2.log
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/db/gmail.go internal/db/gmail_test.go
git commit -m "feat(db): gmail_messages access layer, watermark, auth-state helpers

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Gmail OAuth (`internal/gmail/auth.go`)

**Files:**
- Create: `internal/gmail/auth.go`, `internal/gmail/auth_test.go`

**Interfaces:**
- Produces:
  - `type GoogleOAuthConfig struct { ClientID, ClientSecret string }`
  - `type OAuthToken struct { AccessToken, TokenType, RefreshToken, Expiry string }` (JSON tags as in calendar)
  - `type TokenStore` with `NewTokenStore(workspaceDir string) *TokenStore` → file `gmail_token.json`; methods `Load/Save/Delete/Exists/Path`
  - `func Login(ctx, cfg GoogleOAuthConfig, out io.Writer, opts ...LoginOptions) (*OAuthToken, error)`
  - `func Prepare(cfg GoogleOAuthConfig, customRedirectURI string) (*PrepareResult, error)`
  - `func Complete(ctx, cfg GoogleOAuthConfig, code, redirectURI string) (*OAuthToken, error)`
  - `var googleTokenEndpoint string` (exported within the package for client.go/tests)

- [ ] **Step 1: Copy calendar/auth.go as a base and adapt it**

Create `internal/gmail/auth.go` based on `internal/calendar/auth.go` (340 lines). Targeted changes:
- `package gmail`;
- `const gmailScope = "https://www.googleapis.com/auth/gmail.modify"`; remove `calendarEventsScope`/`calendarCalendarListScope`;
- in `buildAuthURL` — `"scope": {gmailScope}`;
- `NewTokenStore` → `filepath.Join(workspaceDir, "gmail_token.json")`;
- `defaultRedirectPort = 18511` (the next free range after Calendar's 18501-18510);
- `listenLocal` preferred ports `18511..18520`;
- success/error HTML: title "Watchtower — Gmail Connected", body text "Gmail has been linked to Watchtower.";
- in `Login`, the output lines: "Opening browser for Gmail authorization...";
- do **NOT** declare `DefaultGoogleClientID`/`DefaultGoogleClientSecret` in this package (credentials come in via cmd from `calendar.Default...` — see Task 9).

- [ ] **Step 2: Copy and adapt auth_test.go**

Create `internal/gmail/auth_test.go` based on `internal/calendar/auth_test.go`. Change the package to `gmail`, verify that `buildAuthURL` contains the `gmail.modify` scope and `access_type=offline`, that TokenStore writes/reads `gmail_token.json`, and Login/Complete against an `httptest.Server` (overriding `googleAuthEndpoint`/`googleTokenEndpoint`). Key new assertion:

```go
func TestBuildAuthURLHasGmailScope(t *testing.T) {
    u := buildAuthURL(GoogleOAuthConfig{ClientID: "cid"}, "http://127.0.0.1:18511/callback", "st")
    if !strings.Contains(u, url.QueryEscape("https://www.googleapis.com/auth/gmail.modify")) {
        t.Fatalf("gmail scope missing: %s", u)
    }
    if !strings.Contains(u, "access_type=offline") {
        t.Fatalf("offline access missing: %s", u)
    }
}
```

- [ ] **Step 3: Run the tests**

```bash
go test ./internal/gmail/ > /tmp/t3.log 2>&1; echo "exit=$?"; tail -30 /tmp/t3.log
```
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add internal/gmail/auth.go internal/gmail/auth_test.go
git commit -m "feat(gmail): OAuth (gmail.modify scope, gmail_token.json store)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Gmail API client (`internal/gmail/client.go` + `models.go`)

**Files:**
- Create: `internal/gmail/client.go`, `internal/gmail/models.go`, `internal/gmail/client_test.go`

**Interfaces:**
- Consumes: `GoogleOAuthConfig`, `googleTokenEndpoint` (Task 3).
- Produces:
  - `var ErrAuthRevoked = errors.New("gmail auth revoked")`
  - `func NewClient(ctx, refreshToken string, cfg GoogleOAuthConfig) (*Client, error)`
  - `func (c *Client) ListInboxMessageIDs(ctx, query string, maxResults int) ([]string, error)` — returns message IDs matching a `q=` query (e.g. `in:inbox newer_than:7d`)
  - `func (c *Client) GetMessage(ctx, id string) (*Message, error)`
  - `models.go`: `type Message struct { ID, ThreadID, FromEmail, FromName, Subject, Snippet, BodyText, InternalDate string; To, Cc []string; Labels []string; IsUnread bool; Permalink string }`

- [ ] **Step 1: Write models.go**

```go
package gmail

// Message is a parsed Gmail message ready for storage.
type Message struct {
    ID           string
    ThreadID     string
    FromEmail    string
    FromName     string
    To           []string
    Cc           []string
    Subject      string
    Snippet      string
    BodyText     string
    InternalDate string // ISO8601
    Labels       []string
    IsUnread     bool
    Permalink    string
}
```

- [ ] **Step 2: Write client_test.go (httptest)**

Gmail API: `GET {base}/users/me/messages?q=...&maxResults=N` → `{"messages":[{"id":"m1","threadId":"t1"}],"nextPageToken":""}`; `GET {base}/users/me/messages/m1?format=full` → `{"id","threadId","labelIds":[...],"snippet","internalDate":"<ms>","payload":{"headers":[{"name":"From","value":"A <a@x.com>"},...],"parts":[{"mimeType":"text/plain","body":{"data":"<base64url>"}}]}}`.

```go
func TestClientListAndGet(t *testing.T) {
    bodyB64 := base64.URLEncoding.EncodeToString([]byte("hello body"))
    mux := http.NewServeMux()
    mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
        if r.URL.Query().Get("q") == "" { t.Error("missing q") }
        fmt.Fprint(w, `{"messages":[{"id":"m1","threadId":"t1"}]}`)
    })
    mux.HandleFunc("/users/me/messages/m1", func(w http.ResponseWriter, r *http.Request) {
        fmt.Fprintf(w, `{"id":"m1","threadId":"t1","labelIds":["INBOX","UNREAD"],
            "snippet":"prev","internalDate":"1720519200000",
            "payload":{"headers":[
                {"name":"From","value":"Alice <a@x.com>"},
                {"name":"To","value":"me@x.com"},
                {"name":"Cc","value":"c@x.com"},
                {"name":"Subject","value":"Hi"}],
              "parts":[{"mimeType":"text/plain","body":{"data":%q}}]}}`, bodyB64)
    })
    srv := httptest.NewServer(mux)
    defer srv.Close()
    tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        fmt.Fprint(w, `{"access_token":"at"}`)
    }))
    defer tokenSrv.Close()

    oldBase, oldTok := gmailAPIBase, googleTokenEndpoint
    gmailAPIBase, googleTokenEndpoint = srv.URL, tokenSrv.URL
    defer func() { gmailAPIBase, googleTokenEndpoint = oldBase, oldTok }()

    c, err := NewClient(context.Background(), "refresh", GoogleOAuthConfig{ClientID: "cid"})
    if err != nil { t.Fatal(err) }
    ids, err := c.ListInboxMessageIDs(context.Background(), "in:inbox newer_than:7d", 100)
    if err != nil || len(ids) != 1 || ids[0] != "m1" { t.Fatalf("ids=%v err=%v", ids, err) }
    m, err := c.GetMessage(context.Background(), "m1")
    if err != nil { t.Fatal(err) }
    if m.FromEmail != "a@x.com" || m.FromName != "Alice" { t.Errorf("from parse: %+v", m) }
    if len(m.To) != 1 || m.To[0] != "me@x.com" { t.Errorf("to parse: %+v", m.To) }
    if m.Subject != "Hi" || m.BodyText != "hello body" { t.Errorf("subject/body: %+v", m) }
    if !m.IsUnread { t.Error("unread flag not set") }
    if m.InternalDate == "" { t.Error("internalDate not parsed") }
}
```

- [ ] **Step 3: Confirm the test fails**

```bash
go test ./internal/gmail/ -run TestClientListAndGet > /tmp/t4.log 2>&1; echo "exit=$?"; tail -20 /tmp/t4.log
```
Expected: FAIL (undefined NewClient/gmailAPIBase).

- [ ] **Step 4: Implement client.go**

Refresh/`ErrAuthRevoked`/`isInvalidGrant` — modeled on `internal/calendar/client.go:18-137`. Plus message parsing.

```go
package gmail

import (
    "context"
    "encoding/base64"
    "encoding/json"
    "errors"
    "fmt"
    "io"
    "net/http"
    "net/url"
    "strconv"
    "strings"
    "time"
)

var gmailAPIBase = "https://www.googleapis.com/gmail/v1"

var ErrAuthRevoked = errors.New("gmail auth revoked")

type Client struct {
    hc           *http.Client
    accessToken  string
    refreshToken string
    oauthCfg     GoogleOAuthConfig
}

func NewClient(ctx context.Context, refreshToken string, cfg GoogleOAuthConfig) (*Client, error) {
    c := &Client{hc: &http.Client{Timeout: 30 * time.Second}, refreshToken: refreshToken, oauthCfg: cfg}
    if err := c.refreshAccessToken(ctx); err != nil {
        return nil, fmt.Errorf("obtaining access token: %w", err)
    }
    return c, nil
}

func isInvalidGrant(body []byte) bool {
    var resp struct{ Error string `json:"error"` }
    if err := json.Unmarshal(body, &resp); err == nil && resp.Error == "invalid_grant" {
        return true
    }
    return strings.Contains(string(body), "invalid_grant")
}

func (c *Client) refreshAccessToken(ctx context.Context) error {
    data := url.Values{
        "grant_type":    {"refresh_token"},
        "refresh_token": {c.refreshToken},
        "client_id":     {c.oauthCfg.ClientID},
        "client_secret": {c.oauthCfg.ClientSecret},
    }
    req, err := http.NewRequestWithContext(ctx, http.MethodPost, googleTokenEndpoint, strings.NewReader(data.Encode()))
    if err != nil { return err }
    req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
    resp, err := c.hc.Do(req)
    if err != nil { return fmt.Errorf("token refresh request: %w", err) }
    defer resp.Body.Close()
    body, _ := io.ReadAll(resp.Body)
    if resp.StatusCode != http.StatusOK {
        if isInvalidGrant(body) { return fmt.Errorf("%w: %s", ErrAuthRevoked, body) }
        return fmt.Errorf("token refresh failed (%d): %s", resp.StatusCode, body)
    }
    var result struct{ AccessToken string `json:"access_token"` }
    if err := json.Unmarshal(body, &result); err != nil { return fmt.Errorf("decoding token response: %w", err) }
    c.accessToken = result.AccessToken
    return nil
}

// doGet performs an authenticated GET, retrying once on 401 after a token refresh.
func (c *Client) doGet(ctx context.Context, path string, params url.Values) ([]byte, error) {
    return c.doGetRetry(ctx, path, params, false)
}

func (c *Client) doGetRetry(ctx context.Context, path string, params url.Values, retried bool) ([]byte, error) {
    u := gmailAPIBase + path
    if len(params) > 0 { u += "?" + params.Encode() }
    req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
    if err != nil { return nil, err }
    req.Header.Set("Authorization", "Bearer "+c.accessToken)
    resp, err := c.hc.Do(req)
    if err != nil { return nil, fmt.Errorf("gmail GET %s: %w", path, err) }
    defer resp.Body.Close()
    body, _ := io.ReadAll(resp.Body)
    if resp.StatusCode == http.StatusUnauthorized && !retried {
        if err := c.refreshAccessToken(ctx); err != nil { return nil, err }
        return c.doGetRetry(ctx, path, params, true)
    }
    if resp.StatusCode != http.StatusOK {
        return nil, fmt.Errorf("gmail GET %s (%d): %s", path, resp.StatusCode, body)
    }
    return body, nil
}

// ListInboxMessageIDs returns message IDs matching the Gmail search query.
func (c *Client) ListInboxMessageIDs(ctx context.Context, query string, maxResults int) ([]string, error) {
    params := url.Values{"q": {query}, "maxResults": {strconv.Itoa(maxResults)}}
    body, err := c.doGet(ctx, "/users/me/messages", params)
    if err != nil { return nil, err }
    var resp struct {
        Messages []struct{ ID string `json:"id"` } `json:"messages"`
    }
    if err := json.Unmarshal(body, &resp); err != nil { return nil, fmt.Errorf("decoding list: %w", err) }
    ids := make([]string, 0, len(resp.Messages))
    for _, m := range resp.Messages { ids = append(ids, m.ID) }
    return ids, nil
}

type apiPart struct {
    MimeType string    `json:"mimeType"`
    Body     struct{ Data string `json:"data"` } `json:"body"`
    Parts    []apiPart `json:"parts"`
}

// GetMessage fetches and parses a single message in full format.
func (c *Client) GetMessage(ctx context.Context, id string) (*Message, error) {
    body, err := c.doGet(ctx, "/users/me/messages/"+id, url.Values{"format": {"full"}})
    if err != nil { return nil, err }
    var raw struct {
        ID           string   `json:"id"`
        ThreadID     string   `json:"threadId"`
        LabelIDs     []string `json:"labelIds"`
        Snippet      string   `json:"snippet"`
        InternalDate string   `json:"internalDate"` // unix millis, as string
        Payload      apiPart  `json:"payload"`
    }
    if err := json.Unmarshal(body, &raw); err != nil { return nil, fmt.Errorf("decoding message: %w", err) }

    m := &Message{
        ID: raw.ID, ThreadID: raw.ThreadID, Snippet: raw.Snippet, Labels: raw.LabelIDs,
        Permalink: "https://mail.google.com/mail/u/0/#inbox/" + raw.ID,
    }
    for _, l := range raw.LabelIDs {
        if l == "UNREAD" { m.IsUnread = true }
    }
    // headers
    var headers []struct{ Name, Value string }
    // payload headers live under raw.Payload; re-decode to reach them
    var payloadWithHeaders struct {
        Payload struct {
            Headers []struct{ Name, Value string `json:"value"` } `json:"headers"`
        } `json:"payload"`
    }
    _ = json.Unmarshal(body, &payloadWithHeaders)
    for _, h := range payloadWithHeaders.Payload.Headers {
        headers = append(headers, struct{ Name, Value string }{h.Name, h.Value})
    }
    for _, h := range headers {
        switch strings.ToLower(h.Name) {
        case "from":
            m.FromName, m.FromEmail = parseAddress(h.Value)
        case "to":
            m.To = parseAddressList(h.Value)
        case "cc":
            m.Cc = parseAddressList(h.Value)
        case "subject":
            m.Subject = h.Value
        }
    }
    if ms, err := strconv.ParseInt(raw.InternalDate, 10, 64); err == nil {
        m.InternalDate = time.UnixMilli(ms).UTC().Format(time.RFC3339)
    }
    m.BodyText = extractPlainText(raw.Payload)
    return m, nil
}

// extractPlainText walks the MIME tree for the first text/plain body (base64url).
func extractPlainText(p apiPart) string {
    if p.MimeType == "text/plain" && p.Body.Data != "" {
        if dec, err := base64.URLEncoding.DecodeString(p.Body.Data); err == nil {
            return string(dec)
        }
        // Gmail sometimes omits padding; retry with RawURLEncoding.
        if dec, err := base64.RawURLEncoding.DecodeString(p.Body.Data); err == nil {
            return string(dec)
        }
    }
    for _, sub := range p.Parts {
        if txt := extractPlainText(sub); txt != "" {
            return txt
        }
    }
    return ""
}

// parseAddress splits "Name <email>" into (name, email). Falls back to email-only.
func parseAddress(v string) (name, email string) {
    v = strings.TrimSpace(v)
    if i := strings.LastIndex(v, "<"); i >= 0 {
        email = strings.TrimSuffix(strings.TrimSpace(v[i+1:]), ">")
        name = strings.Trim(strings.TrimSpace(v[:i]), `"`)
        return name, strings.TrimSpace(email)
    }
    return "", v
}

// parseAddressList parses a comma-separated address header into emails.
func parseAddressList(v string) []string {
    var out []string
    for _, part := range strings.Split(v, ",") {
        if _, email := parseAddress(part); email != "" {
            out = append(out, email)
        }
    }
    return out
}
```

Note for the implementer: the `GetMessage` shown above decodes the body twice just to reach `payload.headers`. Simplify this during implementation — give `apiPart` a `Headers []struct{Name,Value string}` field and do a single `json.Unmarshal`. The test from Step 2 is the source of truth for behavior; the final parsing shape is up to you, as long as the test passes and there's no double decoding.

- [ ] **Step 5: Run the tests**

```bash
go test ./internal/gmail/ > /tmp/t4.log 2>&1; echo "exit=$?"; tail -30 /tmp/t4.log
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/gmail/client.go internal/gmail/models.go internal/gmail/client_test.go
git commit -m "feat(gmail): REST client — list/get inbox messages, MIME plain-text parse

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Gmail Syncer + config (`internal/gmail/sync.go`)

**Files:**
- Create: `internal/gmail/sync.go`, `internal/gmail/sync_test.go`
- Modify: `internal/config/config.go`, `internal/config/defaults.go`

**Interfaces:**
- Consumes: `Client` (Task 4), the DB layer (Task 2), `config.Config`.
- Produces:
  - `func NewSyncer(client *Client, database *db.DB, cfg *config.Config, logger *log.Logger) *Syncer`
  - `func (s *Syncer) Sync(ctx context.Context) (int, error)`
  - `config.GmailConfig{ Enabled bool; InitialHistoryDays, MaxMessagesPerSync, MaxBodyBytes int }`; a `Gmail GmailConfig` field on `config.Config`.

- [ ] **Step 1: Add GmailConfig to config**

In `internal/config/config.go`, next to `CalendarConfig`:

```go
// GmailConfig holds Gmail integration settings.
type GmailConfig struct {
    Enabled            bool `mapstructure:"enabled"`               // enable gmail sync (default: false)
    InitialHistoryDays int  `mapstructure:"initial_history_days"`  // days of inbox to backfill on first sync
    MaxMessagesPerSync int  `mapstructure:"max_messages_per_sync"` // per-cycle cap
    MaxBodyBytes       int  `mapstructure:"max_body_bytes"`        // truncate body_text beyond this
}
```

In the `Config` struct (after `Calendar CalendarConfig`):
```go
    Gmail           GmailConfig                 `mapstructure:"gmail"`
```

In `internal/config/defaults.go` (next to the Calendar defaults):
```go
    // Gmail defaults
    DefaultGmailEnabled            = false
    DefaultGmailInitialHistoryDays = 7
    DefaultGmailMaxMessagesPerSync = 100
    DefaultGmailMaxBodyBytes       = 51200
```

In `Load` (after the `calendar.sync_days_ahead` SetDefault):
```go
    v.SetDefault("gmail.enabled", DefaultGmailEnabled)
    v.SetDefault("gmail.initial_history_days", DefaultGmailInitialHistoryDays)
    v.SetDefault("gmail.max_messages_per_sync", DefaultGmailMaxMessagesPerSync)
    v.SetDefault("gmail.max_body_bytes", DefaultGmailMaxBodyBytes)
```

- [ ] **Step 2: Write sync_test.go**

Test: the initial sync (watermark=0) sends a `newer_than` query, syncs messages, filters out PROMOTIONS/SOCIAL, truncates the body, and advances the watermark to the maximum internalDate.

```go
func TestSyncFiltersAndUpserts(t *testing.T) {
    // messages: m1 normal, m2 promotions (must be skipped)
    mux := http.NewServeMux()
    mux.HandleFunc("/users/me/messages", func(w http.ResponseWriter, r *http.Request) {
        fmt.Fprint(w, `{"messages":[{"id":"m1"},{"id":"m2"}]}`)
    })
    mux.HandleFunc("/users/me/messages/m1", func(w http.ResponseWriter, r *http.Request) {
        fmt.Fprint(w, `{"id":"m1","threadId":"t1","labelIds":["INBOX","UNREAD"],"snippet":"s",
          "internalDate":"1720519200000","payload":{"headers":[{"name":"Subject","value":"Hi"},
          {"name":"From","value":"a@x.com"}],"parts":[{"mimeType":"text/plain","body":{"data":""}}]}}`)
    })
    mux.HandleFunc("/users/me/messages/m2", func(w http.ResponseWriter, r *http.Request) {
        fmt.Fprint(w, `{"id":"m2","threadId":"t2","labelIds":["INBOX","CATEGORY_PROMOTIONS"],
          "snippet":"promo","internalDate":"1720519300000","payload":{"headers":[]}}`)
    })
    srv := httptest.NewServer(mux); defer srv.Close()
    tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        fmt.Fprint(w, `{"access_token":"at"}`)
    })); defer tokenSrv.Close()
    oldBase, oldTok := gmailAPIBase, googleTokenEndpoint
    gmailAPIBase, googleTokenEndpoint = srv.URL, tokenSrv.URL
    defer func() { gmailAPIBase, googleTokenEndpoint = oldBase, oldTok }()

    database := db.OpenTestDB(t) // use the package's test DB helper
    cfg := &config.Config{}
    cfg.Gmail = config.GmailConfig{Enabled: true, InitialHistoryDays: 7, MaxMessagesPerSync: 100, MaxBodyBytes: 51200}
    c, _ := NewClient(context.Background(), "refresh", GoogleOAuthConfig{ClientID: "cid"})
    s := NewSyncer(c, database, cfg, nil)
    n, err := s.Sync(context.Background())
    if err != nil { t.Fatal(err) }
    if n != 1 { t.Fatalf("want 1 synced (promotions skipped), got %d", n) }
    rows, _ := database.GmailMessagesSyncedAfter("2000-01-01T00:00:00Z")
    if len(rows) != 1 || rows[0].ID != "m1" { t.Fatalf("stored rows: %+v", rows) }
}
```

(If `internal/db` doesn't export `OpenTestDB`, use the same in-memory DB setup that the existing `internal/calendar/sync_test.go` tests use.)

- [ ] **Step 3: Confirm the test fails**

```bash
go test ./internal/gmail/ -run TestSyncFiltersAndUpserts > /tmp/t5.log 2>&1; echo "exit=$?"; tail -20 /tmp/t5.log
```
Expected: FAIL (undefined NewSyncer).

- [ ] **Step 4: Implement sync.go**

Model the structure on `internal/calendar/sync.go`.

```go
package gmail

import (
    "context"
    "encoding/json"
    "errors"
    "fmt"
    "io"
    "log"
    "strings"
    "time"

    "watchtower/internal/config"
    "watchtower/internal/db"
)

// Syncer fetches Gmail inbox messages and stores them.
type Syncer struct {
    client *Client
    db     *db.DB
    cfg    *config.Config
    logger *log.Logger
}

func NewSyncer(client *Client, database *db.DB, cfg *config.Config, logger *log.Logger) *Syncer {
    if logger == nil {
        logger = log.New(io.Discard, "", 0)
    }
    return &Syncer{client: client, db: database, cfg: cfg, logger: logger}
}

// noiseLabels are Gmail categories we skip before AI ever sees them.
var noiseLabels = map[string]bool{"CATEGORY_PROMOTIONS": true, "CATEGORY_SOCIAL": true}

// Sync pulls inbox messages newer than the watermark, stores them, and advances
// the watermark. Returns the count of stored messages.
func (s *Syncer) Sync(ctx context.Context) (int, error) {
    days := s.cfg.Gmail.InitialHistoryDays
    if days <= 0 {
        days = config.DefaultGmailInitialHistoryDays
    }
    maxMsgs := s.cfg.Gmail.MaxMessagesPerSync
    if maxMsgs <= 0 {
        maxMsgs = config.DefaultGmailMaxMessagesPerSync
    }
    maxBody := s.cfg.Gmail.MaxBodyBytes
    if maxBody <= 0 {
        maxBody = config.DefaultGmailMaxBodyBytes
    }

    watermark, err := s.db.GetGmailLastInternalDate()
    if err != nil {
        return 0, fmt.Errorf("reading gmail watermark: %w", err)
    }
    query := fmt.Sprintf("in:inbox newer_than:%dd", days) // initial backfill window; watermark filters below

    ids, err := s.client.ListInboxMessageIDs(ctx, query, maxMsgs)
    if err != nil {
        s.recordAuthResult(err)
        if errors.Is(err, ErrAuthRevoked) {
            return 0, err
        }
        return 0, fmt.Errorf("listing gmail messages: %w", err)
    }
    s.recordAuthResult(nil)

    now := time.Now().UTC()
    syncedAt := now.Format(time.RFC3339)
    count := 0
    maxSeen := watermark

    for _, id := range ids {
        m, err := s.client.GetMessage(ctx, id)
        if err != nil {
            s.logger.Printf("gmail: fetch message %s: %v", id, err)
            continue
        }
        // Noise filter (before storage/AI).
        skip := false
        for _, l := range m.Labels {
            if noiseLabels[l] {
                skip = true
                break
            }
        }
        if skip {
            continue
        }
        // Watermark filter: skip already-seen messages (internalDate <= watermark).
        msgUnix := isoToUnix(m.InternalDate)
        if watermark > 0 && msgUnix <= watermark {
            continue
        }
        if msgUnix > maxSeen {
            maxSeen = msgUnix
        }
        body := m.BodyText
        if len(body) > maxBody {
            body = body[:maxBody]
        }
        toJSON, _ := json.Marshal(m.To)
        ccJSON, _ := json.Marshal(m.Cc)
        labelsJSON, _ := json.Marshal(m.Labels)
        row := db.GmailMessage{
            ID: m.ID, ThreadID: m.ThreadID, FromEmail: m.FromEmail, FromName: m.FromName,
            ToJSON: string(toJSON), CcJSON: string(ccJSON), Subject: m.Subject, Snippet: m.Snippet,
            BodyText: body, InternalDate: m.InternalDate, LabelsJSON: string(labelsJSON),
            IsUnread: m.IsUnread, Permalink: m.Permalink,
        }
        if err := s.db.UpsertGmailMessage(row, syncedAt); err != nil {
            s.logger.Printf("gmail: upsert %s: %v", m.ID, err)
            continue
        }
        count++
    }

    if maxSeen > watermark {
        if err := s.db.SetGmailLastInternalDate(maxSeen); err != nil {
            s.logger.Printf("gmail: advancing watermark: %v", err)
        }
    }
    return count, nil
}

func (s *Syncer) recordAuthResult(err error) {
    if s.db == nil {
        return
    }
    if err == nil {
        if dbErr := s.db.SetGmailAuthState("ok", ""); dbErr != nil {
            s.logger.Printf("gmail: clear auth state: %v", dbErr)
        }
        return
    }
    status := "error"
    if errors.Is(err, ErrAuthRevoked) {
        status = "revoked"
    }
    if dbErr := s.db.SetGmailAuthState(status, err.Error()); dbErr != nil {
        s.logger.Printf("gmail: record auth state: %v", dbErr)
    }
}

// isoToUnix converts an RFC3339 timestamp to unix seconds (0 on parse failure).
func isoToUnix(iso string) float64 {
    t, err := time.Parse(time.RFC3339, iso)
    if err != nil {
        return 0
    }
    return float64(t.Unix())
}

var _ = strings.TrimSpace // keep strings import if unused after edits
```

(Remove `var _ = strings.TrimSpace` if `strings` isn't needed — it's just a hint that the import might end up unused.)

- [ ] **Step 5: Run the gmail + config tests**

```bash
go test ./internal/gmail/ ./internal/config/ > /tmp/t5.log 2>&1; echo "exit=$?"; tail -30 /tmp/t5.log
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/gmail/sync.go internal/gmail/sync_test.go internal/config/config.go internal/config/defaults.go
git commit -m "feat(gmail): syncer with watermark, noise filter, body truncation + config

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Gmail detector (`internal/inbox/gmail_detector.go`)

**Files:**
- Create: `internal/inbox/gmail_detector.go`, `internal/inbox/gmail_detector_test.go`
- Modify: `internal/inbox/classifier.go`

**Interfaces:**
- Consumes: `db.GmailMessagesSyncedAfter` (Task 2), `db.CreateInboxItem`, `DefaultItemClass`.
- Produces: `func DetectGmail(ctx context.Context, database *db.DB, myEmail string, sinceTS time.Time) (int, error)`

- [ ] **Step 1: Extend classifier defaultClasses**

In `internal/inbox/classifier.go`, add to the `defaultClasses` map:
```go
    "email_received":        "actionable",
    "email_cc":              "ambient",
```

- [ ] **Step 2: Write gmail_detector_test.go**

```go
func TestDetectGmailReceivedVsCC(t *testing.T) {
    database := openInboxTestDB(t) // same helper the calendar detector test uses
    syncedAt := "2026-07-09T10:00:00Z"
    // m1: myEmail in To → email_received
    _ = database.UpsertGmailMessage(db.GmailMessage{
        ID: "m1", ThreadID: "t1", FromEmail: "a@x.com", Subject: "Direct",
        Snippet: "hello", ToJSON: `["me@x.com"]`, CcJSON: `[]`,
        InternalDate: "2026-07-09T09:00:00Z", Permalink: "p1",
    }, syncedAt)
    // m2: myEmail only in Cc → email_cc
    _ = database.UpsertGmailMessage(db.GmailMessage{
        ID: "m2", ThreadID: "t2", FromEmail: "b@x.com", Subject: "Copied",
        Snippet: "fyi", ToJSON: `["other@x.com"]`, CcJSON: `["me@x.com"]`,
        InternalDate: "2026-07-09T09:30:00Z", Permalink: "p2",
    }, syncedAt)
    // m3: myEmail nowhere → skipped
    _ = database.UpsertGmailMessage(db.GmailMessage{
        ID: "m3", ThreadID: "t3", FromEmail: "c@x.com", Subject: "None",
        ToJSON: `["x@x.com"]`, CcJSON: `[]`, InternalDate: "2026-07-09T09:40:00Z",
    }, syncedAt)

    since := time.Date(2026, 7, 9, 0, 0, 0, 0, time.UTC)
    n, err := DetectGmail(context.Background(), database, "me@x.com", since)
    if err != nil { t.Fatal(err) }
    if n != 2 { t.Fatalf("want 2 items, got %d", n) }

    got := inboxTriggerFor(t, database, "t1") // helper: read trigger_type by channel_id
    if got != "email_received" { t.Errorf("m1 trigger=%s", got) }
    if inboxTriggerFor(t, database, "t2") != "email_cc" { t.Errorf("m2 wrong trigger") }

    // Idempotent: second run creates nothing.
    n2, _ := DetectGmail(context.Background(), database, "me@x.com", since)
    if n2 != 0 { t.Fatalf("want 0 on re-run, got %d", n2) }
}
```

(Implement small helpers `openInboxTestDB` and `inboxTriggerFor` modeled on the existing detector tests in the package, e.g. `calendar_detector_test.go`, if it exists; otherwise use a direct `database.QueryRow`.)

- [ ] **Step 3: Confirm the test fails**

```bash
go test ./internal/inbox/ -run TestDetectGmail > /tmp/t6.log 2>&1; echo "exit=$?"; tail -20 /tmp/t6.log
```
Expected: FAIL (undefined DetectGmail).

- [ ] **Step 4: Implement gmail_detector.go**

Model it on `internal/inbox/calendar_detector.go` (fully draining rows before any inserts is handled by `GmailMessagesSyncedAfter`, which drains into a slice itself).

```go
package inbox

import (
    "context"
    "encoding/json"
    "fmt"
    "time"

    "watchtower/internal/db"
)

// DetectGmail scans gmail_messages synced after sinceTS and creates one inbox
// item per message that involves myEmail. Trigger type is email_received when
// myEmail is a To recipient, otherwise email_cc (Cc only). Each message is
// deduplicated on (thread_id, message_id, trigger_type) so repeated calls are
// idempotent.
func DetectGmail(ctx context.Context, database *db.DB, myEmail string, sinceTS time.Time) (int, error) {
    if myEmail == "" {
        return 0, nil
    }
    sinceISO := sinceTS.UTC().Format(time.RFC3339)

    // GmailMessagesSyncedAfter fully drains its rows into a slice before we
    // issue any dedup/insert query below — required for in-memory SQLite with
    // MaxOpenConns(1) (see calendar_detector.go).
    msgs, err := database.GmailMessagesSyncedAfter(sinceISO)
    if err != nil {
        return 0, fmt.Errorf("gmail_detector: query messages: %w", err)
    }

    created := 0
    for _, m := range msgs {
        var to, cc []string
        _ = json.Unmarshal([]byte(m.ToJSON), &to)
        _ = json.Unmarshal([]byte(m.CcJSON), &cc)

        trig := ""
        if containsEmail(to, myEmail) {
            trig = "email_received"
        } else if containsEmail(cc, myEmail) {
            trig = "email_cc"
        }
        if trig == "" {
            continue // message doesn't involve me
        }

        exists, err := gmailInboxExists(database, m.ThreadID, m.ID, trig)
        if err != nil {
            return created, fmt.Errorf("gmail_detector: dedup check: %w", err)
        }
        if exists {
            continue
        }

        snippet := m.Subject
        if m.Snippet != "" {
            snippet = m.Subject + " — " + m.Snippet
        }
        item := db.InboxItem{
            ChannelID:    m.ThreadID,
            MessageTS:    m.ID,
            SenderUserID: m.FromEmail,
            TriggerType:  trig,
            Snippet:      snippet,
            Permalink:    m.Permalink,
            ItemClass:    DefaultItemClass(trig),
            Status:       "pending",
            Priority:     "medium",
        }
        if _, err := database.CreateInboxItem(item); err != nil {
            return created, fmt.Errorf("gmail_detector: create inbox item for %s: %w", m.ID, err)
        }
        created++
    }
    return created, nil
}

// containsEmail reports whether target is present in addrs (case-insensitive).
func containsEmail(addrs []string, target string) bool {
    for _, a := range addrs {
        if equalFoldEmail(a, target) {
            return true
        }
    }
    return false
}

func equalFoldEmail(a, b string) bool {
    return len(a) == len(b) && toLowerEmail(a) == toLowerEmail(b)
}

func toLowerEmail(s string) string {
    b := []byte(s)
    for i, c := range b {
        if c >= 'A' && c <= 'Z' {
            b[i] = c + 32
        }
    }
    return string(b)
}

// gmailInboxExists dedups on (thread_id as channel_id, message_id as message_ts, trigger_type).
// Inlined to avoid symbol collisions with other detectors.
func gmailInboxExists(database *db.DB, threadID, messageID, triggerType string) (bool, error) {
    var count int
    err := database.QueryRow(`SELECT COUNT(*) FROM inbox_items
        WHERE channel_id = ? AND message_ts = ? AND trigger_type = ?`,
        threadID, messageID, triggerType).Scan(&count)
    if err != nil {
        return false, err
    }
    return count > 0, nil
}
```

Note: `equalFoldEmail` compares by length + lowercase ASCII — sufficient for email addresses. If the package already has a util for case-insensitive comparison, use it instead of these three helpers (DRY).

- [ ] **Step 5: Run the tests**

```bash
go test ./internal/inbox/ -run TestDetectGmail > /tmp/t6.log 2>&1; echo "exit=$?"; tail -20 /tmp/t6.log
```
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/inbox/gmail_detector.go internal/inbox/gmail_detector_test.go internal/inbox/classifier.go
git commit -m "feat(inbox): gmail detector — email_received/email_cc from gmail_messages

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Pipeline wiring (`detectAll`, `Run`, `RunFastDetection`)

**Files:**
- Modify: `internal/inbox/pipeline.go`
- Test: `internal/inbox/pipeline_test.go` (or the existing one)

**Interfaces:**
- Consumes: `DetectGmail` (Task 6), `p.currentUserEmail`.
- Produces: an extended `detectAll(...) (slack, jira, cal, gmail, wt int, err error)` signature.

- [ ] **Step 1: Extend detectAll**

In `internal/inbox/pipeline.go`, in `detectAll` (~line 500), change the signature to
`(slack, jira, cal, gmail, wt int, err error)` and add, after the Calendar block:

```go
    if n, e := DetectGmail(ctx, p.db, p.currentUserEmail, sinceTime); e != nil {
        p.logger.Printf("inbox: gmail detect error: %v", e)
        errs = append(errs, fmt.Errorf("gmail: %w", e))
    } else {
        gmail = n
    }
```
and `return slack, jira, cal, gmail, wt, errors.Join(errs...)`.

- [ ] **Step 2: Update both call sites**

In `Run` (~line 373):
```go
    createdSlack, createdJira, createdCalendar, createdGmail, createdWatchtower, detectErr := p.detectAll(ctx, currentUserID, lastTS, sinceTime, true)
    created := createdSlack + createdJira + createdCalendar + createdGmail + createdWatchtower
```

In `RunFastDetection` (~line 483):
```go
    createdSlack, createdJira, createdCalendar, createdGmail, _, _ := p.detectAll(ctx, currentUserID, lastTS, sinceTime, false)
    created := createdSlack + createdJira + createdCalendar + createdGmail
```
and update the log line:
```go
    p.logger.Printf("inbox fast: +%d new (S%d J%d C%d G%d), %d auto-resolved",
        created, createdSlack, createdJira, createdCalendar, createdGmail, resolved)
```

- [ ] **Step 3: Test — an email reaches the inbox via RunFastDetection**

Add to the pipeline test (use the existing way of constructing a `Pipeline` with an in-memory DB; set `p.SetCurrentUser("U1", "me@x.com")`):

```go
func TestRunFastDetectionPicksUpGmail(t *testing.T) {
    p, database := newTestPipeline(t) // existing helper
    p.SetCurrentUser("U1", "me@x.com")
    _ = database.UpsertGmailMessage(db.GmailMessage{
        ID: "g1", ThreadID: "th1", FromEmail: "a@x.com", Subject: "Ping",
        ToJSON: `["me@x.com"]`, CcJSON: `[]`, InternalDate: "2026-07-09T09:00:00Z",
    }, time.Now().UTC().Format(time.RFC3339))
    if err := p.RunFastDetection(context.Background()); err != nil {
        t.Fatal(err)
    }
    var n int
    _ = database.QueryRow(`SELECT COUNT(*) FROM inbox_items WHERE trigger_type='email_received'`).Scan(&n)
    if n != 1 {
        t.Fatalf("want 1 email inbox item, got %d", n)
    }
}
```

(If there's no ready-made `newTestPipeline`, construct a `Pipeline` the same way the neighboring tests in the file do.)

- [ ] **Step 4: Run the inbox package tests**

```bash
go test ./internal/inbox/ > /tmp/t7.log 2>&1; echo "exit=$?"; tail -30 /tmp/t7.log
```
Expected: PASS (including existing tests — the `detectAll` signature is used only within the package).

- [ ] **Step 5: Commit**

```bash
git add internal/inbox/pipeline.go internal/inbox/pipeline_test.go
git commit -m "feat(inbox): wire gmail detector into detectAll / Run / RunFastDetection

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Daemon + sync.go wiring

**Files:**
- Modify: `internal/daemon/daemon.go`, `cmd/sync.go`
- Test: `internal/daemon/daemon_test.go`

**Interfaces:**
- Consumes: `gmail.NewSyncer`, `gmail.Syncer.Sync`, `gmail.NewClient`, `gmail.NewTokenStore`, `gmail.ErrAuthRevoked`.
- Produces: `func (d *Daemon) SetGmailSyncer(s *gmail.Syncer)`; a `phaseGmailSync` phase.

- [ ] **Step 1: daemon field + setter + phase + call**

In `internal/daemon/daemon.go`:
- import `"watchtower/internal/gmail"`;
- a field next to `calendarSyncer` (~line 63): `gmailSyncer *gmail.Syncer`;
- a setter next to `SetCalendarSyncer` (~line 130):
```go
// SetGmailSyncer sets the Gmail syncer for post-sync mail fetch.
func (d *Daemon) SetGmailSyncer(s *gmail.Syncer) {
    d.gmailSyncer = s
}
```
- a call in `runCycle` right after `d.phaseCalendarSync(ctx)` (~line 215): `d.phaseGmailSync(ctx)`;
- a phase method next to `phaseCalendarSync` (~line 313):
```go
// phaseGmailSync pulls Gmail inbox messages. Lightweight, runs every cycle.
func (d *Daemon) phaseGmailSync(ctx context.Context) {
    if d.gmailSyncer == nil {
        return
    }
    n, err := d.gmailSyncer.Sync(ctx)
    if err != nil {
        d.logger.Printf("gmail sync error: %v", err)
    } else if n > 0 {
        d.logger.Printf("gmail: %d messages synced", n)
    }
}
```

- [ ] **Step 2: cmd/sync.go wiring**

In `cmd/sync.go`, right after the Calendar block (~line 355, before `return d.Run(ctx)`):

```go
        // Wire gmail syncer if token exists.
        gmailStore := gmail.NewTokenStore(cfg.WorkspaceDir())
        if gmailStore.Exists() {
            gc := resolveGoogleOAuthConfig() // calendar.GoogleOAuthConfig
            gmailToken, err := gmailStore.Load()
            if err != nil {
                logger.Printf("gmail: failed to load token: %v", err)
            } else {
                gmClient, err := gmail.NewClient(ctx, gmailToken.RefreshToken,
                    gmail.GoogleOAuthConfig{ClientID: gc.ClientID, ClientSecret: gc.ClientSecret})
                if err != nil {
                    logger.Printf("gmail: failed to create client: %v", err)
                    status := "error"
                    if errors.Is(err, gmail.ErrAuthRevoked) {
                        status = "revoked"
                    }
                    if dbErr := database.SetGmailAuthState(status, err.Error()); dbErr != nil {
                        logger.Printf("gmail: failed to record auth state: %v", dbErr)
                    }
                } else {
                    d.SetGmailSyncer(gmail.NewSyncer(gmClient, database, cfg, logger))
                }
            }
        }
```
Add `"watchtower/internal/gmail"` to the imports of `cmd/sync.go`.

- [ ] **Step 3: Daemon nil-guard test**

Add to `internal/daemon/daemon_test.go`:
```go
func TestPhaseGmailSyncNilGuard(t *testing.T) {
    d := &Daemon{logger: log.New(io.Discard, "", 0)}
    // No syncer set — must be a no-op, not a panic.
    d.phaseGmailSync(context.Background())
}
```
(Construct the `Daemon` the same way the neighboring daemon tests do; if the phase is private and the test lives in a different package, put the test in `package daemon`.)

- [ ] **Step 4: Run the build and tests**

```bash
go build ./... > /tmp/t8b.log 2>&1; echo "build=$?"; tail -20 /tmp/t8b.log
go test ./internal/daemon/ ./cmd/ > /tmp/t8.log 2>&1; echo "test=$?"; tail -20 /tmp/t8.log
```
Expected: build=0, test=0.

- [ ] **Step 5: Commit**

```bash
git add internal/daemon/daemon.go cmd/sync.go internal/daemon/daemon_test.go
git commit -m "feat(daemon): gmail sync phase + wire syncer in sync command

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: CLI (`cmd/gmail.go`)

**Files:**
- Create: `cmd/gmail.go`, `cmd/gmail_test.go`

**Interfaces:**
- Consumes: `gmail.*` (Tasks 3-5), `resolveGoogleOAuthConfig` (`cmd/calendar.go:410`), `openDatabaseForWorkspace`/equivalent (see how `cmd/calendar.go` does it).
- Produces: a `gmail` command with `login/logout/sync/status` subcommands.

- [ ] **Step 1: Implement cmd/gmail.go**

Model it on `cmd/calendar.go` (login/logout/sync/status). Key differences: `gmail.NewTokenStore`, `gmail.Login`, `gmail.NewClient`, `gmail.NewSyncer`, converting credentials via `resolveGoogleOAuthConfig()` → `gmail.GoogleOAuthConfig{...}`; status reads `cfg.Gmail.Enabled` and `store.Path()`. Register subcommands via `init()` + `rootCmd.AddCommand(gmailCmd)` (as in `cmd/calendar.go:68`).

Skeleton:
```go
package cmd

import (
    "errors"
    "fmt"

    "github.com/spf13/cobra"
    "watchtower/internal/gmail"
)

var gmailCmd = &cobra.Command{Use: "gmail", Short: "Gmail integration"}

func init() {
    gmailLoginCmd.Flags().Bool("no-open", false, "print the authorize URL instead of opening a browser")
    gmailCmd.AddCommand(gmailLoginCmd, gmailLogoutCmd, gmailSyncCmd, gmailStatusCmd)
    rootCmd.AddCommand(gmailCmd)
}

func gmailOAuthConfig() gmail.GoogleOAuthConfig {
    c := resolveGoogleOAuthConfig()
    return gmail.GoogleOAuthConfig{ClientID: c.ClientID, ClientSecret: c.ClientSecret}
}
```
`gmailLoginCmd`/`gmailLogoutCmd`/`gmailSyncCmd`/`gmailStatusCmd` — modeled on the corresponding `runCalendar*` functions in `cmd/calendar.go`, substituting `gmail.*` and `gmailOAuthConfig()`. `login` uses `gmail.Login(ctx, gmailOAuthConfig(), os.Stdout, gmail.LoginOptions{SkipBrowserOpen: noOpen})` and `store.Save(token)`, then `database.SetGmailAuthState("ok","")`. `sync` — `store.Load()` → `gmail.NewClient` → `gmail.NewSyncer(...).Sync(ctx)`.

- [ ] **Step 2: Test — the command is registered and the OAuth config converts correctly**

`cmd/gmail_test.go`:
```go
func TestGmailCommandRegistered(t *testing.T) {
    found := false
    for _, c := range rootCmd.Commands() {
        if c.Name() == "gmail" {
            found = true
            names := map[string]bool{}
            for _, sub := range c.Commands() {
                names[sub.Name()] = true
            }
            for _, want := range []string{"login", "logout", "sync", "status"} {
                if !names[want] {
                    t.Errorf("missing subcommand %s", want)
                }
            }
        }
    }
    if !found {
        t.Fatal("gmail command not registered")
    }
}
```

- [ ] **Step 3: Run the build and tests**

```bash
go build ./... > /tmp/t9b.log 2>&1; echo "build=$?"; tail -20 /tmp/t9b.log
go test ./cmd/ -run TestGmail > /tmp/t9.log 2>&1; echo "test=$?"; tail -20 /tmp/t9.log
```
Expected: build=0, test=0.

- [ ] **Step 4: Manual CLI check (status without a token)**

```bash
go run . gmail status > /tmp/t9m.log 2>&1; echo "exit=$?"; cat /tmp/t9m.log
```
Expected: prints "not connected" (or similar), exit=0 with no panic.

- [ ] **Step 5: Commit**

```bash
git add cmd/gmail.go cmd/gmail_test.go
git commit -m "feat(cmd): gmail login/logout/sync/status commands

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Desktop — Connect Gmail + card visuals

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/GmailAuthService.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Settings/SettingsView.swift`, `WatchtowerDesktop/Sources/Views/Inbox/InboxCardView.swift`, `WatchtowerDesktop/Tests/.../TestDatabase.swift` (schema sync)

**Interfaces:**
- Consumes: CLI commands `gmail login/logout/status` (Task 9); the `config.gmailEnabled` field (if a Desktop config layer exists — otherwise just connect/disconnect).
- Produces: `GmailAuthService` (`isConnected/isAuthenticating/error`, `connect/cancelConnect/disconnect/checkStatus`).

- [ ] **Step 1: GmailAuthService.swift**

Copy `WatchtowerDesktop/Sources/Services/GoogleAuthService.swift` to `GmailAuthService.swift`, replacing:
- the class name → `GmailAuthService`;
- process arguments `["calendar", "login"]` → `["gmail", "login"]`, `["calendar", "logout"]` → `["gmail", "logout"]`;
- in `checkStatus()`, the scan for `*/google_token.json` → `*/gmail_token.json`.

- [ ] **Step 2: gmailSettingsSection in SettingsView.swift**

Modeled on `calendarSettingsSection` (`SettingsView.swift:373-429`), add:
- `@State private var gmailAuth = GmailAuthService()` next to `googleAuth` (~line 46);
- a `Section("Gmail")` with the same structure: connected → green checkmark + Disconnect + an "Enable Gmail sync" toggle (writes `config.gmailEnabled`, if the field exists); not connected → a Connect button (`gmailAuth.connect()`), ProgressView+Cancel while `isAuthenticating`, red error text;
- wire `gmailSettingsSection` into the form body next to `calendarSettingsSection`.

If the Desktop config doesn't have `gmailEnabled` — add it modeled on `calendarEnabled` (find the `calendarEnabled` definition in the Desktop config model and mirror it).

- [ ] **Step 3: InboxCardView email types**

In `WatchtowerDesktop/Sources/Views/Inbox/InboxCardView.swift`, in the three `switch item.triggerType` statements:
- `triggerLabel` (~260): `case "email_received", "email_cc": return "Email"`;
- `triggerSymbol` (~278): `case "email_received", "email_cc": return "envelope"`;
- `triggerColor` (~296): `case "email_received", "email_cc": return .blue`.

- [ ] **Step 4: Sync TestDatabase.swift**

Find the file under `WatchtowerDesktop/Tests/` that creates the test schema (TestDatabase.swift). Add `CREATE TABLE gmail_messages (...)` and `gmail_auth_state`, and expand the `inbox_items.trigger_type` CHECK with `email_received`/`email_cc` — exactly as in the Task 1 migration (otherwise Swift tests that read these tables/types will drift from the schema — a known pitfall in this repo).

- [ ] **Step 5: Build and test Desktop**

```bash
cd WatchtowerDesktop && swift build > /tmp/t10b.log 2>&1; echo "build=$?"; tail -30 /tmp/t10b.log
swift test > /tmp/t10.log 2>&1; echo "test=$?"; tail -30 /tmp/t10.log
```
Expected: build=0, test=0.

- [ ] **Step 6: Commit**

```bash
cd /Users/user/PhpstormProjects/watchtower
git add WatchtowerDesktop/
git commit -m "feat(desktop): Connect Gmail settings + email card visuals

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Final Verification (after all tasks)

- [ ] **Full Go run**

```bash
gofmt -l internal/ cmd/ > /tmp/fmt.log 2>&1; echo "gofmt-dirty=$(wc -l < /tmp/fmt.log)"
go vet ./... > /tmp/vet.log 2>&1; echo "vet=$?"; tail -20 /tmp/vet.log
go build ./... > /tmp/build.log 2>&1; echo "build=$?"
go test ./... > /tmp/all.log 2>&1; echo "test=$?"; tail -30 /tmp/all.log
```
Expected: gofmt-dirty=0, vet=0, build=0, test=0.

- [ ] **Local review gate before the PR:** run the `local-review` skill (CI mirror + reviewer panel) against the branch diff, triage the findings, and record them.

- [ ] **Update the app guide** (`docs/app-guide.md`) — add a mention of Connect Gmail and the fact that emails flow into inbox/situations (injected into the chatbot's system prompt — the guide-maintenance rule).

- [ ] **Update the inventory doc** as needed (`docs/inventory/inbox-pulse.md` / `dashboard.md`) — new email trigger types as a source; verify this doesn't violate INBOX-01/09.

---

## Self-Review (filled in by the plan's author)

**Spec coverage:**
- OAuth (gmail.modify, gmail_token.json, self-contained) → Task 3, Task 9 (credentials). ✓
- `gmail_messages` + `gmail_auth_state` tables + watermark → Task 1, Task 2. ✓
- Sync (initial/incremental, noise filter, body truncation) → Task 5. ✓
- Detector (received/cc, dedup, snippet=subject+preview) → Task 6. ✓
- classifier defaultClasses → Task 6 Step 1. ✓
- pipeline detectAll/Run/RunFastDetection → Task 7. ✓
- daemon phase + cmd/sync wiring → Task 8. ✓
- CLI → Task 9. ✓
- Desktop connect + card visuals + TestDatabase sync → Task 10. ✓
- AI processing of emails via the existing triage/compose/situation-card flow — ensured by the detector creating ordinary `inbox_items`; snippet=subject+preview (Task 6) gives triage context; the full body_text is stored (Task 1/5) for the strong tier. ✓ (Prompts are unchanged — per the spec.)
- Out-of-scope work (email digests = Plan 2, write-back = Plan 3) — not included. ✓

**Placeholder scan:** no TBD/"handle errors"; code is provided for all new files; for copy-from-sample files (auth.go, cmd/gmail.go, Desktop) the exact source file and deltas are specified. ✓

**Type consistency:** `GmailMessage` (db) and `Message` (gmail) are separate layers, converted in Task 5; `GoogleOAuthConfig` is defined in `gmail` (Task 3), converted from `calendar.GoogleOAuthConfig` at the cmd level (Tasks 8, 9); the new `detectAll` signature is consistent between Task 7 Step 1 and both call sites. ✓
