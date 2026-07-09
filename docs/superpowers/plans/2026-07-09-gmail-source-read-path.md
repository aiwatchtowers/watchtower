# Gmail Source (Read-Path) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Подключить Gmail как источник inbox: письма из Gmail Inbox синхронизируются локально и попадают в inbox/ситуации через существующий AI-конвейер.

**Architecture:** Самодостаточный пакет `internal/gmail/` (OAuth + API-клиент + Syncer) по образцу `internal/calendar/` пишет письма в таблицу `gmail_messages`. Детектор `internal/inbox/gmail_detector.go` читает эту таблицу и создаёт `inbox_items` (`email_received`/`email_cc`), дальше работает существующий pipeline без изменений. Daemon получает фазу `phaseGmailSync`; Desktop — кнопку Connect Gmail.

**Tech Stack:** Go 1.25, `database/sql` + `modernc.org/sqlite`, goose-миграции, raw `net/http` для Gmail REST v1, SwiftUI + GRDB (Desktop).

**Спека:** `docs/superpowers/specs/2026-07-09-gmail-source-design.md`

## Global Constraints

- Go 1.25; SQLite через `modernc.org/sqlite` (`database/sql`), никаких CGO-драйверов.
- `MaxOpenConns(1)` для in-memory SQLite: детекторы обязаны **полностью вычитать `rows` в слайс до любого следующего запроса** (иначе deadlock) — см. `calendar_detector.go`.
- Расширение enum-CHECK (`inbox_items.trigger_type`) требует «table-recreation dance» (SQLite не умеет `ALTER TABLE ... ADD CONSTRAINT`) — образец `internal/db/migrations/00002_target_due_inbox.sql`.
- Любое изменение схемы зеркалится в `internal/db/schema.sql`, новые таблицы добавляются в `TestAllTablesExist`, golden snapshot регенерируется: `go test ./internal/db/ -run TestSchemaGolden -update`.
- Пакет `internal/gmail` **не импортирует** `internal/calendar` (Google-креды связываются на уровне `cmd`).
- Gmail OAuth scope: `https://www.googleapis.com/auth/gmail.modify` (write-back — отдельный план, но scope запрашивается сразу).
- Шумовой фильтр до AI: письма с ярлыками `CATEGORY_PROMOTIONS`/`CATEGORY_SOCIAL` не синхронизируются.
- Дефолты конфига: `InitialHistoryDays=7`, `MaxMessagesPerSync=100`, `MaxBodyBytes=51200`.
- Проверять реальный exit-код тестов (не пайпить через `tail`); Swift: `cd WatchtowerDesktop && swift build && swift test`.
- Все commit-сообщения оканчиваются `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File Structure

**Создаётся:**
- `internal/db/migrations/00016_gmail_source.sql` — схема (таблицы + watermark + trigger_type).
- `internal/db/gmail.go` — DB-слой (модель, upsert, чтение для детектора, watermark, auth-state).
- `internal/gmail/auth.go` — OAuth (TokenStore `gmail_token.json`, Login/Prepare/Complete).
- `internal/gmail/client.go` — Gmail REST v1 клиент (list/get, refresh).
- `internal/gmail/models.go` — доменный тип письма.
- `internal/gmail/sync.go` — Syncer (initial/incremental, фильтр, upsert, watermark).
- `internal/inbox/gmail_detector.go` — `DetectGmail`.
- `cmd/gmail.go` — CLI `gmail login/logout/sync/status`.
- `WatchtowerDesktop/Sources/Services/GmailAuthService.swift` — Desktop connect-сервис.
- Тесты: `internal/db/gmail_test.go`, `internal/gmail/*_test.go`, `internal/inbox/gmail_detector_test.go`.

**Модифицируется:**
- `internal/db/schema.sql` — зеркало схемы.
- `internal/db/db_test.go` — `TestAllTablesExist` (+`gmail_messages`, `gmail_auth_state`).
- `internal/db/testdata/schema_golden.sql` (или как называется snapshot) — регенерация.
- `internal/config/config.go` — `GmailConfig` + поле в `Config` + `SetDefault` в `Load`.
- `internal/config/defaults.go` — дефолты Gmail.
- `internal/inbox/classifier.go` — `defaultClasses` (+email типы).
- `internal/inbox/pipeline.go` — `detectAll` + `Run` + `RunFastDetection`.
- `internal/daemon/daemon.go` — поле/сеттер/фаза Gmail.
- `cmd/sync.go` — проводка Gmail syncer в daemon.
- `cmd/root.go` — регистрация команды `gmail` (если не через `init()`).
- `WatchtowerDesktop/Sources/Views/Settings/SettingsView.swift` — `gmailSettingsSection`.
- `WatchtowerDesktop/Sources/Views/Inbox/InboxCardView.swift` — `case`-ы email-типов.
- `WatchtowerDesktop/Tests/.../TestDatabase.swift` — синхрон схемы.

---

## Task 1: Migration 00016 — schema

**Files:**
- Create: `internal/db/migrations/00016_gmail_source.sql`
- Modify: `internal/db/schema.sql`, `internal/db/db_test.go` (TestAllTablesExist)
- Test: `internal/db/migration_test.go` (или существующий migration-тест), `internal/db/schema_snapshot_test.go`

**Interfaces:**
- Produces: таблицы `gmail_messages`, `gmail_auth_state`; колонка `workspace.gmail_last_internal_date REAL NOT NULL DEFAULT 0`; значения `trigger_type` `email_received`, `email_cc`.

- [ ] **Step 1: Написать миграцию**

Create `internal/db/migrations/00016_gmail_source.sql`. Секция Up: создать две таблицы, добавить watermark-колонку, затем recreation-dance для `inbox_items`. **Важно:** блок `CREATE TABLE inbox_items_new (...)` копирует ТЕКУЩЕЕ определение `inbox_items` из `schema.sql:447-485` целиком (все колонки до `composed_at` + `UNIQUE(channel_id, message_ts)`), меняя только список `trigger_type`, и воспроизводит все 7 индексов.

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

- [ ] **Step 2: Зеркалировать в schema.sql**

В `internal/db/schema.sql`: (а) добавить два `CREATE TABLE` (`gmail_messages` c индексами, `gmail_auth_state` + `INSERT OR IGNORE`) рядом с `calendar_auth_state` (~строка 1007); (б) добавить `gmail_last_internal_date REAL NOT NULL DEFAULT 0` последней колонкой в `CREATE TABLE workspace` (после `compose_last_run_ts` — не забыть запятую перед ней); (в) в `CREATE TABLE inbox_items` в список `trigger_type` дописать `'email_received','email_cc'` (после `'stream'`).

- [ ] **Step 3: Написать/дополнить тест миграции**

Добавить в существующий migration-тест (или создать `internal/db/gmail_migration_test.go`) проверку, что после `Open()` таблицы существуют и приём email-trigger'а работает:

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

(Смотри, как в пакете открывается тестовая БД — переиспользуй тот же helper, что и соседние тесты.)

- [ ] **Step 4: Добавить таблицы в TestAllTablesExist**

В `internal/db/db_test.go` в список ожидаемых таблиц (`TestAllTablesExist`, ~строка 92) добавить `"gmail_messages"` и `"gmail_auth_state"`.

- [ ] **Step 5: Прогнать тесты, убедиться что падают/проходят как надо**

```bash
go test ./internal/db/ -run 'TestMigration00016GmailSource|TestAllTablesExist' -v > /tmp/t1.log 2>&1; echo "exit=$?"; tail -30 /tmp/t1.log
```
Expected: PASS обоих.

- [ ] **Step 6: Регенерировать golden snapshot и прогнать весь пакет db**

```bash
go test ./internal/db/ -run TestSchemaGolden -update > /tmp/t1g.log 2>&1; echo "exit=$?"
go test ./internal/db/ > /tmp/t1all.log 2>&1; echo "exit=$?"; tail -20 /tmp/t1all.log
```
Expected: обе команды exit=0.

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
- Consumes: таблицы из Task 1.
- Produces:
  - type `GmailMessage struct { ID, ThreadID, FromEmail, FromName, ToJSON, CcJSON, Subject, Snippet, BodyText, InternalDate, LabelsJSON string; IsUnread bool; Permalink, SyncedAt, UpdatedAt string }`
  - `func (db *DB) UpsertGmailMessage(m GmailMessage, syncedAt string) error`
  - `func (db *DB) GmailMessagesSyncedAfter(sinceISO string) ([]GmailMessage, error)`
  - `func (db *DB) GetGmailLastInternalDate() (float64, error)`
  - `func (db *DB) SetGmailLastInternalDate(ts float64) error`
  - `func (db *DB) GetGmailAuthState() (GmailAuthState, error)` / `func (db *DB) SetGmailAuthState(status, errMsg string) error`
  - type `GmailAuthState struct { Status, Error, UpdatedAt string }`

- [ ] **Step 1: Написать тест DB-слоя**

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

- [ ] **Step 2: Убедиться, что тест не компилируется/падает**

```bash
go test ./internal/db/ -run 'TestGmail' > /tmp/t2.log 2>&1; echo "exit=$?"; tail -20 /tmp/t2.log
```
Expected: FAIL (undefined: UpsertGmailMessage и т.д.).

- [ ] **Step 3: Реализовать `internal/db/gmail.go`**

Образец методов auth-state и watermark — `internal/db/calendar.go:301-325` и `internal/db/workspace.go` (`GetComposeLastRunTS`/`SetComposeLastRunTS`).

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

- [ ] **Step 4: Прогнать тесты**

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
  - `type OAuthToken struct { AccessToken, TokenType, RefreshToken, Expiry string }` (JSON-теги как в calendar)
  - `type TokenStore` с `NewTokenStore(workspaceDir string) *TokenStore` → файл `gmail_token.json`; методы `Load/Save/Delete/Exists/Path`
  - `func Login(ctx, cfg GoogleOAuthConfig, out io.Writer, opts ...LoginOptions) (*OAuthToken, error)`
  - `func Prepare(cfg GoogleOAuthConfig, customRedirectURI string) (*PrepareResult, error)`
  - `func Complete(ctx, cfg GoogleOAuthConfig, code, redirectURI string) (*OAuthToken, error)`
  - `var googleTokenEndpoint string` (экспортируемо в пакете для client.go/tests)

- [ ] **Step 1: Скопировать calendar/auth.go как основу и адаптировать**

Создать `internal/gmail/auth.go` на базе `internal/calendar/auth.go` (340 строк). Точечные изменения:
- `package gmail`;
- `const gmailScope = "https://www.googleapis.com/auth/gmail.modify"`; удалить `calendarEventsScope`/`calendarCalendarListScope`;
- в `buildAuthURL` — `"scope": {gmailScope}`;
- `NewTokenStore` → `filepath.Join(workspaceDir, "gmail_token.json")`;
- `defaultRedirectPort = 18511` (следующий свободный диапазон после Calendar 18501-18510);
- `listenLocal` preferred-порты `18511..18520`;
- success/error HTML: заголовок «Watchtower — Gmail Connected», текст «Gmail has been linked to Watchtower.»;
- в `Login` строки вывода: «Opening browser for Gmail authorization...»;
- `DefaultGoogleClientID`/`DefaultGoogleClientSecret` **НЕ объявлять** в этом пакете (креды приходят через cmd из `calendar.Default...` — см. Task 9).

- [ ] **Step 2: Скопировать и адаптировать auth_test.go**

Создать `internal/gmail/auth_test.go` на базе `internal/calendar/auth_test.go`. Заменить пакет на `gmail`, проверить что `buildAuthURL` содержит `gmail.modify` scope и `access_type=offline`, что TokenStore пишет/читает `gmail_token.json`, и Login/Complete против `httptest.Server` (переопределяя `googleAuthEndpoint`/`googleTokenEndpoint`). Ключевой новый ассерт:

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

- [ ] **Step 3: Прогнать тесты**

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
  - `func (c *Client) ListInboxMessageIDs(ctx, query string, maxResults int) ([]string, error)` — возвращает message IDs по `q=` (например `in:inbox newer_than:7d`)
  - `func (c *Client) GetMessage(ctx, id string) (*Message, error)`
  - `models.go`: `type Message struct { ID, ThreadID, FromEmail, FromName, Subject, Snippet, BodyText, InternalDate string; To, Cc []string; Labels []string; IsUnread bool; Permalink string }`

- [ ] **Step 1: Написать models.go**

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

- [ ] **Step 2: Написать client_test.go (httptest)**

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

- [ ] **Step 3: Убедиться, что тест падает**

```bash
go test ./internal/gmail/ -run TestClientListAndGet > /tmp/t4.log 2>&1; echo "exit=$?"; tail -20 /tmp/t4.log
```
Expected: FAIL (undefined NewClient/gmailAPIBase).

- [ ] **Step 4: Реализовать client.go**

Refresh/`ErrAuthRevoked`/`isInvalidGrant` — по образцу `internal/calendar/client.go:18-137`. Плюс парсинг сообщения.

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

Примечание для реализатора: приведённый `GetMessage` дважды декодирует тело ради доступа к `payload.headers`. При реализации упрости — сделай `apiPart` с полем `Headers []struct{Name,Value string}` и одним `json.Unmarshal`. Тест из Step 2 — источник истины по поведению; финальная форма парсинга на усмотрение, лишь бы тест проходил и не было двойного декодирования.

- [ ] **Step 5: Прогнать тесты**

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
- Consumes: `Client` (Task 4), DB-слой (Task 2), `config.Config`.
- Produces:
  - `func NewSyncer(client *Client, database *db.DB, cfg *config.Config, logger *log.Logger) *Syncer`
  - `func (s *Syncer) Sync(ctx context.Context) (int, error)`
  - `config.GmailConfig{ Enabled bool; InitialHistoryDays, MaxMessagesPerSync, MaxBodyBytes int }`; поле `Gmail GmailConfig` в `config.Config`.

- [ ] **Step 1: Добавить GmailConfig в config**

В `internal/config/config.go` рядом с `CalendarConfig`:

```go
// GmailConfig holds Gmail integration settings.
type GmailConfig struct {
    Enabled            bool `mapstructure:"enabled"`               // enable gmail sync (default: false)
    InitialHistoryDays int  `mapstructure:"initial_history_days"`  // days of inbox to backfill on first sync
    MaxMessagesPerSync int  `mapstructure:"max_messages_per_sync"` // per-cycle cap
    MaxBodyBytes       int  `mapstructure:"max_body_bytes"`        // truncate body_text beyond this
}
```

В `Config` struct (после `Calendar CalendarConfig`):
```go
    Gmail           GmailConfig                 `mapstructure:"gmail"`
```

В `internal/config/defaults.go` (рядом с Calendar defaults):
```go
    // Gmail defaults
    DefaultGmailEnabled            = false
    DefaultGmailInitialHistoryDays = 7
    DefaultGmailMaxMessagesPerSync = 100
    DefaultGmailMaxBodyBytes       = 51200
```

В `Load` (после `calendar.sync_days_ahead` SetDefault):
```go
    v.SetDefault("gmail.enabled", DefaultGmailEnabled)
    v.SetDefault("gmail.initial_history_days", DefaultGmailInitialHistoryDays)
    v.SetDefault("gmail.max_messages_per_sync", DefaultGmailMaxMessagesPerSync)
    v.SetDefault("gmail.max_body_bytes", DefaultGmailMaxBodyBytes)
```

- [ ] **Step 2: Написать sync_test.go**

Тест: initial-sync (watermark=0) шлёт запрос `newer_than`, синкает письма, отсекает PROMOTIONS/SOCIAL, усекает тело, продвигает watermark по максимальному internalDate.

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

(Если в `internal/db` нет экспортированного `OpenTestDB`, используй тот же способ открытия in-memory БД, что применяют существующие тесты `internal/calendar/sync_test.go`.)

- [ ] **Step 3: Убедиться что тест падает**

```bash
go test ./internal/gmail/ -run TestSyncFiltersAndUpserts > /tmp/t5.log 2>&1; echo "exit=$?"; tail -20 /tmp/t5.log
```
Expected: FAIL (undefined NewSyncer).

- [ ] **Step 4: Реализовать sync.go**

Образец структуры — `internal/calendar/sync.go`.

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

(Убери `var _ = strings.TrimSpace`, если `strings` не нужен — это лишь подсказка, что импорт может оказаться неиспользуемым.)

- [ ] **Step 5: Прогнать тесты gmail + config**

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

- [ ] **Step 1: Расширить classifier defaultClasses**

В `internal/inbox/classifier.go` в map `defaultClasses` добавить:
```go
    "email_received":        "actionable",
    "email_cc":              "ambient",
```

- [ ] **Step 2: Написать gmail_detector_test.go**

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

(Реализуй маленькие хелперы `openInboxTestDB` и `inboxTriggerFor` по образцу существующих тестов детекторов в пакете, напр. `calendar_detector_test.go`, если он есть; если нет — используй прямой `database.QueryRow`.)

- [ ] **Step 3: Убедиться что тест падает**

```bash
go test ./internal/inbox/ -run TestDetectGmail > /tmp/t6.log 2>&1; echo "exit=$?"; tail -20 /tmp/t6.log
```
Expected: FAIL (undefined DetectGmail).

- [ ] **Step 4: Реализовать gmail_detector.go**

Образец — `internal/inbox/calendar_detector.go` (полное вычитывание rows до вставок обеспечивает `GmailMessagesSyncedAfter`, который сам вычитывает в слайс).

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

Примечание: `equalFoldEmail` сравнивает по длине+lowercase ASCII — достаточно для email. Если в пакете уже есть util для case-insensitive сравнения, используй его вместо этих трёх хелперов (DRY).

- [ ] **Step 5: Прогнать тесты**

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
- Test: `internal/inbox/pipeline_test.go` (или существующий)

**Interfaces:**
- Consumes: `DetectGmail` (Task 6), `p.currentUserEmail`.
- Produces: расширенная сигнатура `detectAll(...) (slack, jira, cal, gmail, wt int, err error)`.

- [ ] **Step 1: Расширить detectAll**

В `internal/inbox/pipeline.go` в `detectAll` (~строка 500) изменить сигнатуру на
`(slack, jira, cal, gmail, wt int, err error)` и добавить после Calendar-блока:

```go
    if n, e := DetectGmail(ctx, p.db, p.currentUserEmail, sinceTime); e != nil {
        p.logger.Printf("inbox: gmail detect error: %v", e)
        errs = append(errs, fmt.Errorf("gmail: %w", e))
    } else {
        gmail = n
    }
```
и `return slack, jira, cal, gmail, wt, errors.Join(errs...)`.

- [ ] **Step 2: Обновить оба места вызова**

В `Run` (~строка 373):
```go
    createdSlack, createdJira, createdCalendar, createdGmail, createdWatchtower, detectErr := p.detectAll(ctx, currentUserID, lastTS, sinceTime, true)
    created := createdSlack + createdJira + createdCalendar + createdGmail + createdWatchtower
```

В `RunFastDetection` (~строка 483):
```go
    createdSlack, createdJira, createdCalendar, createdGmail, _, _ := p.detectAll(ctx, currentUserID, lastTS, sinceTime, false)
    created := createdSlack + createdJira + createdCalendar + createdGmail
```
и обновить лог-строку:
```go
    p.logger.Printf("inbox fast: +%d new (S%d J%d C%d G%d), %d auto-resolved",
        created, createdSlack, createdJira, createdCalendar, createdGmail, resolved)
```

- [ ] **Step 3: Тест — email-письмо доходит до inbox через RunFastDetection**

Добавить в pipeline-тест (используй существующий способ конструирования `Pipeline` с in-memory DB; выстави `p.SetCurrentUser("U1", "me@x.com")`):

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

(Если готового `newTestPipeline` нет — сконструируй `Pipeline` тем же способом, что и соседние тесты в файле.)

- [ ] **Step 4: Прогнать тесты пакета inbox**

```bash
go test ./internal/inbox/ > /tmp/t7.log 2>&1; echo "exit=$?"; tail -30 /tmp/t7.log
```
Expected: PASS (включая существующие тесты — сигнатура detectAll используется только внутри пакета).

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
- Produces: `func (d *Daemon) SetGmailSyncer(s *gmail.Syncer)`; фаза `phaseGmailSync`.

- [ ] **Step 1: daemon поле + сеттер + фаза + вызов**

В `internal/daemon/daemon.go`:
- import `"watchtower/internal/gmail"`;
- поле рядом с `calendarSyncer` (~строка 63): `gmailSyncer *gmail.Syncer`;
- сеттер рядом с `SetCalendarSyncer` (~строка 130):
```go
// SetGmailSyncer sets the Gmail syncer for post-sync mail fetch.
func (d *Daemon) SetGmailSyncer(s *gmail.Syncer) {
    d.gmailSyncer = s
}
```
- вызов в `runCycle` сразу после `d.phaseCalendarSync(ctx)` (~строка 215): `d.phaseGmailSync(ctx)`;
- метод-фаза рядом с `phaseCalendarSync` (~строка 313):
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

- [ ] **Step 2: cmd/sync.go проводка**

В `cmd/sync.go` сразу после блока Calendar (~строка 355, перед `return d.Run(ctx)`):

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
Добавить `"watchtower/internal/gmail"` в импорты `cmd/sync.go`.

- [ ] **Step 3: Тест daemon nil-guard**

Добавить в `internal/daemon/daemon_test.go`:
```go
func TestPhaseGmailSyncNilGuard(t *testing.T) {
    d := &Daemon{logger: log.New(io.Discard, "", 0)}
    // No syncer set — must be a no-op, not a panic.
    d.phaseGmailSync(context.Background())
}
```
(Сконструируй `Daemon` тем же способом, что соседние daemon-тесты; если phase приватная и тест в другом пакете — сделай тест в `package daemon`.)

- [ ] **Step 4: Прогнать сборку и тесты**

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
- Consumes: `gmail.*` (Tasks 3-5), `resolveGoogleOAuthConfig` (`cmd/calendar.go:410`), `openDatabaseForWorkspace`/эквивалент (посмотри, как это делает `cmd/calendar.go`).
- Produces: команда `gmail` с подкомандами `login/logout/sync/status`.

- [ ] **Step 1: Реализовать cmd/gmail.go**

Образец — `cmd/calendar.go` (login/logout/sync/status). Ключевые отличия: `gmail.NewTokenStore`, `gmail.Login`, `gmail.NewClient`, `gmail.NewSyncer`, конвертация кредов через `resolveGoogleOAuthConfig()` → `gmail.GoogleOAuthConfig{...}`; статус читает `cfg.Gmail.Enabled` и `store.Path()`. Регистрация подкоманд через `init()` + `rootCmd.AddCommand(gmailCmd)` (как в `cmd/calendar.go:68`).

Скелет:
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
`gmailLoginCmd`/`gmailLogoutCmd`/`gmailSyncCmd`/`gmailStatusCmd` — по образцу соответствующих `runCalendar*` из `cmd/calendar.go`, подставив `gmail.*` и `gmailOAuthConfig()`. `login` использует `gmail.Login(ctx, gmailOAuthConfig(), os.Stdout, gmail.LoginOptions{SkipBrowserOpen: noOpen})` и `store.Save(token)`, затем `database.SetGmailAuthState("ok","")`. `sync` — `store.Load()` → `gmail.NewClient` → `gmail.NewSyncer(...).Sync(ctx)`.

- [ ] **Step 2: Тест — команда зарегистрирована и OAuth-конфиг конвертируется**

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

- [ ] **Step 3: Прогнать сборку и тесты**

```bash
go build ./... > /tmp/t9b.log 2>&1; echo "build=$?"; tail -20 /tmp/t9b.log
go test ./cmd/ -run TestGmail > /tmp/t9.log 2>&1; echo "test=$?"; tail -20 /tmp/t9.log
```
Expected: build=0, test=0.

- [ ] **Step 4: Ручная проверка CLI (status без токена)**

```bash
go run . gmail status > /tmp/t9m.log 2>&1; echo "exit=$?"; cat /tmp/t9m.log
```
Expected: печатает «not connected» (или аналог), exit=0 без паники.

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
- Modify: `WatchtowerDesktop/Sources/Views/Settings/SettingsView.swift`, `WatchtowerDesktop/Sources/Views/Inbox/InboxCardView.swift`, `WatchtowerDesktop/Tests/.../TestDatabase.swift` (схема-синхрон)

**Interfaces:**
- Consumes: CLI-команды `gmail login/logout/status` (Task 9); поле `config.gmailEnabled` (если есть слой конфига в Desktop — иначе только connect/disconnect).
- Produces: `GmailAuthService` (`isConnected/isAuthenticating/error`, `connect/cancelConnect/disconnect/checkStatus`).

- [ ] **Step 1: GmailAuthService.swift**

Скопировать `WatchtowerDesktop/Sources/Services/GoogleAuthService.swift` в `GmailAuthService.swift`, заменив:
- имя класса → `GmailAuthService`;
- аргументы процесса `["calendar", "login"]` → `["gmail", "login"]`, `["calendar", "logout"]` → `["gmail", "logout"]`;
- в `checkStatus()` сканирование `*/google_token.json` → `*/gmail_token.json`.

- [ ] **Step 2: gmailSettingsSection в SettingsView.swift**

По образцу `calendarSettingsSection` (`SettingsView.swift:373-429`) добавить:
- `@State private var gmailAuth = GmailAuthService()` рядом с `googleAuth` (~строка 46);
- секцию `Section("Gmail")` с той же структурой: connected → зелёная галка + Disconnect + тоггл «Enable Gmail sync» (пишет `config.gmailEnabled`, если поле есть); not connected → кнопка Connect (`gmailAuth.connect()`), ProgressView+Cancel при `isAuthenticating`, красный текст ошибки;
- подключить `gmailSettingsSection` в тело формы рядом с `calendarSettingsSection`.

Если в Desktop-конфиге нет `gmailEnabled` — добавь его по образцу `calendarEnabled` (найди определение `calendarEnabled` в Desktop config-модели и повтори).

- [ ] **Step 3: InboxCardView email-типы**

В `WatchtowerDesktop/Sources/Views/Inbox/InboxCardView.swift` в три `switch item.triggerType`:
- `triggerLabel` (~260): `case "email_received", "email_cc": return "Email"`;
- `triggerSymbol` (~278): `case "email_received", "email_cc": return "envelope"`;
- `triggerColor` (~296): `case "email_received", "email_cc": return .blue`.

- [ ] **Step 4: Синхронизировать TestDatabase.swift**

Найти в `WatchtowerDesktop/Tests/` файл, создающий тестовую схему (TestDatabase.swift). Добавить `CREATE TABLE gmail_messages (...)` и `gmail_auth_state`, и расширить `inbox_items.trigger_type` CHECK на `email_received`/`email_cc` — точно как в миграции Task 1 (иначе Swift-тесты, читающие эти таблицы/типы, разъедутся со схемой — известная ловушка репо).

- [ ] **Step 5: Собрать и протестировать Desktop**

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

## Финальная проверка (после всех задач)

- [ ] **Полный прогон Go**

```bash
gofmt -l internal/ cmd/ > /tmp/fmt.log 2>&1; echo "gofmt-dirty=$(wc -l < /tmp/fmt.log)"
go vet ./... > /tmp/vet.log 2>&1; echo "vet=$?"; tail -20 /tmp/vet.log
go build ./... > /tmp/build.log 2>&1; echo "build=$?"
go test ./... > /tmp/all.log 2>&1; echo "test=$?"; tail -30 /tmp/all.log
```
Expected: gofmt-dirty=0, vet=0, build=0, test=0.

- [ ] **Локальный ревью-гейт перед PR:** запустить навык `local-review` (mirror CI + панель ревьюеров) на диффе ветки, оттриажить находки, зафиксировать.

- [ ] **Обновить app-guide** (`docs/app-guide.md`) — добавить упоминание Connect Gmail и того, что письма попадают в inbox/ситуации (инжектится в system prompt чат-бота — правило поддержки гайда).

- [ ] **Обновить документ инвентаря** при необходимости (`docs/inventory/inbox-pulse.md` / `dashboard.md`) — новые trigger-типы email как источник; свериться, не нарушает ли что-то INBOX-01/09.

---

## Self-Review (заполнено автором плана)

**Spec coverage:**
- OAuth (gmail.modify, gmail_token.json, self-contained) → Task 3, Task 9 (креды). ✓
- Таблица `gmail_messages` + `gmail_auth_state` + watermark → Task 1, Task 2. ✓
- Sync (initial/incremental, noise filter, body truncation) → Task 5. ✓
- Детектор (received/cc, дедуп, snippet=subject+preview) → Task 6. ✓
- classifier defaultClasses → Task 6 Step 1. ✓
- pipeline detectAll/Run/RunFastDetection → Task 7. ✓
- daemon phase + cmd/sync wiring → Task 8. ✓
- CLI → Task 9. ✓
- Desktop connect + card visuals + TestDatabase sync → Task 10. ✓
- AI-обработка: писем через существующие triage/compose/situation-card — обеспечивается тем, что детектор создаёт обычные `inbox_items`; snippet=subject+preview (Task 6) даёт triage контекст; полное body_text хранится (Task 1/5) для сильного tier. ✓ (Промпты не меняются — по спеке.)
- Задачи вне охвата (email-дайджесты=План 2, write-back=План 3) — не включены. ✓

**Placeholder scan:** нет TBD/«handle errors»; код приведён для всех новых файлов; для копий-образцов (auth.go, cmd/gmail.go, Desktop) указаны точный файл-образец и дельты. ✓

**Type consistency:** `GmailMessage` (db) и `Message` (gmail) — разные слои, конвертация в Task 5; `GoogleOAuthConfig` определён в `gmail` (Task 3), конвертация из `calendar.GoogleOAuthConfig` на cmd-уровне (Tasks 8, 9); `detectAll` новая сигнатура согласована между Task 7 Step 1 и оба call-site. ✓
