# Slack Multi-Account Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** N Slack organizations per workspace in one shared DB — `slack_accounts` rows, per-account token files, namespaced channel/user ids (`"<accountID>:<rawSlackID>"`), syncer fan-out, per-account own-message suppression, Desktop account list. One shared secretary context across all connected Slack orgs.

**Architecture:** New `slack_accounts` table replaces the single `workspace.current_user_id`/`search_last_date` fields. `channels.id`/`users.id`/`messages.channel_id`/`messages.user_id` (and every table that copies those values) become namespaced strings `"<accountID>:<rawSlackID>"` instead of a composite PK — chosen so the digest/tracks/people/memory/MCP pipelines, which already treat these columns as opaque unique strings, need zero signature changes. `internal/sync.Orchestrator` becomes per-account (namespaces at every DB write, strips the prefix only at the handful of call sites that hit the live Slack API). `cmd/sync.go`/`internal/daemon` fan out one `Orchestrator` per enabled account, mirroring `wireImapSyncers`/`wireGoogleSyncers`. Existing single-workspace installs migrate in place (account #1).

**Tech Stack:** Go 1.25, goose migrations, modernc.org/sqlite, SwiftUI + GRDB (WatchtowerDesktop).

**Spec:** `docs/superpowers/specs/2026-07-31-slack-multi-account-design.md`

## Global Constraints

- Branch: `feature/multi-account` (parallel worktree per the initiative plan). Commit messages in English.
- New migration number: **00044** (`internal/db/migrations/00044_slack_accounts.sql`). Do NOT bump `CurrentSchemaFormat`.
- Every schema change must be mirrored in `internal/db/schema.sql`, `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift`, added to `TestAllTablesExist` (`internal/db/db_test.go`) if a new table, and the golden regenerated: `go test ./internal/db/ -run TestSchemaGolden -update`.
- Table-recreation dances (`sync_state` PK rename is NOT needed — see Task 1 rationale; no table actually needs recreation this time, only `ALTER TABLE ... ADD COLUMN` and data `UPDATE`s) run under a normal transaction; no `PRAGMA foreign_keys = OFF` dance is required because no table's PRIMARY KEY *type* changes, only the *values* in existing TEXT columns.
- **Documented v1 identity-scoping decisions (do not "fix" these — they are deliberate, not oversights):**
  1. `db.GetCurrentUserID()` (used by Jira detection, style-sample, people-card lookup, `cmd/profile.go`) stays pinned to **account #1's** `current_user_id`. The app remains conceptually single-owner; only Slack message ingestion, inbox stream-candidate exclusion, and own-message suppression become genuinely multi-account aware (Task 7). Widening every `GetCurrentUserID()` consumer to a multi-identity union is out of scope for v1.
  2. Historical rows in JSON-embedded id columns (`tracks.channel_ids`, `tracks.participants`, `people.starred_channels`, any `shared_channel_ids` config) are **not** rewritten by the migration — only scalar `TEXT` id columns are. New rows written after the migration carry namespaced ids correctly; pre-migration JSON blobs keep their old bare ids as frozen historical text. Same for the memory vault's markdown files (git-backed, not SQL-rewritable) — historical entity/episode mentions keep old-style ids, new content is written correctly by pipelines running post-migration.
  3. `slack remove <id>` is **non-destructive** (deletes the token file, sets `status='removed'`, `enabled=0`) — it does NOT cascade-delete `channels`/`messages`/digests/tracks/situations/memory for that account. The `slack_accounts` row itself is kept (not hard-deleted) for label/domain attribution.
- No behavioral-contract weakening: read `docs/inventory/inbox-pulse.md` before touching `internal/inbox`; INBOX-09 semantics stay intact.
- Secrets never in the DB and never in argv — the Slack token moves to a 0600 file (`slack_token_<id>.json`), matching the `google_token_<id>.json`/IMAP credential-file convention.
- Go verification per task: `go build ./... && go vet ./...` plus the named tests, redirected to a log file with `echo "exit=$?"` checked explicitly — never piped through `tail`. Swift: `cd WatchtowerDesktop && swift build && swift test`, same exit-code discipline.
- The daemon may be running during development (Desktop respawns it). Don't rely on killing it; run CLI commands manually for verification.

---

### Task 1: Migration 00044 — `slack_accounts` + namespaced ids + in-place data migration

**Files:**
- Create: `internal/db/migrations/00044_slack_accounts.sql`
- Create: `internal/db/slack_accounts_migration_test.go`
- Modify: `internal/db/schema.sql` (workspace block, users/channels/messages blocks, every table listed in Step 3 below; new `slack_accounts` block placed before `email_accounts`)
- Modify: `internal/db/db_test.go` (`TestAllTablesExist`: add `"slack_accounts"`)
- Modify: `internal/db/testdata/schema_v73.golden` (regenerate)

**Interfaces:**
- Produces table `slack_accounts(id, team_id, team_name, team_domain, label, current_user_id, status, error, enabled, search_last_date, created_at)`; `channels.id`/`users.id`/`messages.channel_id`/`messages.user_id` (and every column listed in Step 3) hold namespaced strings `"<accountID>:<rawSlackID>"`; `workspace.current_user_id` and `workspace.search_last_date` columns are dropped.

- [ ] **Step 1: Write the failing migration test**

`internal/db/slack_accounts_migration_test.go`:

```go
package db

import "testing"

func TestMigration00044SlackAccounts(t *testing.T) {
	d := OpenTestDB(t)

	assertTableExists(t, d, "slack_accounts")

	if _, err := d.Exec(`INSERT INTO slack_accounts (team_id, team_name, team_domain, label, current_user_id)
		VALUES ('T1', 'Team One', 'team-one', 'Team One', '1:U0001')`); err != nil {
		t.Fatalf("insert slack account: %v", err)
	}
	var id int64
	if err := d.QueryRow(`SELECT id FROM slack_accounts WHERE team_id = 'T1'`).Scan(&id); err != nil || id == 0 {
		t.Fatalf("expected autoincrement id, got %d err=%v", id, err)
	}

	// Namespaced channel/user ids are just TEXT — no PK type change, but
	// two different accounts can now own colliding raw Slack ids.
	if _, err := d.Exec(`INSERT INTO channels (id, name, type) VALUES ('1:C001', 'general', 'public')`); err != nil {
		t.Fatalf("insert channel: %v", err)
	}
	if _, err := d.Exec(`INSERT INTO channels (id, name, type) VALUES ('2:C001', 'general', 'public')`); err != nil {
		t.Fatalf("same raw id under a second account must not collide: %v", err)
	}

	// workspace.current_user_id / search_last_date are gone.
	if _, err := d.Exec(`UPDATE workspace SET current_user_id = 'x'`); err == nil {
		t.Fatal("workspace.current_user_id should be dropped")
	}
	if _, err := d.Exec(`UPDATE workspace SET search_last_date = 'x'`); err == nil {
		t.Fatal("workspace.search_last_date should be dropped")
	}
}

func TestMigration00044_FreshDBHasNoSeedRow(t *testing.T) {
	d := OpenTestDB(t)
	var n int
	if err := d.QueryRow(`SELECT COUNT(*) FROM slack_accounts`).Scan(&n); err != nil {
		t.Fatalf("count: %v", err)
	}
	if n != 0 {
		t.Fatalf("fresh DB must have no slack_accounts seed row, got %d", n)
	}
}
```

Reuse `assertTableExists`/`OpenTestDB` from the Google migration test helpers (same package, `internal/db/google_accounts_migration_test.go`).

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/db/ -run TestMigration00044 -v 2>&1 | tee /tmp/s1.log; echo "exit=$?"`
Expected: FAIL (table `slack_accounts` missing).

- [ ] **Step 3: Write the migration**

`internal/db/migrations/00044_slack_accounts.sql`. No table-recreation dance is needed — every affected table keeps its existing `PRIMARY KEY`/column types; only the *values* of existing TEXT id columns change, plus one new table and two dropped columns on `workspace` (SQLite supports `ALTER TABLE ... DROP COLUMN` directly, no rebuild required).

```sql
-- +goose Up

-- 1. Account table.
CREATE TABLE IF NOT EXISTS slack_accounts (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    team_id           TEXT NOT NULL DEFAULT '',
    team_name         TEXT NOT NULL DEFAULT '',
    team_domain       TEXT NOT NULL DEFAULT '',
    label             TEXT NOT NULL DEFAULT '',
    current_user_id   TEXT NOT NULL DEFAULT '',  -- namespaced, e.g. "1:U0123"
    status            TEXT NOT NULL DEFAULT 'ok',  -- ok | error | revoked | removed
    error             TEXT NOT NULL DEFAULT '',
    enabled           INTEGER NOT NULL DEFAULT 1,
    search_last_date  TEXT NOT NULL DEFAULT '',
    created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- 2. Seed account #1 from the legacy workspace singleton whenever legacy
--    Slack data exists (token-only installs are seeded in Go by
--    ensureLegacySlackAccount — SQL can't see the config-embedded token).
INSERT INTO slack_accounts (team_id, team_name, team_domain, current_user_id, search_last_date)
SELECT COALESCE(id, ''), COALESCE(name, ''), COALESCE(domain, ''),
       CASE WHEN COALESCE(current_user_id, '') = '' THEN '' ELSE '1:' || current_user_id END,
       COALESCE(search_last_date, '')
FROM workspace
WHERE EXISTS (SELECT 1 FROM workspace WHERE COALESCE(current_user_id, '') != '' OR id != '');

-- 3. Namespace every existing Slack-derived id with the "1:" prefix
--    (all current data belongs to the single pre-migration account).
--    Empty-string sentinels stay empty; NULLs pass through '||' as NULL.
UPDATE channels SET id = '1:' || id WHERE id != '';
UPDATE channels SET dm_user_id = '1:' || dm_user_id WHERE dm_user_id IS NOT NULL AND dm_user_id != '';
UPDATE users SET id = '1:' || id WHERE id != '';
UPDATE messages SET channel_id = '1:' || channel_id WHERE channel_id != '';
UPDATE messages SET user_id = '1:' || user_id WHERE user_id != '';
UPDATE messages SET thread_ts = thread_ts WHERE 0; -- thread_ts is a raw ts, not an id — no-op, documents the decision
UPDATE reactions SET channel_id = '1:' || channel_id WHERE channel_id != '';
UPDATE reactions SET user_id = '1:' || user_id WHERE user_id != '';
UPDATE files SET message_channel_id = '1:' || message_channel_id WHERE message_channel_id != '';
UPDATE sync_state SET channel_id = '1:' || channel_id WHERE channel_id != '';
UPDATE channel_settings SET channel_id = '1:' || channel_id WHERE channel_id != '';
UPDATE digests SET channel_id = '1:' || channel_id WHERE channel_id != '';
UPDATE digest_participants SET user_id = '1:' || user_id WHERE user_id != '';
UPDATE user_analyses SET user_id = '1:' || user_id WHERE user_id != '';
UPDATE tracks SET assignee_user_id = '1:' || assignee_user_id WHERE assignee_user_id != '';
UPDATE tracks SET ball_on = '1:' || ball_on WHERE ball_on != '';
UPDATE tracks SET owner_user_id = '1:' || owner_user_id WHERE owner_user_id != '';
UPDATE tracks SET requester_user_id = '1:' || requester_user_id WHERE requester_user_id != '';
UPDATE inbox_items SET channel_id = '1:' || channel_id
  WHERE channel_id != '' AND channel_id NOT LIKE 'gmail:%' AND channel_id NOT LIKE 'imap:%';
UPDATE inbox_items SET sender_user_id = '1:' || sender_user_id
  WHERE sender_user_id != '' AND channel_id LIKE '1:%';
UPDATE inbox_learned_rules SET scope_key = 'channel:1:' || substr(scope_key, 9)
  WHERE scope_key LIKE 'channel:%' AND scope_key NOT LIKE 'channel:gmail:%' AND scope_key NOT LIKE 'channel:imap:%';
UPDATE inbox_learned_rules SET scope_key = 'sender:1:' || substr(scope_key, 8)
  WHERE scope_key LIKE 'sender:%';
UPDATE people SET slack_user_id = '1:' || slack_user_id WHERE slack_user_id != '';
UPDATE communication_guides SET user_id = '1:' || user_id WHERE user_id != '';
UPDATE people_cards SET user_id = '1:' || user_id WHERE user_id != '';
UPDATE briefings SET user_id = '1:' || user_id WHERE user_id != '';
UPDATE day_plans SET user_id = '1:' || user_id WHERE user_id != '';
UPDATE calendar_attendee_map SET slack_user_id = '1:' || slack_user_id WHERE slack_user_id != '';
UPDATE jira_user_map SET slack_user_id = '1:' || slack_user_id WHERE slack_user_id != '';
UPDATE jira_slack_links SET channel_id = '1:' || channel_id WHERE channel_id != '';
UPDATE memory_provenance SET channel_id = '1:' || channel_id
  WHERE channel_id != '' AND scheme = '';
UPDATE memory_provenance SET sender_id = '1:' || sender_id
  WHERE sender_id != '' AND scheme = '';

-- 4. Retire the workspace-singleton Slack fields (moved to slack_accounts).
--    id/name/domain/synced_at stay as a frozen legacy snapshot of account #1
--    — nothing reads them by key (every workspace read is `LIMIT 1`).
ALTER TABLE workspace DROP COLUMN current_user_id;
ALTER TABLE workspace DROP COLUMN search_last_date;

-- +goose Down
ALTER TABLE workspace ADD COLUMN current_user_id TEXT NOT NULL DEFAULT '';
ALTER TABLE workspace ADD COLUMN search_last_date TEXT NOT NULL DEFAULT '';
UPDATE workspace SET
    current_user_id = COALESCE((SELECT substr(current_user_id, 3) FROM slack_accounts WHERE id = 1), ''),
    search_last_date = COALESCE((SELECT search_last_date FROM slack_accounts WHERE id = 1), '');
UPDATE memory_provenance SET sender_id = substr(sender_id, 3) WHERE sender_id LIKE '1:%' AND scheme = '';
UPDATE memory_provenance SET channel_id = substr(channel_id, 3) WHERE channel_id LIKE '1:%' AND scheme = '';
UPDATE jira_slack_links SET channel_id = substr(channel_id, 3) WHERE channel_id LIKE '1:%';
UPDATE jira_user_map SET slack_user_id = substr(slack_user_id, 3) WHERE slack_user_id LIKE '1:%';
UPDATE calendar_attendee_map SET slack_user_id = substr(slack_user_id, 3) WHERE slack_user_id LIKE '1:%';
UPDATE day_plans SET user_id = substr(user_id, 3) WHERE user_id LIKE '1:%';
UPDATE briefings SET user_id = substr(user_id, 3) WHERE user_id LIKE '1:%';
UPDATE people_cards SET user_id = substr(user_id, 3) WHERE user_id LIKE '1:%';
UPDATE communication_guides SET user_id = substr(user_id, 3) WHERE user_id LIKE '1:%';
UPDATE people SET slack_user_id = substr(slack_user_id, 3) WHERE slack_user_id LIKE '1:%';
UPDATE inbox_learned_rules SET scope_key = 'sender:' || substr(scope_key, 9) WHERE scope_key LIKE 'sender:1:%';
UPDATE inbox_learned_rules SET scope_key = 'channel:' || substr(scope_key, 10) WHERE scope_key LIKE 'channel:1:%';
UPDATE inbox_items SET sender_user_id = substr(sender_user_id, 3) WHERE sender_user_id LIKE '1:%';
UPDATE inbox_items SET channel_id = substr(channel_id, 3) WHERE channel_id LIKE '1:%';
UPDATE tracks SET requester_user_id = substr(requester_user_id, 3) WHERE requester_user_id LIKE '1:%';
UPDATE tracks SET owner_user_id = substr(owner_user_id, 3) WHERE owner_user_id LIKE '1:%';
UPDATE tracks SET ball_on = substr(ball_on, 3) WHERE ball_on LIKE '1:%';
UPDATE tracks SET assignee_user_id = substr(assignee_user_id, 3) WHERE assignee_user_id LIKE '1:%';
UPDATE user_analyses SET user_id = substr(user_id, 3) WHERE user_id LIKE '1:%';
UPDATE digest_participants SET user_id = substr(user_id, 3) WHERE user_id LIKE '1:%';
UPDATE digests SET channel_id = substr(channel_id, 3) WHERE channel_id LIKE '1:%';
UPDATE channel_settings SET channel_id = substr(channel_id, 3) WHERE channel_id LIKE '1:%';
UPDATE sync_state SET channel_id = substr(channel_id, 3) WHERE channel_id LIKE '1:%';
UPDATE files SET message_channel_id = substr(message_channel_id, 3) WHERE message_channel_id LIKE '1:%';
UPDATE reactions SET user_id = substr(user_id, 3) WHERE user_id LIKE '1:%';
UPDATE reactions SET channel_id = substr(channel_id, 3) WHERE channel_id LIKE '1:%';
UPDATE messages SET user_id = substr(user_id, 3) WHERE user_id LIKE '1:%';
UPDATE messages SET channel_id = substr(channel_id, 3) WHERE channel_id LIKE '1:%';
UPDATE users SET id = substr(id, 3) WHERE id LIKE '1:%';
UPDATE channels SET dm_user_id = substr(dm_user_id, 3) WHERE dm_user_id LIKE '1:%';
UPDATE channels SET id = substr(id, 3) WHERE id LIKE '1:%';
DROP TABLE IF EXISTS slack_accounts;
```

Notes for the implementer:
- `memory_provenance` has a `scheme` column distinguishing `''` (bare Slack message refs) from `mail:`/`cal:`/`act:`/`chat:` — only `scheme = ''` rows carry Slack ids, hence the `WHERE scheme = ''` guard (grep `internal/db/schema.sql` for `memory_provenance` to confirm the exact column name/values before writing; if the scheme discriminator has a different column name, adapt the WHERE clause accordingly — do NOT namespace `mail:`/`cal:`/`act:`/`chat:` rows).
- `inbox_items.channel_id` for Gmail/IMAP items already carries a `gmail:`/`imap:` prefix (unrelated existing scheme) — the `NOT LIKE 'gmail:%' AND NOT LIKE 'imap:%'` guards keep those untouched; same reasoning for `inbox_learned_rules.scope_key`.
- Table names confirmed via `internal/db/schema.sql`: `calendar_attendee_map` (line ~869) and `jira_user_map` (line ~962), both carrying a `slack_user_id` column.
- Confirm `people.slack_user_id` is `UNIQUE` (schema.sql line ~606) — the migration doesn't change uniqueness, just the value, so this is safe.

- [ ] **Step 4: Data-migration fixture test.** Follow the raw-SQL fixture harness shape from `internal/db/google_accounts_migration_test.go` (Task 4 of the Google plan, Step 4): `sql.Open("sqlite", ":memory:")`, `SetMaxOpenConns(1)`, `goose.UpTo(..., 43)`, seed `workspace` (current_user_id='U1'), a channel `C1`, a message from `U1` in `C1`, an `inbox_items` row with bare `channel_id='C1'`, a `channel:C1` learned rule — then `goose.UpByOne` to 44 and assert: `slack_accounts` has one row with `current_user_id='1:U1'`; `channels.id='1:C1'`; `messages.channel_id='1:C1'` and `messages.user_id='1:U1'`; `inbox_items.channel_id='1:C1'`; the learned rule's `scope_key='channel:1:C1'`. Also seed a `gmail:1:th1` `inbox_items` row and assert it is UNCHANGED after the migration (the `NOT LIKE 'gmail:%'` guard works).

- [ ] **Step 5: Run to verify failure, then implement, then verify pass**

Run: `go test ./internal/db/ -run TestMigration00044 -v 2>&1 | tee /tmp/s1b.log; echo "exit=$?"` → FAIL, then write the SQL from Step 3, then rerun → PASS.

- [ ] **Step 6: Mirror into `internal/db/schema.sql`** — add the `slack_accounts` CREATE TABLE block (before `email_accounts`), remove `current_user_id`/`search_last_date` from the `workspace` block. (Existing column comments elsewhere that reference "Slack user_id"/"Slack channel_id" stay accurate — they're still Slack ids, just namespaced now; add one comment on `channels.id`/`users.id`/`messages.channel_id`/`messages.user_id` noting the `"<accountID>:<rawID>"` format.)

- [ ] **Step 7: `TestAllTablesExist` + regenerate golden**

Add `"slack_accounts"` to the table list in `internal/db/db_test.go`.
Run: `go test ./internal/db/ -run TestSchemaGolden -update 2>&1 | tee /tmp/s1g.log; echo "exit=$?"`

- [ ] **Step 8: Full package run**

Run: `go test ./internal/db/ -v 2>&1 | tee /tmp/s1r.log; echo "exit=$?"` — expect PASS for the DB package; note (don't fix yet) any failures elsewhere referencing `ws.CurrentUserID`/`ws.SearchLastDate` — Task 3 fixes those.

- [ ] **Step 9: Commit**

```bash
git add internal/db/migrations/00044_slack_accounts.sql internal/db/schema.sql internal/db/db_test.go internal/db/slack_accounts_migration_test.go internal/db/testdata/schema_v73.golden
git commit -m "feat(db): slack_accounts table + namespaced Slack ids across the schema (migration 00044)"
```

---

### Task 2: `internal/slack` — namespace helpers + per-account token store

**Files:**
- Create: `internal/slack/namespace.go`
- Create: `internal/slack/namespace_test.go`
- Create: `internal/slack/token_store.go`
- Create: `internal/slack/token_store_test.go`

**Interfaces:**
- Produces:

```go
// internal/slack/namespace.go
func Namespace(accountID int64, rawID string) string      // "" in → "" out; else "<accountID>:<rawID>"
func SplitAccountID(id string) (accountID int64, rawID string, ok bool)  // ok=false if no valid "<int>:" prefix

// internal/slack/token_store.go
type Token struct {
	AccessToken string `json:"access_token"`
	TeamID      string `json:"team_id"`
	TeamName    string `json:"team_name"`
	UserID      string `json:"user_id"` // raw (unnamespaced) — the token owner's Slack user id
}
type TokenStore struct{ path string }
func NewTokenStore(workspaceDir string, accountID int64) *TokenStore // -> slack_token_<id>.json
func (s *TokenStore) Load() (*Token, error)   // os.IsNotExist -> (nil, nil)
func (s *TokenStore) Save(t *Token) error     // 0600, MkdirAll 0700
func (s *TokenStore) Delete() error           // IsNotExist -> nil
func (s *TokenStore) Exists() bool
```

- [ ] **Step 1: Write failing tests**

`internal/slack/namespace_test.go`:

```go
package slack

import "testing"

func TestNamespace(t *testing.T) {
	if got := Namespace(2, "C0123"); got != "2:C0123" {
		t.Fatalf("got %q", got)
	}
	if got := Namespace(2, ""); got != "" {
		t.Fatalf("empty raw id must stay empty, got %q", got)
	}
}

func TestSplitAccountID(t *testing.T) {
	acct, raw, ok := SplitAccountID("2:C0123")
	if !ok || acct != 2 || raw != "C0123" {
		t.Fatalf("got acct=%d raw=%q ok=%v", acct, raw, ok)
	}
	if _, _, ok := SplitAccountID("C0123"); ok {
		t.Fatal("no colon prefix should not parse as namespaced")
	}
	if _, _, ok := SplitAccountID(""); ok {
		t.Fatal("empty string should not parse")
	}
}
```

`internal/slack/token_store_test.go` (copy the `imap` credential-store test shape at `internal/imap/credentials_test.go`): Save→Load roundtrip in `t.TempDir()`, file mode 0600, `Path()` ends in `slack_token_3.json` for `NewTokenStore(dir, 3)`, `Load()` on a missing file returns `(nil, nil)`, `Delete()` on a missing file returns `nil`.

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/slack/ -run 'Namespace|SplitAccountID|TokenStore' -v 2>&1 | tee /tmp/s2.log; echo "exit=$?"` → FAIL.

- [ ] **Step 3: Implement**

```go
// internal/slack/namespace.go
package slack

import (
	"strconv"
	"strings"
)

func Namespace(accountID int64, rawID string) string {
	if rawID == "" {
		return ""
	}
	return strconv.FormatInt(accountID, 10) + ":" + rawID
}

func SplitAccountID(id string) (accountID int64, rawID string, ok bool) {
	idx := strings.IndexByte(id, ':')
	if idx <= 0 {
		return 0, id, false
	}
	n, err := strconv.ParseInt(id[:idx], 10, 64)
	if err != nil {
		return 0, id, false
	}
	return n, id[idx+1:], true
}
```

`token_store.go` copies the shape of `internal/imap/credentials.go` (`Load`/`Save`/`Delete`/`Exists`, `encoding/json`, `os.MkdirAll(filepath.Dir(path), 0o700)`, `os.WriteFile(path, data, 0o600)`), filename `fmt.Sprintf("slack_token_%d.json", accountID)`.

- [ ] **Step 4: Run to verify pass**

Run: `go test ./internal/slack/ -v 2>&1 | tee /tmp/s2r.log; echo "exit=$?"` → PASS. `go build ./... 2>&1 | tee /tmp/s2b.log; echo "exit=$?"` → 0.

- [ ] **Step 5: Commit**

```bash
git add internal/slack/namespace.go internal/slack/namespace_test.go internal/slack/token_store.go internal/slack/token_store_test.go
git commit -m "feat(slack): account-id namespace helpers, per-account token file store"
```

---

### Task 3: `internal/db` — slack_accounts CRUD, repoint GetCurrentUserID/search watermark

**Files:**
- Create: `internal/db/slack_accounts.go`
- Create: `internal/db/slack_accounts_test.go`
- Modify: `internal/db/workspace.go` (delete `SetCurrentUserID`; `GetCurrentUserID` now reads `slack_accounts` id=1; delete `GetSearchLastDate`/`UpdateSearchLastDate` — moved to per-account; delete `CurrentUserID` field references in `GetWorkspace`)
- Modify: `internal/db/models.go` (`Workspace` struct loses `CurrentUserID` field)
- Modify: `internal/db/inbox.go` (`ListStreamCandidatesSince` signature — see Task 7, not this task; leave as-is here)
- Modify: any other file referencing `Workspace.CurrentUserID` at the DB layer (none found beyond `workspace.go`/`models.go` — `orchestrator.go`, `style_sample.go`, `cmd/profile.go` are fixed in Tasks 4 and 7)

**Interfaces:**
- Produces:

```go
type SlackAccount struct {
	ID             int64
	TeamID         string
	TeamName       string
	TeamDomain     string
	Label          string
	CurrentUserID  string // namespaced, e.g. "2:U0123"
	Status         string // ok | error | revoked | removed
	Error          string
	Enabled        bool
	SearchLastDate string
	CreatedAt      string
}
func (db *DB) CreateSlackAccount(a SlackAccount) (int64, error)
func (db *DB) ListSlackAccounts() ([]SlackAccount, error)           // ORDER BY id ASC
func (db *DB) ListEnabledSlackAccounts() ([]SlackAccount, error)    // WHERE enabled = 1 AND status != 'removed'
func (db *DB) GetSlackAccount(id int64) (SlackAccount, error)       // sql.ErrNoRows wrapped
func (db *DB) UpdateSlackAccountConnection(id int64, teamID, teamName, teamDomain, currentUserID string) error
func (db *DB) SetSlackAccountLabel(id int64, label string) error
func (db *DB) SetSlackAccountEnabled(id int64, enabled bool) error
func (db *DB) SetSlackAccountAuthState(id int64, status, errMsg string) error
func (db *DB) SetSlackAccountRemoved(id int64) error                // status='removed', enabled=0 (non-destructive)
func (db *DB) GetSlackAccountSearchWatermark(id int64) (string, error)
func (db *DB) SetSlackAccountSearchWatermark(id int64, date string) error
func (db *DB) ListOwnerSlackUserIDs() ([]string, error)             // enabled accounts' non-empty current_user_id, namespaced
// db.GetCurrentUserID() keeps its exact (string, error) signature — now reads
// slack_accounts WHERE id = 1 (documented v1 pin, see Global Constraints).
```

- [ ] **Step 1: Write failing tests** in `internal/db/slack_accounts_test.go`: create→list→get roundtrip; `SetSlackAccountAuthState` on a missing row returns an error with `RowsAffected()==0` (copy the `SetEmailAccountAuthState` shape); `SetSlackAccountRemoved` sets `status='removed'` and `enabled=0` but the row is still returned by `GetSlackAccount`/`ListSlackAccounts` (non-destructive — it must NOT appear in `ListEnabledSlackAccounts`); `GetSlackAccountSearchWatermark` on a fresh account returns `("", nil)`; `ListOwnerSlackUserIDs` with two accounts (one enabled with `current_user_id="1:U1"`, one disabled with `current_user_id="2:U2"`) returns only `["1:U1"]`; with an account whose `current_user_id` is still empty (mid-OAuth), that account is excluded from the list (degenerate case, no error — per [[feedback_test_degenerate_clean_exit]]). `GetCurrentUserID()` test: fresh DB with no `slack_accounts` row returns `("", nil)`; after creating account #1 with `current_user_id="1:U1"`, returns `"1:U1"`; after ALSO creating account #2, still returns account #1's value (proves the pin).

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/db/ -run 'SlackAccount|GetCurrentUserID' -v 2>&1 | tee /tmp/s3.log; echo "exit=$?"` → FAIL.

- [ ] **Step 3: Implement `internal/db/slack_accounts.go`** — copy the CRUD shape of `internal/db/google_accounts.go` (Task 2 of the Google plan) exactly, substituting the `SlackAccount` fields above. `ListOwnerSlackUserIDs`:

```go
func (db *DB) ListOwnerSlackUserIDs() ([]string, error) {
	rows, err := db.Query(`SELECT current_user_id FROM slack_accounts
		WHERE enabled = 1 AND status != 'removed' AND current_user_id != ''`)
	if err != nil {
		return nil, fmt.Errorf("listing owner slack user ids: %w", err)
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, fmt.Errorf("scanning owner slack user id: %w", err)
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}
```

- [ ] **Step 4: Update `internal/db/workspace.go`**: delete `SetCurrentUserID` entirely (its only caller, `internal/sync/orchestrator.go`, is fixed in Task 4 to call `SetSlackAccountAuthState`/`UpdateSlackAccountConnection` instead); delete `GetSearchLastDate`/`UpdateSearchLastDate` (moved to `GetSlackAccountSearchWatermark`/`SetSlackAccountSearchWatermark`); rewrite `GetCurrentUserID`:

```go
// GetCurrentUserID returns account #1's Slack user id — the app's canonical
// owner identity for Jira/style-sample/people-card purposes. Pinned to
// account #1 in v1; does not widen across additional connected accounts.
func (db *DB) GetCurrentUserID() (string, error) {
	var userID string
	err := db.QueryRow(`SELECT current_user_id FROM slack_accounts WHERE id = 1`).Scan(&userID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("getting current_user_id: %w", err)
	}
	return userID, nil
}
```

`GetWorkspace` drops the `current_user_id` column from its `SELECT`/`Scan`; `Workspace` struct in `models.go` drops the `CurrentUserID` field.

- [ ] **Step 5: Chase compile errors**

Run: `go build ./... 2>&1 | tee /tmp/s3b.log; echo "exit=$?"` — expect breakage in `internal/sync` (orchestrator.go), `internal/inbox/style_sample.go`, `cmd/profile.go`. For THIS task only, stub minimally (Task 4/7 fix these properly) so the build is green: e.g. in `style_sample.go` replace `ws.CurrentUserID` with a call to `p.db.GetCurrentUserID()`; in `cmd/profile.go` same substitution; in `orchestrator.go` temporarily read `o.db.GetCurrentUserID()` in place of `ws.CurrentUserID` (Task 4 replaces this with the per-account field properly).

- [ ] **Step 6: Run**

Run: `go test ./internal/db/ ./internal/inbox/ ./cmd/ 2>&1 | tee /tmp/s3r.log; echo "exit=$?"` → PASS. `go build ./... && go vet ./... 2>&1 | tee /tmp/s3v.log; echo "exit=$?"` → 0.

- [ ] **Step 7: Commit**

```bash
git add internal/db/ internal/inbox/style_sample.go cmd/profile.go internal/sync/orchestrator.go
git commit -m "feat(db): slack_accounts CRUD; pin GetCurrentUserID to account #1"
```

---

### Task 4: `internal/sync` — Orchestrator becomes per-account

**Files:**
- Modify: `internal/sync/orchestrator.go` (`Orchestrator` gains `accountID int64` + `account db.SlackAccount`; `NewOrchestrator(database, slackClient, cfg, accountID int64)`; `ensureWorkspace`/`syncCurrentUser` become account-scoped; workspace-team-info write goes through a NEW `UpsertSlackTeamInfo`-style call on `slack_accounts`, not `workspace`)
- Modify: `internal/sync/message_sync.go` (`channelID` parameters carry NAMESPACED ids; Slack API calls strip the prefix via `watchtowerslack.SplitAccountID`)
- Modify: `internal/sync/user_sync.go` (same: DB reads/writes namespaced, API calls raw)
- Modify: `internal/sync/thread_sync.go` (same)
- Modify: `internal/sync/search_sync.go` (same; `EnsureChannel`/message inserts namespace before writing)
- Modify: `internal/sync/worker.go` (no signature change — `SyncTask.ChannelID` documented as namespaced)
- Modify: all `internal/sync/*_test.go` (harness constructs `NewOrchestrator(..., accountID)`, seeds a `slack_accounts` row first)

**Interfaces:**
- Consumes: Task 2 (`slack.Namespace`/`slack.SplitAccountID`), Task 3 (`db.SlackAccount`, `SetSlackAccountAuthState`, `UpdateSlackAccountConnection`, `GetSlackAccountSearchWatermark`/`SetSlackAccountSearchWatermark`).
- Produces: `func NewOrchestrator(database *db.DB, slackClient *watchtowerslack.Client, cfg *config.Config, accountID int64) *Orchestrator` — Task 5 wires it per account.

**Design rule for every step below:** inside `internal/sync`, `channelID`/`userID` string values passed between the Orchestrator's own methods, stored via `SyncTask`, or written to the DB are **always namespaced** (`"<accountID>:<rawID>"`). The **only** places that need the raw (unnamespaced) id are the literal Slack SDK calls: `o.slackClient.GetConversationHistory` (`ChannelID` field), `GetConversationReplies(ctx, channelID, ...)`, `GetChannelReadCursor(ctx, channelID)`, `GetUserInfo(ctx, userID)`. Strip the prefix with `_, rawID, _ := watchtowerslack.SplitAccountID(channelID)` immediately before those calls only.

- [ ] **Step 1: Update the test harness + write new failing tests.** In every existing `internal/sync/*_test.go`, seed an account first and pass its id:

```go
accountID, err := database.CreateSlackAccount(db.SlackAccount{TeamID: "T1", Label: "Test"})
// ...
o := NewOrchestrator(database, client, cfg, accountID)
```

Any hand-built `db.Channel{ID: "C1", ...}`/`db.Message{ChannelID: "C1", ...}` fixtures in these tests become `db.Channel{ID: "1:C1", ...}` (or whatever `accountID` the test uses) since the Orchestrator now expects namespaced ids at its DB boundary.

New test `TestSyncTwoAccountsNoCollision` (`orchestrator_test.go`): two accounts, both with a Slack channel raw-id `C001` (same raw id, different orgs — the exact collision case the whole design defends against), run a full sync for both via two `Orchestrator`s against two `httptest` servers, assert `channels` ends up with BOTH `"1:C001"` and `"2:C001"` as distinct rows with independent message histories (no cross-contamination).

New test `TestSyncChannelUsesRawIDForSlackAPI`: seed a channel `"3:C001"`, run `syncChannel`, assert the `httptest` handler observed the raw query param `channel=C001` (not `channel=3:C001`) — proves the de-namespacing boundary is correctly placed.

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/sync/ -v 2>&1 | tee /tmp/s4.log; echo "exit=$?"` → FAIL (constructor arity, id mismatches).

- [ ] **Step 3: Implement.**

`orchestrator.go`: add `accountID int64` field, set in `NewOrchestrator`. Replace the `ensureWorkspace(ctx)` body (currently upserts `workspace` from `GetTeamInfo`) with a call that updates `slack_accounts` instead:

```go
func (o *Orchestrator) ensureWorkspace(ctx context.Context) error {
	acct, err := o.db.GetSlackAccount(o.accountID)
	if err != nil {
		return fmt.Errorf("loading slack account %d: %w", o.accountID, err)
	}
	if acct.TeamID != "" {
		o.logger.Printf("workspace: %s (%s) [cached]", acct.TeamName, acct.TeamID)
		o.account = acct
		return nil
	}
	info, err := o.slackClient.GetTeamInfo(ctx)
	if err != nil {
		return fmt.Errorf("fetching team info: %w", err)
	}
	if err := o.db.UpdateSlackAccountConnection(o.accountID, info.ID, info.Name, info.Domain, acct.CurrentUserID); err != nil {
		return fmt.Errorf("updating slack account %d: %w", o.accountID, err)
	}
	acct.TeamID, acct.TeamName, acct.TeamDomain = info.ID, info.Name, info.Domain
	o.account = acct
	return nil
}
```

`syncCurrentUser`: replace `o.db.SetCurrentUserID(authResp.UserID)` with

```go
namespaced := watchtowerslack.Namespace(o.accountID, authResp.UserID)
if err := o.db.UpdateSlackAccountConnection(o.accountID, o.account.TeamID, o.account.TeamName, o.account.TeamDomain, namespaced); err != nil {
	o.logger.Printf("failed to save current user id: %v", err)
	return
}
o.account.CurrentUserID = namespaced
```

`Run`'s `if ws.CurrentUserID == ""` check becomes `if o.account.CurrentUserID == ""`.

`message_sync.go`: `syncChannel(ctx, channelID, full)` — `channelID` is namespaced everywhere it's used for logging/DB (`o.db.GetSyncState(channelID)`, `o.db.UpdateSyncState(channelID, ...)`, `o.channelName(channelID)`); at the Slack call site:

```go
_, rawID, _ := watchtowerslack.SplitAccountID(channelID)
resp, err := o.slackClient.GetConversationHistory(ctx, watchtowerslack.HistoryOptions{
	ChannelID: rawID,
	// ...
})
```

`upsertMessagePage(channelID string, messages []goslack.Message)` — `channelID` param is already namespaced (caller passes it through unchanged); build each `db.Message` with `ChannelID: channelID, UserID: watchtowerslack.Namespace(o.accountID, msg.User)` (raw `msg.User` comes straight from the Slack SDK response, so it needs namespacing here, unlike `channelID` which arrives pre-namespaced).

`buildChannelQueue`: reads `db.Channel` rows (already namespaced from storage) to build `SyncTask{ChannelID: ch.ID}` — no change needed beyond confirming `ch.ID` is namespaced (it is, since `channels.id` is namespaced at write time).

`thread_sync.go`: `syncThread(ctx, channelID, threadTS)` strips the prefix only for `o.slackClient.GetConversationReplies(ctx, rawID, threadTS)`, then calls `o.upsertMessagePage(channelID, replies)` with the ORIGINAL namespaced `channelID`.

`user_sync.go`: `fetchUserProfilesIndividually`/`fetchAllUserProfiles` — `o.db.GetIncompleteUserIDs()` returns namespaced ids (stored that way); strip before `o.slackClient.GetUserInfo(ctx, rawID)`; build `db.User{ID: userID /* namespaced */, ...}` from the response, with `userID` being the namespaced id you started from (not the raw one echoed back by the API).

`search_sync.go`: `syncViaSearch` — `o.db.EnsureChannel(msg.Channel.ID, ...)` and message inserts need `watchtowerslack.Namespace(o.accountID, msg.Channel.ID)`/`watchtowerslack.Namespace(o.accountID, msg.User)` since `msg.Channel.ID`/`msg.User` come raw from `SearchMessages`. `o.discoveredChannelIDs` keys become namespaced too (populated from the same namespaced value used for `EnsureChannel`). Search watermark reads/writes switch from `o.db.GetSearchLastDate()`/`UpdateSearchLastDate()` to `o.db.GetSlackAccountSearchWatermark(o.accountID)`/`SetSlackAccountSearchWatermark(o.accountID, date)`.

`syncMetadata` (channel/user full listing, `UpsertUser`/`UpsertChannel` call sites around line 450/495): namespace `u.ID`/`ch.ID` (raw from `GetUsers`/`GetChannels`) before building `db.User{}`/`db.Channel{}`; `ch.DMUserID` gets namespaced too if non-empty.

`channelName(id string)` (used for log lines) — takes the namespaced id, looks up `o.channelNames[id]` (map already keyed by namespaced id since populated during the same sync run) — no change needed beyond confirming the map key matches.

- [ ] **Step 4: Run**

Run: `go test ./internal/sync/ -v 2>&1 | tee /tmp/s4r.log; echo "exit=$?"` → PASS. `go build ./... 2>&1 | tee /tmp/s4b.log; echo "exit=$?"` → 0.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(sync): per-account orchestrator, namespaced ids at the DB boundary"
```

---

### Task 5: Wiring — `wireSlackSyncers`, daemon fan-out

**Files:**
- Modify: `cmd/sync.go` (replace the single `slackClient := watchtowerslack.NewClient(ws.SlackToken); orch = sync.NewOrchestrator(...)` block with `wireSlackSyncers`)
- Modify: `internal/daemon/daemon.go` (`orchestrator *sync.Orchestrator` field → `orchestrators []*sync.Orchestrator`; `New(cfg *config.Config) *Daemon` drops the orchestrator constructor param; new `SetOrchestrators(o []*sync.Orchestrator)`; `phaseSlackSync` loops, aggregates `last_sync.json` across all accounts)
- Modify: `internal/daemon/daemon_test.go` (whatever pins `New(orchestrator, cfg)`/`d.orchestrator`)
- Modify: every OTHER caller of `daemon.New` (grep `daemon.New(` across `cmd/`) to use `SetOrchestrators` after construction

**Interfaces:**
- Consumes: Task 4.
- Produces:

```go
// internal/daemon
func New(cfg *config.Config) *Daemon
func (d *Daemon) SetOrchestrators(o []*sync.Orchestrator)
```

- [ ] **Step 1: Write failing test.** `internal/daemon/daemon_test.go`: `TestPhaseSlackSyncAggregatesAcrossAccounts` — two orchestrators (fake/no-op ones backed by `httptest` returning empty history, or a minimal stub satisfying whatever interface `phaseSlackSync` needs — check whether `Orchestrator` is a concrete struct or an interface; if concrete, use two real `Orchestrator`s against two `httptest.Server`s each returning zero channels so `Run` completes fast), `SetOrchestrators([o1, o2])`, call `d.phaseSlackSync(ctx)`, assert no error and that `last_sync.json` reflects both accounts having run (e.g. via `Progress().Snapshot()` per-account, summed). `TestPhaseSlackSyncEmptySlice`: `SetOrchestrators(nil)` → `phaseSlackSync` returns nil immediately (degenerate case, matches the existing `d.orchestrator == nil` early-return).

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/daemon/ -run PhaseSlackSync -v 2>&1 | tee /tmp/s5.log; echo "exit=$?"` → FAIL.

- [ ] **Step 3: Implement.**

`daemon.go`:

```go
type Daemon struct {
	// ...
	orchestrators []*sync.Orchestrator // was: orchestrator *sync.Orchestrator
}

func New(cfg *config.Config) *Daemon {
	return &Daemon{config: cfg}
}

func (d *Daemon) SetOrchestrators(o []*sync.Orchestrator) {
	d.orchestrators = o
}

// phaseSlackSync runs every connected account's orchestrator and writes one
// aggregated last_sync.json. One account's error is logged and does not
// block the others (the wireImapSyncers fan-out pattern) — matching
// INBOX-09: the phase-level watermark logic downstream is unaffected since
// each orchestrator advances its own account's sync_state independently.
func (d *Daemon) phaseSlackSync(ctx context.Context) error {
	if len(d.orchestrators) == 0 {
		return nil
	}
	var firstErr error
	var snaps []sync.ProgressSnapshot // adjust to the real Snapshot() return type
	for _, o := range d.orchestrators {
		if err := o.Run(ctx, sync.SyncOptions{}); err != nil {
			d.logger.Printf("sync error: %v", err)
			if firstErr == nil {
				firstErr = err
			}
		}
		snaps = append(snaps, o.Progress().Snapshot())
	}
	resultPath := filepath.Join(d.config.WorkspaceDir(), "last_sync.json")
	if err := sync.WriteSyncResult(resultPath, sync.ResultFromSnapshots(snaps, firstErr)); err != nil {
		d.logger.Printf("failed to write sync result: %v", err)
	}
	return firstErr
}
```

If `sync.ResultFromSnapshot`/`WriteSyncResult` only accept a single snapshot today, add a small `ResultFromSnapshots(snaps []ProgressSnapshot, err error) *Result` in `internal/sync/result.go` that sums the numeric fields (messages synced, channels synced, etc. — check `Result`'s exact fields via `grep -n "type Result struct" -A20 internal/sync/result.go`) and concatenates any per-account error text; keep `ResultFromSnapshot` (singular) in place for any other caller.

`cmd/sync.go`:

```go
func wireSlackSyncers(database *db.DB, cfg *config.Config, logger *log.Logger) []*sync.Orchestrator {
	accounts, err := database.ListEnabledSlackAccounts()
	if err != nil {
		logger.Printf("slack: failed to list accounts: %v", err)
		return nil
	}
	var orchestrators []*sync.Orchestrator
	for _, acct := range accounts {
		store := watchtowerslack.NewTokenStore(cfg.WorkspaceDir(), acct.ID)
		token, err := store.Load()
		if err != nil || token == nil {
			if err != nil {
				logger.Printf("slack: account %d: failed to load token: %v", acct.ID, err)
			}
			continue
		}
		client := watchtowerslack.NewClient(token.AccessToken)
		client.SetLogger(logger)
		orchestrators = append(orchestrators, sync.NewOrchestrator(database, client, cfg, acct.ID))
	}
	return orchestrators
}
```

Call site (`runSync`, replacing the current `if ws.SlackToken != "" { slackClient := ...; orch = sync.NewOrchestrator(...) }` block): also call `ensureLegacySlackAccount` (Task 6) immediately before `wireSlackSyncers` so a fresh single-account install still works. Wherever the daemon is constructed for the CLI (`daemon.New(orch, cfg)` today), change to `d := daemon.New(cfg); d.SetOrchestrators(wireSlackSyncers(database, cfg, logger))`.

- [ ] **Step 4: Run**

Run: `go test ./internal/daemon/ ./cmd/ ./internal/sync/ 2>&1 | tee /tmp/s5r.log; echo "exit=$?"` → PASS. `go build ./... 2>&1 | tee /tmp/s5b.log; echo "exit=$?"` → 0.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(daemon): slack syncer fan-out, aggregated sync result across accounts"
```

---

### Task 6: CLI — `slack add/login/accounts/enable/disable/remove`, legacy seed, config retirement

**Files:**
- Create: `cmd/slack.go` (new subcommands)
- Create: `cmd/slack_legacy.go` (`ensureLegacySlackAccount`)
- Create: `cmd/slack_test.go`
- Modify: `cmd/auth.go` (`login`/`logout` become account-#1 aliases; `saveAuthResult` writes to `slack_accounts`/`slack_token_<id>.json` instead of `config.yaml`)
- Modify: `internal/config/config.go` (`WorkspaceConfig.SlackToken` field kept for the `ValidateWorkspace`/`isValidSlackToken` back-compat read path — see Step 3 — but no longer written to by new logins)
- Modify: `cmd/sync.go` (the `ws.SlackToken != ""` gate — see Step 3)

**Interfaces:**
- Produces:

```go
// cmd/slack_legacy.go — idempotent; called from wireSlackSyncers's call site
// and every alias command. If slack_accounts is empty and
// workspaces.<ws>.slack_token is set in config: create account #1
// (team info via auth.test), write slack_token_1.json, blank the config
// key (best-effort — old configs may be read-only; log, don't fail).
func ensureLegacySlackAccount(ctx context.Context, cfg *config.Config, database *db.DB, logger *log.Logger) (int64, error)
```

`watchtower slack add [--label L] [--no-open] [--app-return]` flow: `auth.Login` (unchanged) → on success, `CreateSlackAccount` → `AuthTest` via a client built from the fresh token → `UpdateSlackAccountConnection` (team info + namespaced current_user_id) → `TokenStore.Save` → print summary. On any failure after `CreateSlackAccount`, delete the row (rollback, mirror `createEmailAccountWithCredentials`'s rollback pattern).

- [ ] **Step 1: Failing tests** (`cmd/slack_test.go`): (a) `ensureLegacySlackAccount` — temp config with `workspaces.test.slack_token` set, empty `slack_accounts` table → returns account id 1, `slack_token_1.json` written with that token, row exists with the token's team info (stub `AuthTest`/`GetTeamInfo` via `watchtowerslack.NewClientWithAPI` against an `httptest` server); second call is a no-op (idempotent, table non-empty → returns existing id 1 without re-creating); with no config token and no `slack_accounts` rows → returns `(0, nil)`, no error (degenerate clean exit). (b) `slack accounts` with zero accounts prints a helpful "no accounts connected" line, not an error.

- [ ] **Step 2: Run to verify failure**

Run: `go test ./cmd/ -run 'LegacySlackAccount|SlackAccounts' -v 2>&1 | tee /tmp/s6.log; echo "exit=$?"` → FAIL.

- [ ] **Step 3: Implement.**

`cmd/slack.go` subcommands: `add`, `login --account <id>` (re-consent, same `auth.Login` flow, `UpdateSlackAccountConnection` on the given id instead of creating a new row), `accounts` (list: `#<id> <label|team_name> <status> [enabled|disabled]`), `enable <id>`/`disable <id>` (thin wrappers over `SetSlackAccountEnabled`), `remove <id>` (delete the token file via `TokenStore.Delete()`, then `SetSlackAccountRemoved(id)` — **not** `DeleteSlackAccount`; there is no `DeleteSlackAccount` function in this plan, deliberately, per the non-destructive decision).

`cmd/auth.go`: `runAuthLogin`/`runAuthComplete` call `ensureLegacySlackAccount` first (create-if-absent), then behave as `slack login --account 1` when an account already exists, or as `slack add` (labelled "") when none exists yet — i.e. `saveAuthResult` is replaced by a call into the same account-creation path `cmd/slack.go` uses, NOT the old `viper.Set("workspaces."+workspace+".slack_token", ...)` write. `runAuthLogout` becomes `slack remove 1` (create-if-absent semantics don't apply to logout — if account #1 doesn't exist, this is a no-op, matching today's `auth logout` behavior with no token set).

`internal/config/config.go`: `WorkspaceConfig.SlackToken` stays in the struct (removing it would break `mapstructure` unmarshaling of old config files, and `cfg.Validate()`/`isValidSlackToken` still reference it) but its only remaining role is the legacy-seed READ path inside `ensureLegacySlackAccount` — nothing writes it anymore. `cmd/sync.go`'s `if ws.SlackToken != "" { cfg.Validate() }` gate becomes `if hasAnySlackToken(cfg, database) { cfg.Validate() }` where `hasAnySlackToken` checks `ws.SlackToken != "" || len(database.ListEnabledSlackAccounts()) > 0` — Slack stays fully optional when neither source has a token, unchanged from today's contract.

- [ ] **Step 4: Run**

Run: `go test ./cmd/ 2>&1 | tee /tmp/s6r.log; echo "exit=$?"` → PASS. `go build ./... && go vet ./... 2>&1 | tee /tmp/s6v.log; echo "exit=$?"` → 0.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(cli): slack add/login/accounts/enable/disable/remove, legacy account seed"
```

---

### Task 7: Inbox — multi-account own-message exclusion, secretary brief attribution

**Files:**
- Modify: `internal/db/inbox.go` (`ListStreamCandidatesSince` — signature change, see Interfaces)
- Modify: `internal/inbox/triage.go` (call site passes owner ids, not a single string)
- Modify: `internal/inbox/pipeline.go` (`resolveCurrentUserID` stays for Jira/brief purposes — Global Constraints decision #1; a NEW `resolveOwnerSlackUserIDs` helper feeds the stream-candidate query)
- Modify: `internal/inbox/brief.go` or wherever `buildSecretaryBrief` lives (add a "connected Slack accounts" line when >1 account, mirroring the Gmail owner-addresses line)
- Modify: `internal/db/inbox_test.go`, `internal/inbox/triage_test.go`

**Interfaces:**
- Consumes: `db.ListOwnerSlackUserIDs()` (Task 3).
- Produces:

```go
// internal/db/inbox.go — was ListStreamCandidatesSince(currentUserID string, sinceTS float64, limit int)
func (db *DB) ListStreamCandidatesSince(ownerUserIDs []string, sinceTS float64, limit int) ([]InboxCandidate, error)
```

- [ ] **Step 1: Failing tests.** `internal/db/inbox_test.go`: rework `TestListStreamCandidatesSince` to pass `[]string{"U1"}` instead of `"U1"`; add `TestListStreamCandidatesSince_MultipleOwners`: messages from `"U1"` and `"U2"` (two different accounts' owner ids) are BOTH excluded when `ownerUserIDs = []string{"U1", "U2"}`; a message from `"U1"` is NOT excluded when `ownerUserIDs = []string{"U2"}` only (proves it's not accidentally excluding everything); empty `ownerUserIDs` slice excludes nothing (degenerate case — SQL `NOT IN ()` — verify the query builder handles a zero-length slice without producing invalid SQL, e.g. by skipping the clause entirely when the slice is empty).

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/db/ -run ListStreamCandidates -v 2>&1 | tee /tmp/s7.log; echo "exit=$?"` → FAIL.

- [ ] **Step 3: Implement.**

```go
func (db *DB) ListStreamCandidatesSince(ownerUserIDs []string, sinceTS float64, limit int) ([]InboxCandidate, error) {
	placeholders := make([]string, len(ownerUserIDs))
	args := []any{sinceTS}
	for i, id := range ownerUserIDs {
		placeholders[i] = "?"
		args = append(args, id)
	}
	exclude := ""
	if len(ownerUserIDs) > 0 {
		exclude = "AND m.user_id NOT IN (" + strings.Join(placeholders, ",") + ")"
	}
	args = append(args, limit)
	query := fmt.Sprintf(`
		SELECT m.channel_id, m.ts, COALESCE(m.thread_ts,''), m.user_id, m.text, COALESCE(m.permalink,''), m.ts_unix
		FROM messages m
		JOIN channels c ON c.id = m.channel_id
		WHERE m.ts_unix > ?
		  AND m.is_deleted = 0
		  AND COALESCE(m.subtype,'') = ''
		  AND m.user_id != ''
		  %s
		  AND c.type != 'dm'
		  AND NOT EXISTS (...)
		  AND NOT EXISTS (...)
		ORDER BY m.ts_unix ASC
		LIMIT ?`, exclude)
	rows, err := db.Query(query, args...)
	// ... unchanged scanning logic
}
```

(Keep the two `NOT EXISTS` subqueries byte-identical to today — only the exclusion clause and parameter binding change.)

`internal/inbox/pipeline.go`: add

```go
// resolveOwnerSlackUserIDs returns every connected, enabled Slack account's
// own user id, for excluding the owner's own messages from stream
// candidates. Distinct from resolveCurrentUserID, which stays pinned to
// account #1 for Jira/style/people-card purposes (Global Constraints #1).
func (p *Pipeline) resolveOwnerSlackUserIDs() ([]string, error) {
	return p.db.ListOwnerSlackUserIDs()
}
```

`triage.go`'s call site: `ownerIDs, err := p.resolveOwnerSlackUserIDs(); ... p.db.ListStreamCandidatesSince(ownerIDs, sinceTS, maxStream)`.

`buildSecretaryBrief`: after resolving accounts via `database.ListSlackAccounts()`, when `len(accounts) > 1`, append a line: `Connected Slack workspaces: <label1> (<team_name1>), <label2> (<team_name2>), ...` — so triage/composer prompts understand messages may come from any of them (matching the Gmail "owner email addresses" line's purpose and placement).

- [ ] **Step 4: Run**

Run: `go test ./internal/db/ ./internal/inbox/ 2>&1 | tee /tmp/s7r.log; echo "exit=$?"` → PASS.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(inbox): multi-account own-message exclusion, connected-workspaces brief line"
```

---

### Task 8: AI rendering — multi-account system prompt and permalinks

**Files:**
- Modify: `internal/ai/context_builder.go` (workspace line lists all connected Slack accounts instead of one `ws.Name`/`ws.Domain`; permalink rendering resolves domain per message via the channel-id prefix)
- Modify: `internal/ai/context_builder_test.go`
- Modify: `cmd/ask.go`, `cmd/root.go`, `cmd/status.go`, `internal/repl/repl.go`, `internal/repl/commands.go`, `internal/briefing/pipeline.go`, `internal/memory/reflect.go` (each `ws.Name`/`ws.Domain`/`ws.ID` read for AI-facing output becomes a `ListSlackAccounts()`-derived summary — see Step 3 per-file notes)

**Interfaces:**
- Produces: a small shared helper (place in `internal/db` next to `slack_accounts.go`, since every caller already imports `db`):

```go
// FormatConnectedWorkspaces renders "<label1> (<domain1>), <label2> (<domain2>)"
// for AI system-prompt / status-line display. Empty slice -> "".
func FormatConnectedWorkspaces(accounts []SlackAccount) string
```

- [ ] **Step 1: Failing tests.** `internal/db/slack_accounts_test.go` (add to the file from Task 3): `FormatConnectedWorkspaces` with 0/1/2 accounts. `internal/ai/context_builder_test.go`: seed two `slack_accounts` rows, assert the built system prompt contains both team names/domains instead of a single `ws.Name`/`ws.Domain` line; assert a permalink rendered for a message whose `channel_id` is `"2:C001"` uses account 2's domain (not account 1's).

- [ ] **Step 2: Run to verify failure**

Run: `go test ./internal/ai/ ./internal/db/ -run 'FormatConnectedWorkspaces|SystemPrompt|Permalink' -v 2>&1 | tee /tmp/s8.log; echo "exit=$?"` → FAIL.

- [ ] **Step 3: Implement.**

```go
// internal/db/slack_accounts.go
func FormatConnectedWorkspaces(accounts []SlackAccount) string {
	parts := make([]string, 0, len(accounts))
	for _, a := range accounts {
		name := a.Label
		if name == "" {
			name = a.TeamName
		}
		if a.TeamDomain != "" {
			parts = append(parts, fmt.Sprintf("%s (%s)", name, a.TeamDomain))
		} else {
			parts = append(parts, name)
		}
	}
	return strings.Join(parts, ", ")
}
```

`internal/ai/context_builder.go` — replace `ws, err := cb.db.GetWorkspace(); ... "Workspace: %s (domain: %s)"` with `accounts, err := cb.db.ListSlackAccounts(); ... "Connected Slack workspaces: %s"` using `db.FormatConnectedWorkspaces(accounts)`. Permalink rendering: wherever `context_builder.go` (or its response renderer, `ai.NewResponseRenderer`) turns a stored `channel_id`/`ts` into a link, it currently takes a single `domain`/`teamID` constructor argument — change the constructor to take `*db.DB` instead and resolve per-message: `acctID, rawID, ok := watchtowerslack.SplitAccountID(channelID); if ok { acct, _ := db.GetSlackAccount(acctID); domain = acct.TeamDomain; teamID = acct.TeamID }`.

`cmd/ask.go`, `cmd/root.go`, `cmd/status.go`, `internal/repl/*.go`: each currently does `ws, _ := database.GetWorkspace(); ...ws.Name, ws.Domain, ws.ID...` for a single status/prompt line — replace with `accounts, _ := database.ListSlackAccounts(); ...db.FormatConnectedWorkspaces(accounts)...`. `cmd/status.go`'s `"Workspace: %s (%s)"` line becomes one line per account (`for _, a := range accounts { fmt.Fprintf(out, "Slack: %s (%s) [%s]\n", ...) }`) rather than a single line — this is the CLI status output, low-risk to reshape.

`internal/briefing/pipeline.go:174`/`internal/memory/reflect.go:396` — both read `ws.ID` for a `workspaceID` value used as a label/key in briefing rows or reflection output; since `workspace.id` is UNCHANGED by this migration (kept as the frozen legacy snapshot per Task 1), these two call sites need NO change — verify with `go build` in Step 4 that they still compile against the trimmed `Workspace` struct (they read `.ID`, which still exists).

- [ ] **Step 4: Run**

Run: `go test ./internal/ai/ ./internal/db/ ./cmd/ ./internal/repl/ ./internal/briefing/ ./internal/memory/ 2>&1 | tee /tmp/s8r.log; echo "exit=$?"` → PASS. `go build ./... && go vet ./... 2>&1 | tee /tmp/s8v.log; echo "exit=$?"` → 0. Full sweep: `go test ./... 2>&1 | tee /tmp/s8all.log; echo "exit=$?"` → PASS.

- [ ] **Step 5: Commit**

```bash
git commit -am "feat(ai): multi-account system prompt and per-message permalink domain resolution"
```

---

### Task 9: Desktop — model, queries, ViewModel

**Files:**
- Create: `WatchtowerDesktop/Sources/Models/SlackAccount.swift`
- Create: `WatchtowerDesktop/Sources/Database/Queries/SlackAccountQueries.swift`
- Create: `WatchtowerDesktop/Sources/ViewModels/SlackAccountsViewModel.swift`
- Create: `WatchtowerDesktop/Tests/SlackAccountQueriesTests.swift`
- Create: `WatchtowerDesktop/Tests/SlackAccountsViewModelTests.swift`
- Modify: `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift` (add `slack_accounts` CREATE TABLE mirror + `insertSlackAccount(...)` fixture; `workspace` mirror drops `current_user_id`/`search_last_date`; note in a comment that `channels.id`/`users.id`/`messages.channel_id`/`messages.user_id` fixtures used by OTHER existing tests may now need namespaced values if those tests assert cross-table joins — audit `grep -rln 'insertMessage\|insertChannel' WatchtowerDesktop/Tests` and fix any fixture that asserts on a bare id string)
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (hold `slackAccountsViewModel` beside `googleAccountsViewModel`/`emailAccountsViewModel`)

**Interfaces:**
- Produces (Task 10 consumes):

```swift
struct SlackAccount: FetchableRecord, Identifiable, Equatable {
    let id: Int
    let teamName, teamDomain, label, currentUserID, status, error: String
    let enabled: Bool
    var isOK: Bool { status == "ok" }
    var displayName: String { label.isEmpty ? (teamName.isEmpty ? "Slack account #\(id)" : teamName) : label }
}
enum SlackAccountQueries {
    static func fetchAll(_ db: Database) throws -> [SlackAccount] // SELECT * FROM slack_accounts ORDER BY id ASC
}
@MainActor @Observable final class SlackAccountsViewModel {
    private(set) var accounts: [SlackAccount]
    var isConnecting: Bool
    var error: String?
    func refresh()
    func addAccount(label: String) async          // shells `slack add --app-return [--label L]`
    func relogin(_ account: SlackAccount) async    // `slack login --account <id> --app-return`
    func setEnabled(_ account: SlackAccount, enabled: Bool) async  // `slack enable|disable <id>`
    func remove(_ account: SlackAccount) async     // `slack remove <id>`
    func cancelConnect()
    static func addArgs(label: String) -> [String]        // pure, testable
    static func removeArgs(for account: SlackAccount) -> [String]
}
```

- [ ] **Step 1: Failing tests.** `SlackAccountQueriesTests`: insert two fixture rows via `insertSlackAccount`, `fetchAll` returns both in id order, fields mapped correctly including `enabled`/`status`. `SlackAccountsViewModelTests`: `addArgs(label: "Personal")` → `["slack", "add", "--app-return", "--label", "Personal"]`; `addArgs(label: "")` → `["slack", "add", "--app-return"]` (no empty `--label` flag); `removeArgs(for: account)` → `["slack", "remove", "3"]` for `id: 3`.

- [ ] **Step 2: Run to verify failure**

Run: `cd WatchtowerDesktop && swift test --filter SlackAccount > /tmp/s9.log 2>&1; echo "exit=$?"` → non-zero.

- [ ] **Step 3: Implement** — copy `GoogleAccountsViewModel`'s mechanics verbatim (`runCLI`/`runProcess` stdin-before-drain pattern), `refresh()` reads via `dbPool.read { SlackAccountQueries.fetchAll($0) }`, success path triggers `DaemonManager.restart()`.

- [ ] **Step 4: Run**

Run: `cd WatchtowerDesktop && swift test > /tmp/s9r.log 2>&1; echo "exit=$?"` → 0.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/ && git commit -m "feat(desktop): slack account model, queries, view model"
```

---

### Task 10: Desktop — Settings UI (greenfield)

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Settings/AddSlackAccountView.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Settings/SettingsView.swift` (new `slackAccountsSection`, placed near the top of the Data/Sources settings group — this is a NEW section, not a replacement, since there is no prior Slack settings block; wire the `confirmationDialog` removal pattern used by `calendarAccountPendingRemoval`)
- Modify: `docs/app-guide.md` (Settings → Slack section)

**Interfaces:**
- Consumes: Task 9's `SlackAccountsViewModel`.

- [ ] **Step 1: Build the section.** `slackAccountsSection`: `ForEach(vm.accounts)` → displayName + status dot (green ok / orange error / red revoked, `account.error` as tooltip) + `Toggle("Enabled", isOn: ...)` bound through `vm.setEnabled` + `Button("Re-login")` when not ok + `Button(role: .destructive) { pendingRemoval = account }`. `Button("Add Slack Workspace") { showAddSlackAccountSheet = true }`. `AddSlackAccountView` (small sheet, ~360×200): optional label `TextField`, Connect button → `vm.addAccount(label:)`, spinner + Cancel while `vm.isConnecting`, error text. Removal confirmation dialog text explicitly states data is kept ("Disconnects the workspace. Already-synced messages, digests, and situations stay in Watchtower.") — this UI copy is the one place the non-destructive decision needs to be visible to the owner, since it's a behavior change from how Google's removal reads.

- [ ] **Step 2: Verify by build + existing tests**

Run: `cd WatchtowerDesktop && swift build > /tmp/s10.log 2>&1; echo "exit=$?"` → 0. `swift test > /tmp/s10t.log 2>&1; echo "exit=$?"` → 0.

- [ ] **Step 3: Manual smoke via dev app** — `make app-dev`, open Settings: account #1 (migrated) listed with its team name; Add flow opens the OAuth browser; after consent the list refreshes and the daemon restarts. Note in the PR description that the owner will do the real second-workspace connect test (KW/AW/WD from the original screenshot).

- [ ] **Step 4: Update `docs/app-guide.md`** — Settings → Slack section (account list, add/enable/disable/remove, non-destructive removal note) — required by [[feedback_app_guide]].

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/ docs/app-guide.md && git commit -m "feat(desktop): slack accounts settings UI"
```

---

### Task 11: Docs, inventory, final sweep, live migration check

**Files:**
- Modify: `docs/inventory/inbox-pulse.md` (INBOX-09 wording: watermark rules apply per Slack account's `sync_state`/search watermark; note the own-message-exclusion widening to multi-account — extension of an existing contract, no new number, per [[feedback_inventory_no_duplicate_contracts]])
- Modify: `CLAUDE.md` (Feature Notes: short "Slack Multi-Account" paragraph mirroring the Google one)
- Modify: `docs/superpowers/specs/2026-07-31-slack-multi-account-design.md` (status → implemented; append the "documented v1 identity-scoping decisions" from this plan's Global Constraints as an "Implementation deviations/clarifications" section, matching the Google design doc's own precedent for documenting decisions made during implementation)

- [ ] **Step 1: Write the doc updates** (3–6 lines each).

- [ ] **Step 2: Full verification**

```bash
go build ./... && go vet ./... 2>&1 | tee /tmp/s11a.log; echo "exit=$?"
go test ./... 2>&1 | tee /tmp/s11b.log; echo "exit=$?"
golangci-lint run ./... 2>&1 | tee /tmp/s11c.log; echo "exit=$?"
cd WatchtowerDesktop && swift build > /tmp/s11d.log 2>&1; echo "exit=$?"; swift test > /tmp/s11e.log 2>&1; echo "exit=$?"
```

All exit=0.

- [ ] **Step 3: Live migration check on a COPY of the real DB** — `cp ~/.local/share/watchtower/whitebit/watchtower.db /tmp/wt-slack-migrate-test.db`, open it with a scratch config pointing at the copy, run the migration, assert: `slack_accounts` has one row with the real team info; `channels`/`messages`/`users` row counts unchanged; a spot-check message's `channel_id`/`user_id` now carry the `"1:"` prefix; `inbox_items` gmail-prefixed rows untouched; `digests`/`tracks`/`people_cards` row counts unchanged. Never run against the live DB (the daemon may hold it).

- [ ] **Step 4: Commit**

```bash
git add docs/ CLAUDE.md && git commit -m "docs: slack multi-account inventory + guide updates"
```

- [ ] **Step 5: Run the local-review skill** over the branch diff before the PR (per house process).

---

## Self-review notes

- Spec coverage: schema/namespace/token-store (T1–2), account CRUD + identity pin (T3), sync package threading (T4), daemon fan-out (T5), CLI + legacy seed (T6), inbox own-message exclusion + brief (T7), AI rendering (T8), Desktop (T9–10), docs/live-check (T11).
- Consistency: `slack.Namespace(accountID, rawID)` / `slack.SplitAccountID(id)` used identically in Tasks 4, 6, 7, 8; `NewOrchestrator(database, client, cfg, accountID int64)`; `SetSlackAccountAuthState(id, status, errMsg)`; token file `slack_token_<id>.json`; `db.ListOwnerSlackUserIDs()` feeds `ListStreamCandidatesSince([]string, ...)`.
- Known deliberate scope decisions an implementer must NOT "fix" without asking the owner first (all called out in Global Constraints): `GetCurrentUserID()` pinned to account #1; JSON-embedded id columns and the memory vault's markdown files not rewritten by the migration; `slack remove` is non-destructive, unlike `google remove`.
- All table/column names referenced by Task 1's migration were confirmed against `internal/db/schema.sql` directly (including `calendar_attendee_map`/`jira_user_map`, corrected from an earlier guess during planning) — no unverified names remain.
