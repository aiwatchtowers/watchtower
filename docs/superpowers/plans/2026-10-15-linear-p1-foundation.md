# Linear integration — Plan 1: schema, neutral views, connector

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Linear data lands in the Watchtower database. Users connect Linear
workspaces from the CLI and the daemon syncs them. The `tracker_*` views return
Jira and Linear rows side by side, and `ResolveOwner` knows the owner's Linear
identity.

**Architecture:** `internal/linear/` is a hand-written GraphQL connector (OAuth
with PKCE, rotating refresh tokens, a polling sync with per-team watermarks)
that writes its own `linear_*` tables, the way `internal/jira/` owns `jira_*`.
A second migration adds read-only `tracker_*` views (`UNION ALL` over the
Jira and Linear tables) that Plan 2's consumers will read. The Jira tables and
code are not modified.

**Tech Stack:** Go 1.26, `database/sql` + `modernc.org/sqlite`, goose
migrations, cobra CLI, `net/http/httptest` fakes; one Swift twin
(`OwnerQueries.swift`, GRDB).

**Spec:** `docs/superpowers/specs/2026-10-15-linear-integration-design.md`
(this plan covers spec §3, §4.1, §4.2, §5 sync part, §7 connector tests, §8
OWNER-01, and phases P1/P2 minus the items moved to Plan 2 below).

**Plan split.** The spec's five phases come in three plans, and each plan ships
working software on its own:
- **Plan 1 (this one):** `linear_*` tables, `tracker_*` views, connector, CLI,
  daemon phase, owner rung.
- **Plan 2:** consumers on `tracker_*`. It also adds the two migrations that
  only consumers need: `jira_slack_links` → `issue_slack_links` with the
  neutral key detector (spec §4.3), and the `linear` CHECK values (spec §4.4).
  Each lands next to its first reader.
- **Plan 3:** write tools and Desktop.

## Global Constraints

- Migrations are goose files in `internal/db/migrations/`. Plan 1 adds
  `00116_linear_tables.sql` and `00117_tracker_views.sql`. If `main` gained
  migrations in the meantime, take the next free numbers and rename everywhere
  in this plan. Each one is mirrored into `internal/db/schema.sql`, listed in
  `TestAllTablesExist` (tables only), and the golden + Swift test schema are
  regenerated (`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`).
- Jira tables, Jira code and every existing Jira test stay unmodified.
- Timestamps are stored as Linear returns them: UTC ISO-8601 with
  milliseconds and `Z` (`2026-10-15T12:00:00.000Z`), the same layout as
  `FormatJiraTime`. Empty is `''`, never NULL, for TEXT columns.
- `status_category` is one of `todo`, `in_progress`, `done`:
  - `triage`, `backlog` and `unstarted` map to `todo`;
  - `started` maps to `in_progress`;
  - `completed` and `canceled` map to `done`.
- Priority mapping:
  - Linear number to name: 1 = Urgent, 2 = High, 3 = Medium, 4 = Low, 0 = none (name `''`).
  - `priority_rank` mirrors the Linear number: 1–4 for 1–4, 0 for none.
  - Jira name to `priority_rank`: Highest 1, High 2, Medium 3, Low 4, Lowest 5, anything else 0.
- OAuth:
  - authorization code + PKCE S256;
  - no client secret is sent or embedded; client id from env `WATCHTOWER_LINEAR_CLIENT_ID`, else `linear.DefaultLinearClientID` (ldflags);
  - scopes `read,write,issues:create,comments:create` (comma-separated, as Linear's authorize endpoint expects);
  - `actor=user`;
  - loopback redirect only on the fixed ports 18531–18535, because the redirect URI must be pre-registered and a random port can't be.
- Endpoints (package vars, overridable in tests):
  - authorize `https://linear.app/oauth/authorize`;
  - token `https://api.linear.app/oauth/token`;
  - revoke `https://api.linear.app/oauth/revoke`;
  - GraphQL `https://api.linear.app/graphql`.
- Sync:
  - every GraphQL connection passes an explicit `first`;
  - issues pages are 25 with nested `history(first: 50)`, `labels(first: 20)`, `relations(first: 20)`;
  - other pages are 50, users 100.
  - A RATELIMITED or any other team error records `linear_sync_state.last_error` and leaves that team's watermark unchanged.
  - Auth failure → `ErrAuthRevoked` → the daemon marks the account `revoked`. Accounts are never deleted (`removed` is a soft delete).
- Error wrapping: `fmt.Errorf("<doing what>: %w", err)`. No silent `_ =` on DB writes.
- Tests that start an `httptest.Server` close it in `t.Cleanup`. No test spawns a process.
- Inner loop:
  - Go: `go test ./internal/<pkg>` for the touched package, `make lint-diff`.
  - Swift (Task 10 only): `make test-swift FILTER=OwnerQueriesTests`, `make lint-swift`.
- Public repo hygiene: fixtures use `acme`, `example.com`, ids like `user-1`. No real workspace data.
- Docs are in English.

## Review Focus

1. **A refresh-token race between the daemon and a CLI command** (both refresh the same expired token). Expected: one refresh, the other process picks up the saved pair, neither sees `invalid_grant`. Pinned in Task 6 (`TestClient_ConcurrentRefreshSingleFlight`).
2. **An issue moved to another team** (`ENG-12` → `OPS-40`) between two syncs. Expected: one row (same UUID) with `key = 'OPS-40'` and `previous_keys` containing `ENG-12`, no duplicate. Pinned in Task 7 (`TestSyncer_TeamMoveKeepsOneRow`).
3. **A sync interrupted halfway through a team's pages** (error on page 2). Expected: the rows from page 1 stay, the watermark is unchanged, and the next pass re-reads from the old watermark. Pinned in Task 7 (`TestSyncer_PageErrorHoldsWatermark`).
4. **A comment body with no `bodyData` or with malformed JSON.** Expected: the comment is stored with `mentioned_user_ids = '[]'` and the sync does not fail. Pinned in Task 5 (`TestMentionedUserIDs_Malformed`).
5. **An account whose grant was revoked in Linear's UI.** Expected: the account row becomes `revoked`, other accounts keep syncing, and the data is kept. Pinned in Task 9 (`TestPhaseLinearSync_RevokedMarksAccount`).

---

### Task 1: Migration 00116 — `linear_*` tables

**Files:**
- Create: `internal/db/migrations/00116_linear_tables.sql`
- Modify: `internal/db/schema.sql` (append the same DDL after the Jira block, before `jira_comments` is fine — keep it grouped under a `-- Linear (00116)` comment)
- Modify: `internal/db/db_test.go` (`TestAllTablesExist` list)
- Regenerate: `internal/db/testdata/*.golden`, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`
- Test: `internal/db/linear_migration_test.go`

**Interfaces:**
- Produces: tables `linear_accounts`, `linear_teams`, `linear_sync_state`, `linear_issues`, `linear_comments`, `linear_issue_history`, `linear_cycles`, `linear_projects`, `linear_relations`, `linear_user_map` with the columns below — every later task uses these names.

- [ ] **Step 1: Write the failing test**

```go
package db

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestMigration00116_LinearTablesDownUp(t *testing.T) {
	d := openTestDB(t)
	for _, tbl := range []string{"linear_accounts", "linear_teams", "linear_sync_state", "linear_issues",
		"linear_comments", "linear_issue_history", "linear_cycles", "linear_projects",
		"linear_relations", "linear_user_map"} {
		var n int
		require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?`, tbl).Scan(&n))
		require.Equal(t, 1, n, tbl)
	}
	// Composite keys: the same Linear id on two workspaces is two rows.
	_, err := d.Exec(`INSERT INTO linear_accounts (org_id) VALUES ('org-a'), ('org-b')`)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO linear_issues (account_id, id, key, team_id, title) VALUES (1,'i-1','ENG-1','t-1','a'), (2,'i-1','ENG-1','t-1','b')`)
	require.NoError(t, err)
	// org_id is unique: one row per workspace.
	_, err = d.Exec(`INSERT INTO linear_accounts (org_id) VALUES ('org-a')`)
	require.Error(t, err)
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `go test ./internal/db/ -run TestMigration00116`
Expected: FAIL (`linear_accounts` count 0).

- [ ] **Step 3: Write the migration**

`internal/db/migrations/00116_linear_tables.sql`:

```sql
-- +goose Up
-- Linear connector raw store (docs/superpowers/specs/2026-10-15-linear-integration-design.md §4.1).
-- One linear_accounts row per Linear workspace; every other table is scoped by
-- account_id. Issues are keyed by Linear's UUID: the human key ("ENG-12") moves
-- when an issue changes team, so it is a mutable column with previous_keys.
CREATE TABLE IF NOT EXISTS linear_accounts (
    id                       INTEGER PRIMARY KEY AUTOINCREMENT,
    org_id                   TEXT NOT NULL DEFAULT '',
    url_key                  TEXT NOT NULL DEFAULT '',
    org_name                 TEXT NOT NULL DEFAULT '',
    label                    TEXT NOT NULL DEFAULT '',
    status                   TEXT NOT NULL DEFAULT 'ok',  -- ok | error | revoked | removed
    error                    TEXT NOT NULL DEFAULT '',
    enabled                  INTEGER NOT NULL DEFAULT 1,
    owner_user_id            TEXT NOT NULL DEFAULT '',
    owner_email              TEXT NOT NULL DEFAULT '',
    owner_display_name       TEXT NOT NULL DEFAULT '',
    memory_last_extracted_ts REAL NOT NULL DEFAULT 0,
    ideas_floor              TEXT NOT NULL DEFAULT '',
    created_at               TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_linear_accounts_org ON linear_accounts(org_id) WHERE org_id != '';

CREATE TABLE IF NOT EXISTS linear_teams (
    account_id  INTEGER NOT NULL REFERENCES linear_accounts(id) ON DELETE CASCADE,
    id          TEXT NOT NULL,
    key         TEXT NOT NULL DEFAULT '',
    name        TEXT NOT NULL DEFAULT '',
    is_selected INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, id)
);
CREATE INDEX IF NOT EXISTS idx_linear_teams_key ON linear_teams(key);

CREATE TABLE IF NOT EXISTS linear_sync_state (
    account_id     INTEGER NOT NULL REFERENCES linear_accounts(id) ON DELETE CASCADE,
    team_id        TEXT NOT NULL,
    watermark      TEXT NOT NULL DEFAULT '',
    last_synced_at TEXT NOT NULL DEFAULT '',
    last_error     TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (account_id, team_id)
);

CREATE TABLE IF NOT EXISTS linear_issues (
    account_id            INTEGER NOT NULL REFERENCES linear_accounts(id) ON DELETE CASCADE,
    id                    TEXT NOT NULL,
    key                   TEXT NOT NULL,
    previous_keys         TEXT NOT NULL DEFAULT '[]',
    team_id               TEXT NOT NULL DEFAULT '',
    team_key              TEXT NOT NULL DEFAULT '',
    title                 TEXT NOT NULL DEFAULT '',
    description_text      TEXT NOT NULL DEFAULT '',
    state_name            TEXT NOT NULL DEFAULT '',
    state_type            TEXT NOT NULL DEFAULT '',
    status_category       TEXT NOT NULL DEFAULT 'todo',
    state_changed_at      TEXT NOT NULL DEFAULT '',
    assignee_id           TEXT NOT NULL DEFAULT '',
    assignee_email        TEXT NOT NULL DEFAULT '',
    assignee_display_name TEXT NOT NULL DEFAULT '',
    assignee_slack_id     TEXT NOT NULL DEFAULT '',
    creator_id            TEXT NOT NULL DEFAULT '',
    creator_email         TEXT NOT NULL DEFAULT '',
    creator_display_name  TEXT NOT NULL DEFAULT '',
    creator_slack_id      TEXT NOT NULL DEFAULT '',
    priority              INTEGER NOT NULL DEFAULT 0,
    estimate              REAL,
    due_date              TEXT NOT NULL DEFAULT '',
    cycle_id              TEXT NOT NULL DEFAULT '',
    project_id            TEXT NOT NULL DEFAULT '',
    parent_id             TEXT NOT NULL DEFAULT '',
    labels                TEXT NOT NULL DEFAULT '[]',
    url                   TEXT NOT NULL DEFAULT '',
    created_at            TEXT NOT NULL DEFAULT '',
    updated_at            TEXT NOT NULL DEFAULT '',
    completed_at          TEXT NOT NULL DEFAULT '',
    canceled_at           TEXT NOT NULL DEFAULT '',
    raw_json              TEXT NOT NULL DEFAULT '{}',
    synced_at             TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    is_deleted            INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (account_id, id)
);
CREATE INDEX IF NOT EXISTS idx_linear_issues_key ON linear_issues(key);
CREATE INDEX IF NOT EXISTS idx_linear_issues_team ON linear_issues(account_id, team_id);
CREATE INDEX IF NOT EXISTS idx_linear_issues_assignee ON linear_issues(assignee_id);
CREATE INDEX IF NOT EXISTS idx_linear_issues_assignee_status ON linear_issues(assignee_slack_id, status_category);
CREATE INDEX IF NOT EXISTS idx_linear_issues_status_cat ON linear_issues(status_category);
CREATE INDEX IF NOT EXISTS idx_linear_issues_cycle ON linear_issues(cycle_id);
CREATE INDEX IF NOT EXISTS idx_linear_issues_project ON linear_issues(project_id);
CREATE INDEX IF NOT EXISTS idx_linear_issues_updated ON linear_issues(updated_at);
CREATE INDEX IF NOT EXISTS idx_linear_issues_due ON linear_issues(due_date);
CREATE INDEX IF NOT EXISTS idx_linear_issues_synced ON linear_issues(synced_at);

CREATE TABLE IF NOT EXISTS linear_comments (
    account_id          INTEGER NOT NULL REFERENCES linear_accounts(id) ON DELETE CASCADE,
    id                  TEXT NOT NULL,
    issue_id            TEXT NOT NULL,
    issue_key           TEXT NOT NULL DEFAULT '',
    author_id           TEXT NOT NULL DEFAULT '',
    author_display_name TEXT NOT NULL DEFAULT '',
    body_text           TEXT NOT NULL DEFAULT '',
    mentioned_user_ids  TEXT NOT NULL DEFAULT '[]',
    created_at          TEXT NOT NULL DEFAULT '',
    updated_at          TEXT NOT NULL DEFAULT '',
    synced_at           TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (account_id, id)
);
CREATE INDEX IF NOT EXISTS idx_linear_comments_issue_author ON linear_comments(issue_key, author_id);
CREATE INDEX IF NOT EXISTS idx_linear_comments_created ON linear_comments(created_at);
CREATE INDEX IF NOT EXISTS idx_linear_comments_synced ON linear_comments(synced_at);

CREATE TABLE IF NOT EXISTS linear_issue_history (
    account_id         INTEGER NOT NULL REFERENCES linear_accounts(id) ON DELETE CASCADE,
    id                 TEXT NOT NULL,
    field              TEXT NOT NULL CHECK (field IN ('status','assignee')),
    issue_id           TEXT NOT NULL,
    from_value         TEXT NOT NULL DEFAULT '',
    from_string        TEXT NOT NULL DEFAULT '',
    to_value           TEXT NOT NULL DEFAULT '',
    to_string          TEXT NOT NULL DEFAULT '',
    actor_id           TEXT NOT NULL DEFAULT '',
    actor_display_name TEXT NOT NULL DEFAULT '',
    changed_at         TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (account_id, id, field)
);
CREATE INDEX IF NOT EXISTS idx_linear_history_issue ON linear_issue_history(account_id, issue_id, changed_at);

CREATE TABLE IF NOT EXISTS linear_cycles (
    account_id   INTEGER NOT NULL REFERENCES linear_accounts(id) ON DELETE CASCADE,
    id           TEXT NOT NULL,
    team_id      TEXT NOT NULL DEFAULT '',
    number       INTEGER NOT NULL DEFAULT 0,
    name         TEXT NOT NULL DEFAULT '',
    starts_at    TEXT NOT NULL DEFAULT '',
    ends_at      TEXT NOT NULL DEFAULT '',
    completed_at TEXT NOT NULL DEFAULT '',
    progress     REAL NOT NULL DEFAULT 0,
    synced_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (account_id, id)
);

CREATE TABLE IF NOT EXISTS linear_projects (
    account_id  INTEGER NOT NULL REFERENCES linear_accounts(id) ON DELETE CASCADE,
    id          TEXT NOT NULL,
    name        TEXT NOT NULL DEFAULT '',
    state       TEXT NOT NULL DEFAULT '',
    progress    REAL NOT NULL DEFAULT 0,
    target_date TEXT NOT NULL DEFAULT '',
    lead_id     TEXT NOT NULL DEFAULT '',
    url         TEXT NOT NULL DEFAULT '',
    synced_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (account_id, id)
);

-- issue_id blocks/relates to/duplicates related_issue_id ("A blocks B").
CREATE TABLE IF NOT EXISTS linear_relations (
    account_id       INTEGER NOT NULL REFERENCES linear_accounts(id) ON DELETE CASCADE,
    id               TEXT NOT NULL,
    issue_id         TEXT NOT NULL,
    related_issue_id TEXT NOT NULL,
    type             TEXT NOT NULL,
    PRIMARY KEY (account_id, id)
);
CREATE INDEX IF NOT EXISTS idx_linear_relations_related ON linear_relations(account_id, related_issue_id, type);
CREATE INDEX IF NOT EXISTS idx_linear_relations_issue ON linear_relations(account_id, issue_id);

-- Linear user UUIDs are global, so the map is not account-scoped (the
-- jira_user_map precedent).
CREATE TABLE IF NOT EXISTS linear_user_map (
    linear_user_id   TEXT PRIMARY KEY,
    email            TEXT NOT NULL DEFAULT '',
    display_name     TEXT NOT NULL DEFAULT '',
    slack_user_id    TEXT NOT NULL DEFAULT '',
    match_method     TEXT NOT NULL DEFAULT '',
    match_confidence REAL NOT NULL DEFAULT 0,
    resolved_at      TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS idx_linear_user_map_slack ON linear_user_map(slack_user_id);

-- +goose Down
DROP TABLE IF EXISTS linear_user_map;
DROP TABLE IF EXISTS linear_relations;
DROP TABLE IF EXISTS linear_projects;
DROP TABLE IF EXISTS linear_cycles;
DROP TABLE IF EXISTS linear_issue_history;
DROP TABLE IF EXISTS linear_comments;
DROP TABLE IF EXISTS linear_issues;
DROP TABLE IF EXISTS linear_sync_state;
DROP TABLE IF EXISTS linear_teams;
DROP TABLE IF EXISTS linear_accounts;
```

Copy the Up DDL verbatim into `internal/db/schema.sql`. Add the ten table names to `expectedTables` in `TestAllTablesExist`.

- [ ] **Step 4: Regenerate snapshots and run the tests**

Run: `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update && go test ./internal/db/ -run 'TestMigration00116|TestMigrationIdempotent|TestAllTablesExist|TestSchemaGolden|TestDesktopTestSchema'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/db/migrations/00116_linear_tables.sql internal/db/schema.sql internal/db/db_test.go internal/db/linear_migration_test.go internal/db/testdata WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift
git commit -m "feat(db): linear_* tables (migration 00116)"
```

---

### Task 2: DB layer — accounts, teams, sync state, upserts

**Files:**
- Create: `internal/db/linear_accounts.go`, `internal/db/linear.go`
- Test: `internal/db/linear_accounts_test.go`, `internal/db/linear_test.go`

**Interfaces:**
- Consumes: Task 1 tables.
- Produces (used by Tasks 7–11):

```go
var ErrLinearAccountNotFound = errors.New("linear account not found")

type LinearAccount struct {
	ID int64; OrgID, URLKey, OrgName, Label, Status, Error string; Enabled bool
	OwnerUserID, OwnerEmail, OwnerDisplayName, CreatedAt string
}
func (db *DB) CreateLinearAccount(label string) (int64, error)
func (db *DB) ListLinearAccounts() ([]LinearAccount, error)          // all, by id
func (db *DB) ListEnabledLinearAccounts() ([]LinearAccount, error)   // enabled AND status != 'removed'
func (db *DB) GetLinearAccount(id int64) (LinearAccount, error)      // wraps ErrLinearAccountNotFound
func (db *DB) UpdateLinearAccountConnection(id int64, orgID, urlKey, orgName string) error
func (db *DB) SetLinearAccountOwner(id int64, userID, email, displayName string) error
func (db *DB) SetLinearAccountEnabled(id int64, enabled bool) error
func (db *DB) SetLinearAccountAuthState(id int64, status, errMsg string) error
func (db *DB) SetLinearAccountRemoved(id int64) error                // status='removed', enabled=0

type LinearTeam struct{ AccountID int64; ID, Key, Name string; IsSelected bool }
// UpsertLinearTeams inserts new teams with is_selected = selectNew[team.ID], and
// refreshes key/name of known teams without touching their selection.
func (db *DB) UpsertLinearTeams(accountID int64, teams []LinearTeam, selectNew map[string]bool) error
func (db *DB) ListLinearTeams(accountID int64) ([]LinearTeam, error)
func (db *DB) SetLinearTeamSelected(accountID int64, teamKey string, selected bool) error // error if no such key

type LinearSyncState struct{ AccountID int64; TeamID, Watermark, LastSyncedAt, LastError string }
func (db *DB) GetLinearSyncState(accountID int64, teamID string) (LinearSyncState, error) // zero value when missing
func (db *DB) RecordLinearSyncSuccess(accountID int64, teamID, watermark, syncedAt string) error // clears last_error; empty watermark keeps the stored one
func (db *DB) RecordLinearSyncError(accountID int64, teamID, errMsg string) error              // watermark untouched
func (db *DB) ListLinearSyncStates(accountID int64) ([]LinearSyncState, error)

type LinearIssue struct {
	AccountID int64; ID, Key string; PreviousKeys []string; TeamID, TeamKey, Title, DescriptionText string
	StateName, StateType, StatusCategory, StateChangedAt string
	AssigneeID, AssigneeEmail, AssigneeDisplayName string
	CreatorID, CreatorEmail, CreatorDisplayName string
	Priority int; Estimate *float64; DueDate, CycleID, ProjectID, ParentID string; Labels []string
	URL, CreatedAt, UpdatedAt, CompletedAt, CanceledAt, RawJSON string; IsDeleted bool
}
func (db *DB) UpsertLinearIssue(i LinearIssue) error   // keeps assignee_slack_id/creator_slack_id; synced_at = now
func (db *DB) GetLinearIssueByKey(key string) ([]LinearIssue, error) // matches key or a previous key; all accounts

type LinearComment struct{ AccountID int64; ID, IssueID, IssueKey, AuthorID, AuthorDisplayName, BodyText string; MentionedUserIDs []string; CreatedAt, UpdatedAt string }
func (db *DB) UpsertLinearComment(c LinearComment) error

type LinearHistoryEntry struct{ AccountID int64; ID, Field, IssueID, FromValue, FromString, ToValue, ToString, ActorID, ActorDisplayName, ChangedAt string }
func (db *DB) UpsertLinearHistory(entries []LinearHistoryEntry) error

type LinearRelation struct{ ID, RelatedIssueID, Type string }
// ReplaceLinearRelations replaces every relation whose issue_id = issueID.
func (db *DB) ReplaceLinearRelations(accountID int64, issueID string, rels []LinearRelation) error

type LinearCycle struct{ AccountID int64; ID, TeamID string; Number int; Name, StartsAt, EndsAt, CompletedAt string; Progress float64 }
func (db *DB) UpsertLinearCycles(cycles []LinearCycle) error
type LinearProject struct{ AccountID int64; ID, Name, State string; Progress float64; TargetDate, LeadID, URL string }
func (db *DB) UpsertLinearProjects(projects []LinearProject) error

type LinearUser struct{ ID, Email, DisplayName string }
// UpsertLinearUsers refreshes email/display_name and never touches slack_user_id/match_*.
func (db *DB) UpsertLinearUsers(users []LinearUser) error
// BackfillLinearSlackIDs copies linear_user_map.slack_user_id onto
// linear_issues.assignee_slack_id/creator_slack_id for one account; returns rows changed.
func (db *DB) BackfillLinearSlackIDs(accountID int64) (int64, error)
```

- [ ] **Step 1: Write the failing tests** (`internal/db/linear_accounts_test.go`, `internal/db/linear_test.go`)

```go
package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestLinearAccount_Lifecycle(t *testing.T) {
	d := openTestDB(t)
	id, err := d.CreateLinearAccount("Work")
	require.NoError(t, err)
	require.NoError(t, d.UpdateLinearAccountConnection(id, "org-1", "acme", "Acme"))
	require.NoError(t, d.SetLinearAccountOwner(id, "user-1", "owner@example.com", "Owner"))

	a, err := d.GetLinearAccount(id)
	require.NoError(t, err)
	assert.Equal(t, "acme", a.URLKey)
	assert.Equal(t, "user-1", a.OwnerUserID)
	assert.True(t, a.Enabled)
	assert.Equal(t, "ok", a.Status)

	require.NoError(t, d.SetLinearAccountAuthState(id, "revoked", "invalid_grant"))
	require.NoError(t, d.SetLinearAccountRemoved(id))
	enabled, err := d.ListEnabledLinearAccounts()
	require.NoError(t, err)
	assert.Empty(t, enabled)
	all, err := d.ListLinearAccounts()
	require.NoError(t, err)
	require.Len(t, all, 1) // soft delete: the row stays

	_, err = d.GetLinearAccount(99)
	assert.ErrorIs(t, err, ErrLinearAccountNotFound)
}

func TestLinearTeams_UpsertKeepsSelection(t *testing.T) {
	d := openTestDB(t)
	id, _ := d.CreateLinearAccount("")
	require.NoError(t, d.UpsertLinearTeams(id, []LinearTeam{{ID: "t-1", Key: "ENG", Name: "Eng"}, {ID: "t-2", Key: "OPS", Name: "Ops"}},
		map[string]bool{"t-1": true}))
	require.NoError(t, d.SetLinearTeamSelected(id, "OPS", true))
	require.NoError(t, d.SetLinearTeamSelected(id, "ENG", false))
	// A later pass renames ENG and proposes selecting it again: selection is the user's, not the sync's.
	require.NoError(t, d.UpsertLinearTeams(id, []LinearTeam{{ID: "t-1", Key: "ENG", Name: "Engineering"}}, map[string]bool{"t-1": true}))
	teams, err := d.ListLinearTeams(id)
	require.NoError(t, err)
	require.Len(t, teams, 2)
	assert.Equal(t, "Engineering", teams[0].Name)
	assert.False(t, teams[0].IsSelected)
	assert.True(t, teams[1].IsSelected)
	assert.Error(t, d.SetLinearTeamSelected(id, "NOPE", true))
}

func TestLinearSyncState_ErrorKeepsWatermark(t *testing.T) {
	d := openTestDB(t)
	id, _ := d.CreateLinearAccount("")
	require.NoError(t, d.RecordLinearSyncSuccess(id, "t-1", "2026-10-01T00:00:00.000Z", "2026-10-01T00:05:00Z"))
	require.NoError(t, d.RecordLinearSyncError(id, "t-1", "RATELIMITED"))
	s, err := d.GetLinearSyncState(id, "t-1")
	require.NoError(t, err)
	assert.Equal(t, "2026-10-01T00:00:00.000Z", s.Watermark)
	assert.Equal(t, "RATELIMITED", s.LastError)
	// A clean pass with no new issues keeps the watermark and clears the error.
	require.NoError(t, d.RecordLinearSyncSuccess(id, "t-1", "", "2026-10-01T00:10:00Z"))
	s, _ = d.GetLinearSyncState(id, "t-1")
	assert.Equal(t, "2026-10-01T00:00:00.000Z", s.Watermark)
	assert.Empty(t, s.LastError)
}

func TestLinearIssue_UpsertKeepsSlackIDsAndFindsPreviousKey(t *testing.T) {
	d := openTestDB(t)
	id, _ := d.CreateLinearAccount("")
	require.NoError(t, d.UpsertLinearUsers([]LinearUser{{ID: "u-1", Email: "a@example.com", DisplayName: "A"}}))
	_, err := d.Exec(`UPDATE linear_user_map SET slack_user_id='1:U1' WHERE linear_user_id='u-1'`)
	require.NoError(t, err)
	require.NoError(t, d.UpsertLinearIssue(LinearIssue{AccountID: id, ID: "i-1", Key: "ENG-12", AssigneeID: "u-1", StatusCategory: "todo", Labels: []string{"Bug"}}))
	n, err := d.BackfillLinearSlackIDs(id)
	require.NoError(t, err)
	assert.Equal(t, int64(1), n)
	// Team move: same UUID, new key, old key remembered; the Slack id survives the upsert.
	require.NoError(t, d.UpsertLinearIssue(LinearIssue{AccountID: id, ID: "i-1", Key: "OPS-40", PreviousKeys: []string{"ENG-12"}, AssigneeID: "u-1", StatusCategory: "todo"}))
	got, err := d.GetLinearIssueByKey("ENG-12")
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, "OPS-40", got[0].Key)
	var slack string
	require.NoError(t, d.QueryRow(`SELECT assignee_slack_id FROM linear_issues WHERE id='i-1'`).Scan(&slack))
	assert.Equal(t, "1:U1", slack)
}

func TestLinearUsers_UpsertNeverClearsMapping(t *testing.T) {
	d := openTestDB(t)
	require.NoError(t, d.UpsertLinearUsers([]LinearUser{{ID: "u-1", Email: "a@example.com"}}))
	_, err := d.Exec(`UPDATE linear_user_map SET slack_user_id='1:U1', match_method='email' WHERE linear_user_id='u-1'`)
	require.NoError(t, err)
	require.NoError(t, d.UpsertLinearUsers([]LinearUser{{ID: "u-1", Email: "a2@example.com", DisplayName: "A"}}))
	var slack, email string
	require.NoError(t, d.QueryRow(`SELECT slack_user_id, email FROM linear_user_map WHERE linear_user_id='u-1'`).Scan(&slack, &email))
	assert.Equal(t, "1:U1", slack)
	assert.Equal(t, "a2@example.com", email)
}

func TestLinearRelations_Replace(t *testing.T) {
	d := openTestDB(t)
	id, _ := d.CreateLinearAccount("")
	require.NoError(t, d.ReplaceLinearRelations(id, "i-1", []LinearRelation{{ID: "r-1", RelatedIssueID: "i-2", Type: "blocks"}}))
	require.NoError(t, d.ReplaceLinearRelations(id, "i-1", nil))
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM linear_relations`).Scan(&n))
	assert.Zero(t, n)
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/db/ -run 'TestLinear'`
Expected: FAIL to compile (undefined `CreateLinearAccount`, …).

- [ ] **Step 3: Implement**

`internal/db/linear_accounts.go` follows `internal/db/jira_accounts.go` line for line: one `linearAccountColumns` const, one `scanLinearAccount`, a `RowsAffected() == 0` check in every setter. `UpdateLinearAccountConnection` calls `db.fillAccountLabelBestEffort("linear_accounts", id, orgName)`; read that helper in `internal/db/account_labels.go` first. If it whitelists table names, add `linear_accounts` to the whitelist.

```go
const linearAccountColumns = `id, org_id, url_key, org_name, label, status, error, enabled,
        owner_user_id, owner_email, owner_display_name, created_at`

func scanLinearAccount(s interface{ Scan(dest ...any) error }) (LinearAccount, error) {
	var a LinearAccount
	err := s.Scan(&a.ID, &a.OrgID, &a.URLKey, &a.OrgName, &a.Label, &a.Status, &a.Error, &a.Enabled,
		&a.OwnerUserID, &a.OwnerEmail, &a.OwnerDisplayName, &a.CreatedAt)
	return a, err
}

func (db *DB) GetLinearAccount(id int64) (LinearAccount, error) {
	a, err := scanLinearAccount(db.QueryRow(`SELECT `+linearAccountColumns+` FROM linear_accounts WHERE id = ?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return LinearAccount{}, fmt.Errorf("%w: #%d (see 'watchtower linear accounts')", ErrLinearAccountNotFound, id)
	}
	if err != nil {
		return LinearAccount{}, fmt.Errorf("getting linear account %d: %w", id, err)
	}
	return a, nil
}
```

`internal/db/linear.go`, the non-obvious parts:

```go
func (db *DB) UpsertLinearTeams(accountID int64, teams []LinearTeam, selectNew map[string]bool) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("upserting linear teams: %w", err)
	}
	defer tx.Rollback() //nolint:errcheck
	for _, t := range teams {
		if _, err := tx.Exec(`INSERT INTO linear_teams (account_id, id, key, name, is_selected) VALUES (?,?,?,?,?)
			ON CONFLICT(account_id, id) DO UPDATE SET key = excluded.key, name = excluded.name`,
			accountID, t.ID, t.Key, t.Name, selectNew[t.ID]); err != nil {
			return fmt.Errorf("upserting linear team %s: %w", t.Key, err)
		}
	}
	return tx.Commit()
}

func (db *DB) RecordLinearSyncSuccess(accountID int64, teamID, watermark, syncedAt string) error {
	_, err := db.Exec(`INSERT INTO linear_sync_state (account_id, team_id, watermark, last_synced_at, last_error)
		VALUES (?,?,?,?, '')
		ON CONFLICT(account_id, team_id) DO UPDATE SET
		  watermark = CASE WHEN excluded.watermark != '' THEN excluded.watermark ELSE linear_sync_state.watermark END,
		  last_synced_at = excluded.last_synced_at, last_error = ''`, accountID, teamID, watermark, syncedAt)
	if err != nil {
		return fmt.Errorf("recording linear sync success: %w", err)
	}
	return nil
}

func (db *DB) RecordLinearSyncError(accountID int64, teamID, errMsg string) error {
	_, err := db.Exec(`INSERT INTO linear_sync_state (account_id, team_id, last_error) VALUES (?,?,?)
		ON CONFLICT(account_id, team_id) DO UPDATE SET last_error = excluded.last_error`, accountID, teamID, errMsg)
	if err != nil {
		return fmt.Errorf("recording linear sync error: %w", err)
	}
	return nil
}

// UpsertLinearIssue never writes assignee_slack_id/creator_slack_id: those
// belong to BackfillLinearSlackIDs (the jira BackfillJiraSlackIDs split).
const linearIssueUpsert = `INSERT INTO linear_issues (account_id, id, key, previous_keys, team_id, team_key, title,
  description_text, state_name, state_type, status_category, state_changed_at, assignee_id, assignee_email,
  assignee_display_name, creator_id, creator_email, creator_display_name, priority, estimate, due_date,
  cycle_id, project_id, parent_id, labels, url, created_at, updated_at, completed_at, canceled_at, raw_json,
  synced_at, is_deleted)
VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?, strftime('%Y-%m-%dT%H:%M:%SZ','now'), ?)
ON CONFLICT(account_id, id) DO UPDATE SET key=excluded.key, previous_keys=excluded.previous_keys,
  team_id=excluded.team_id, team_key=excluded.team_key, title=excluded.title,
  description_text=excluded.description_text, state_name=excluded.state_name, state_type=excluded.state_type,
  status_category=excluded.status_category, state_changed_at=excluded.state_changed_at,
  assignee_id=excluded.assignee_id, assignee_email=excluded.assignee_email,
  assignee_display_name=excluded.assignee_display_name,
  assignee_slack_id=CASE WHEN excluded.assignee_id = linear_issues.assignee_id THEN linear_issues.assignee_slack_id ELSE '' END,
  creator_id=excluded.creator_id, creator_email=excluded.creator_email,
  creator_display_name=excluded.creator_display_name, priority=excluded.priority, estimate=excluded.estimate,
  due_date=excluded.due_date, cycle_id=excluded.cycle_id, project_id=excluded.project_id,
  parent_id=excluded.parent_id, labels=excluded.labels, url=excluded.url, created_at=excluded.created_at,
  updated_at=excluded.updated_at, completed_at=excluded.completed_at, canceled_at=excluded.canceled_at,
  raw_json=excluded.raw_json, synced_at=excluded.synced_at, is_deleted=excluded.is_deleted`
```

Notes:
- `previous_keys` and `labels` are marshalled with `json.Marshal`; a nil slice is written as `[]`.
- `GetLinearIssueByKey` uses `WHERE key = ? OR EXISTS (SELECT 1 FROM json_each(previous_keys) WHERE value = ?)`.
- `BackfillLinearSlackIDs`:

```sql
UPDATE linear_issues SET
  assignee_slack_id = COALESCE((SELECT m.slack_user_id FROM linear_user_map m WHERE m.linear_user_id = linear_issues.assignee_id), ''),
  creator_slack_id  = COALESCE((SELECT m.slack_user_id FROM linear_user_map m WHERE m.linear_user_id = linear_issues.creator_id), '')
WHERE account_id = ? AND (
  assignee_slack_id != COALESCE((SELECT m.slack_user_id FROM linear_user_map m WHERE m.linear_user_id = linear_issues.assignee_id), '') OR
  creator_slack_id  != COALESCE((SELECT m.slack_user_id FROM linear_user_map m WHERE m.linear_user_id = linear_issues.creator_id), ''))
```

- `UpsertLinearUsers` uses `ON CONFLICT(linear_user_id) DO UPDATE SET email = excluded.email, display_name = excluded.display_name`.
- The other upserts are plain `INSERT … ON CONFLICT(pk) DO UPDATE SET <every non-key column>`.
- Multi-row writers run in one transaction.

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/db/ -run 'TestLinear'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/db/linear_accounts.go internal/db/linear.go internal/db/linear_accounts_test.go internal/db/linear_test.go internal/db/account_labels.go
git commit -m "feat(db): linear accounts, teams, sync state and upserts"
```

---

### Task 3: Migration 00117 — `tracker_*` views + `ListTrackerIssues`

**Files:**
- Create: `internal/db/migrations/00117_tracker_views.sql`, `internal/db/tracker.go`
- Modify: `internal/db/schema.sql` (views after the Linear block)
- Regenerate: golden + Swift test schema
- Test: `internal/db/tracker_test.go`

**Interfaces:**
- Consumes: Task 1 tables, Task 2 upserts (`UpsertLinearIssue`, …), existing `CreateJiraAccount`/`UpsertJiraIssue` (read `internal/db/jira.go` for `UpsertJiraIssue`'s struct before writing the test).
- Produces (Plan 2 builds on these):

```go
type TrackerIssue struct {
	Tracker string; AccountID int64; IssueID, Key, ProjectKey, Title, DescriptionText string
	Status, StatusCategory, StatusChangedAt string
	AssigneeID, AssigneeEmail, AssigneeDisplayName, AssigneeSlackID string
	ReporterID, ReporterDisplayName, ReporterSlackID string
	Priority string; PriorityRank int; Points *float64; DueDate string
	IterationID, IterationName, ContainerKind, ContainerID, ContainerName, ParentKey string
	Labels string; IsBug, IsBlocked bool; URL, CreatedAt, UpdatedAt, ResolvedAt, SyncedAt string
}
type TrackerIssueFilter struct {
	Tracker string            // "" = both
	AssigneeSlackID string    // "" = any
	OpenOnly bool             // status_category != 'done'
	Limit int                 // 0 = no limit
}
// ListTrackerIssues reads tracker_issues (is_deleted = 0), ordered by
// priority_rank (0 last), then updated_at DESC.
func (db *DB) ListTrackerIssues(f TrackerIssueFilter) ([]TrackerIssue, error)
```

Views: `tracker_issues`, `tracker_comments`, `tracker_history`, `tracker_iterations`, `tracker_people`, `tracker_accounts` with the columns below.

- [ ] **Step 1: Write the failing tests**

```go
package db

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func seedMixedTrackers(t *testing.T, d *DB) {
	t.Helper()
	ja, err := d.CreateJiraAccount(JiraAccount{CloudID: "c", SiteURL: "https://acme.atlassian.net", SiteName: "Acme"})
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO jira_issues (account_id, key, id, project_key, summary, status, status_category,
		assignee_slack_id, priority, created_at, updated_at, synced_at, is_deleted)
		VALUES (?, 'ABC-1', '10001', 'ABC', 'Jira task', 'Blocked', 'in_progress', '1:U1', 'Highest',
		'2026-10-01T00:00:00.000Z', '2026-10-02T00:00:00.000Z', '2026-10-02T00:00:00Z', 0)`, ja)
	require.NoError(t, err)

	la, err := d.CreateLinearAccount("")
	require.NoError(t, err)
	require.NoError(t, d.UpsertLinearCycles([]LinearCycle{{AccountID: la, ID: "c-1", TeamID: "t-1", Number: 7}}))
	require.NoError(t, d.UpsertLinearIssue(LinearIssue{AccountID: la, ID: "i-1", Key: "ENG-1", TeamKey: "ENG",
		Title: "Linear task", StateName: "In Progress", StateType: "started", StatusCategory: "in_progress",
		Priority: 2, CycleID: "c-1", Labels: []string{"bug"}, UpdatedAt: "2026-10-03T00:00:00.000Z"}))
	require.NoError(t, d.UpsertLinearIssue(LinearIssue{AccountID: la, ID: "i-2", Key: "ENG-2", TeamKey: "ENG",
		Title: "Blocker", StateType: "unstarted", StatusCategory: "todo", UpdatedAt: "2026-10-01T00:00:00.000Z"}))
	require.NoError(t, d.ReplaceLinearRelations(la, "i-2", []LinearRelation{{ID: "r-1", RelatedIssueID: "i-1", Type: "blocks"}}))
	_, err = d.Exec(`UPDATE linear_issues SET assignee_slack_id = '1:U1' WHERE id = 'i-1'`)
	require.NoError(t, err)
}

func TestTrackerIssues_MergesBothTrackers(t *testing.T) {
	d := openTestDB(t)
	seedMixedTrackers(t, d)
	got, err := d.ListTrackerIssues(TrackerIssueFilter{AssigneeSlackID: "1:U1", OpenOnly: true})
	require.NoError(t, err)
	require.Len(t, got, 2)
	// priority_rank: Jira Highest = 1 sorts before Linear High = 2.
	assert.Equal(t, "jira", got[0].Tracker)
	assert.Equal(t, 1, got[0].PriorityRank)
	assert.True(t, got[0].IsBlocked) // Jira status-name rule
	assert.Equal(t, "https://acme.atlassian.net/browse/ABC-1", got[0].URL)

	assert.Equal(t, "linear", got[1].Tracker)
	assert.Equal(t, "High", got[1].Priority)
	assert.Equal(t, 2, got[1].PriorityRank)
	assert.Equal(t, "Cycle 7", got[1].IterationName)
	assert.True(t, got[1].IsBug)
	assert.True(t, got[1].IsBlocked) // incoming blocks relation from a not-done issue
}

func TestTrackerIssues_DoneBlockerDoesNotBlock(t *testing.T) {
	d := openTestDB(t)
	seedMixedTrackers(t, d)
	_, err := d.Exec(`UPDATE linear_issues SET status_category = 'done' WHERE id = 'i-2'`)
	require.NoError(t, err)
	got, err := d.ListTrackerIssues(TrackerIssueFilter{Tracker: "linear", AssigneeSlackID: "1:U1"})
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.False(t, got[0].IsBlocked)
}

func TestTrackerViews_AllQueryable(t *testing.T) {
	d := openTestDB(t)
	seedMixedTrackers(t, d)
	for _, v := range []string{"tracker_issues", "tracker_comments", "tracker_history", "tracker_iterations", "tracker_people", "tracker_accounts"} {
		rows, err := d.Query(`SELECT * FROM ` + v + ` LIMIT 1`)
		require.NoError(t, err, v)
		rows.Close()
	}
}

// The owner's-open-issues query must reach an index on both branches of the
// compound view; a plan regression fails here instead of slowing the daemon.
func TestTrackerIssues_OwnerOpenQueryUsesIndexes(t *testing.T) {
	d := openTestDB(t)
	rows, err := d.Query(`EXPLAIN QUERY PLAN SELECT key FROM tracker_issues
		WHERE assignee_slack_id = ? AND status_category != 'done' AND is_deleted = 0`, "1:U1")
	require.NoError(t, err)
	defer rows.Close()
	var plan []string
	for rows.Next() {
		var id, parent, notused int
		var detail string
		require.NoError(t, rows.Scan(&id, &parent, &notused, &detail))
		plan = append(plan, detail)
	}
	joined := strings.Join(plan, "\n")
	assert.Contains(t, joined, "SEARCH ji USING INDEX idx_jira_issues_assignee_status", joined)
	assert.Contains(t, joined, "SEARCH li USING INDEX idx_linear_issues_assignee_status", joined)
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/db/ -run 'TestTracker'`
Expected: FAIL (`no such table: tracker_issues` / undefined `ListTrackerIssues`).

- [ ] **Step 3: Write the migration**

`internal/db/migrations/00117_tracker_views.sql`:

```sql
-- +goose Up
-- Tracker-neutral read layer over Jira and Linear (spec §4.2). Plain
-- projections: every normalization (status_category, state_changed_at) is
-- written by the connectors, so the views stay index-friendly. The branch
-- aliases ji/li are pinned by TestTrackerIssues_OwnerOpenQueryUsesIndexes.
CREATE VIEW IF NOT EXISTS tracker_issues AS
SELECT 'jira' AS tracker, ji.account_id, ji.id AS issue_id, ji.key, ji.project_key,
       ji.summary AS title, ji.description_text, ji.status, ji.status_category,
       ji.status_category_changed_at AS status_changed_at,
       ji.assignee_account_id AS assignee_id, ji.assignee_email, ji.assignee_display_name, ji.assignee_slack_id,
       ji.reporter_account_id AS reporter_id, ji.reporter_display_name, ji.reporter_slack_id,
       ji.priority,
       CASE ji.priority WHEN 'Highest' THEN 1 WHEN 'High' THEN 2 WHEN 'Medium' THEN 3
                        WHEN 'Low' THEN 4 WHEN 'Lowest' THEN 5 ELSE 0 END AS priority_rank,
       ji.story_points AS points, ji.due_date,
       COALESCE(CAST(ji.sprint_id AS TEXT), '') AS iteration_id, ji.sprint_name AS iteration_name,
       CASE WHEN ji.epic_key != '' THEN 'epic' ELSE '' END AS container_kind,
       ji.epic_key AS container_id,
       COALESCE((SELECT e.summary FROM jira_issues e WHERE e.account_id = ji.account_id AND e.key = ji.epic_key), '') AS container_name,
       '' AS parent_key, ji.labels, ji.is_bug,
       CASE WHEN LOWER(ji.status) LIKE '%block%' THEN 1 ELSE 0 END AS is_blocked,
       COALESCE((SELECT a.site_url FROM jira_accounts a WHERE a.id = ji.account_id), '') || '/browse/' || ji.key AS url,
       ji.created_at, ji.updated_at, ji.resolved_at, ji.synced_at, ji.is_deleted
FROM jira_issues ji
UNION ALL
SELECT 'linear', li.account_id, li.id, li.key, li.team_key,
       li.title, li.description_text, li.state_name, li.status_category, li.state_changed_at,
       li.assignee_id, li.assignee_email, li.assignee_display_name, li.assignee_slack_id,
       li.creator_id, li.creator_display_name, li.creator_slack_id,
       CASE li.priority WHEN 1 THEN 'Urgent' WHEN 2 THEN 'High' WHEN 3 THEN 'Medium' WHEN 4 THEN 'Low' ELSE '' END,
       CASE WHEN li.priority BETWEEN 1 AND 4 THEN li.priority ELSE 0 END,
       li.estimate, li.due_date, li.cycle_id,
       COALESCE((SELECT CASE WHEN c.name != '' THEN c.name ELSE 'Cycle ' || c.number END
                 FROM linear_cycles c WHERE c.account_id = li.account_id AND c.id = li.cycle_id), ''),
       CASE WHEN li.project_id != '' THEN 'project' ELSE '' END,
       li.project_id,
       COALESCE((SELECT p.name FROM linear_projects p WHERE p.account_id = li.account_id AND p.id = li.project_id), ''),
       COALESCE((SELECT par.key FROM linear_issues par WHERE par.account_id = li.account_id AND par.id = li.parent_id), ''),
       li.labels,
       EXISTS (SELECT 1 FROM json_each(li.labels) WHERE LOWER(value) = 'bug'),
       EXISTS (SELECT 1 FROM linear_relations r JOIN linear_issues b ON b.account_id = r.account_id AND b.id = r.issue_id
               WHERE r.account_id = li.account_id AND r.related_issue_id = li.id AND r.type = 'blocks'
                 AND b.status_category != 'done' AND b.is_deleted = 0),
       li.url, li.created_at, li.updated_at,
       CASE WHEN li.completed_at != '' THEN li.completed_at ELSE li.canceled_at END,
       li.synced_at, li.is_deleted
FROM linear_issues li;

CREATE VIEW IF NOT EXISTS tracker_comments AS
SELECT 'jira' AS tracker, account_id, id, issue_key, author_account_id AS author_id, author AS author_display_name,
       body_text, NULL AS mentioned_ids, created_at, updated_at, synced_at
FROM jira_comments
UNION ALL
SELECT 'linear', account_id, id, issue_key, author_id, author_display_name,
       body_text, mentioned_user_ids, created_at, updated_at, synced_at
FROM linear_comments;

CREATE VIEW IF NOT EXISTS tracker_history AS
SELECT 'jira' AS tracker, account_id, issue_key, history_id AS id, field, from_value, from_string,
       to_value, to_string, author_account_id AS actor_id, author_display_name AS actor_display_name, changed_at
FROM jira_issue_changelog
UNION ALL
SELECT 'linear', h.account_id, COALESCE((SELECT i.key FROM linear_issues i WHERE i.account_id = h.account_id AND i.id = h.issue_id), ''),
       h.id, h.field, h.from_value, h.from_string, h.to_value, h.to_string, h.actor_id, h.actor_display_name, h.changed_at
FROM linear_issue_history h;

CREATE VIEW IF NOT EXISTS tracker_iterations AS
SELECT 'jira' AS tracker, s.account_id, CAST(s.id AS TEXT) AS id, s.name, s.state, s.start_date AS starts_at,
       s.end_date AS ends_at, s.complete_date AS completed_at,
       COALESCE((SELECT b.project_key FROM jira_boards b WHERE b.account_id = s.account_id AND b.id = s.board_id), '') AS project_key
FROM jira_sprints s
UNION ALL
SELECT 'linear', c.account_id, c.id,
       CASE WHEN c.name != '' THEN c.name ELSE 'Cycle ' || c.number END,
       CASE WHEN c.completed_at != '' OR (c.ends_at != '' AND c.ends_at < strftime('%Y-%m-%dT%H:%M:%fZ','now')) THEN 'closed'
            WHEN c.starts_at != '' AND c.starts_at > strftime('%Y-%m-%dT%H:%M:%fZ','now') THEN 'future'
            ELSE 'active' END,
       c.starts_at, c.ends_at, c.completed_at,
       COALESCE((SELECT t.key FROM linear_teams t WHERE t.account_id = c.account_id AND t.id = c.team_id), '')
FROM linear_cycles c;

CREATE VIEW IF NOT EXISTS tracker_people AS
SELECT 'jira' AS tracker, jira_account_id AS user_id, email, slack_user_id, display_name FROM jira_user_map
UNION ALL
SELECT 'linear', linear_user_id, email, slack_user_id, display_name FROM linear_user_map;

CREATE VIEW IF NOT EXISTS tracker_accounts AS
SELECT 'jira' AS tracker, id, CASE WHEN label != '' THEN label ELSE site_name END AS label, site_url AS url, status, enabled
FROM jira_accounts
UNION ALL
SELECT 'linear', id, CASE WHEN label != '' THEN label ELSE org_name END,
       CASE WHEN url_key != '' THEN 'https://linear.app/' || url_key ELSE '' END, status, enabled
FROM linear_accounts;

-- +goose Down
DROP VIEW IF EXISTS tracker_accounts;
DROP VIEW IF EXISTS tracker_people;
DROP VIEW IF EXISTS tracker_iterations;
DROP VIEW IF EXISTS tracker_history;
DROP VIEW IF EXISTS tracker_comments;
DROP VIEW IF EXISTS tracker_issues;
```

Before running, check the Jira column names used above against `internal/db/schema.sql`:
- `jira_comments.author`, `author_account_id`;
- `jira_issue_changelog.history_id`, `author_*`;
- `jira_sprints.start_date`, `end_date`, `complete_date`, `board_id`;
- `jira_issues.is_bug`.

If a name differs, fix the view, not the Jira table. Then copy the views into `schema.sql`.

`internal/db/tracker.go` is one `SELECT` with the same column order as the `TrackerIssue` fields:
- `WHERE is_deleted = 0`, plus each optional filter appended with `AND … = ?`;
- `ORDER BY CASE WHEN priority_rank = 0 THEN 99 ELSE priority_rank END, updated_at DESC`;
- `LIMIT ?` only when `Limit > 0`;
- `points` is scanned into `sql.NullFloat64`.

- [ ] **Step 4: Regenerate and run the tests**

Run: `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update && go test ./internal/db/ -run 'TestTracker|TestMigrationIdempotent|TestSchemaGolden|TestDesktopTestSchema'`
Expected: PASS. If the index assertion fails, read the printed plan:
- if SQLite picked `idx_*_assignee_slack` instead of the composite index, assert on the index it picked; a `SEARCH` on either index is acceptable;
- a `SCAN ji` or `SCAN li` is not acceptable.

- [ ] **Step 5: Commit**

```bash
git add internal/db/migrations/00117_tracker_views.sql internal/db/schema.sql internal/db/tracker.go internal/db/tracker_test.go internal/db/testdata WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift
git commit -m "feat(db): tracker_* neutral views over Jira and Linear (migration 00117)"
```

---

### Task 4: `internal/linear` — OAuth (PKCE login, exchange, refresh, revoke, token store)

**Files:**
- Create: `internal/linear/oauth.go`, `internal/linear/token_store.go`
- Test: `internal/linear/oauth_test.go`

**Interfaces:**
- Consumes: `auth.NewPKCEPair`, `auth.RandomState`, `auth.NewCallbackHandler`, `auth.PortFromAddr`, `auth.OpenBrowser` (`internal/auth`); `oauthpage.Success/Error/ErrLoginTimedOut`; `fsutil.WriteFileAtomic`, `fsutil.LockFile`.
- Produces:

```go
var DefaultLinearClientID string // -ldflags -X watchtower/internal/linear.DefaultLinearClientID=...
var (
	authorizeEndpoint = "https://linear.app/oauth/authorize"
	tokenEndpoint     = "https://api.linear.app/oauth/token"
	revokeEndpoint    = "https://api.linear.app/oauth/revoke"
)
const Scopes = "read,write,issues:create,comments:create"
var ErrAuthRevoked = errors.New("linear auth revoked")

type OAuthConfig struct{ ClientID string }
type Token struct {
	AccessToken  string `json:"access_token"`
	TokenType    string `json:"token_type"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int    `json:"expires_in"`
	Scope        string `json:"scope"`
	Expiry       string `json:"expiry,omitempty"` // RFC 3339, from ExpiresIn
}
func (t *Token) IsExpired() bool // true within 60 s of Expiry, or when Expiry is empty/unparseable

type TokenStore struct{ /* path */ }
func NewTokenStore(workspaceDir string, accountID int64) *TokenStore // <dir>/linear_token_<id>.json
func (s *TokenStore) Load() (*Token, error)
func (s *TokenStore) Save(t *Token) error            // fsutil.WriteFileAtomic, 0600
func (s *TokenStore) Lock(ctx context.Context) (func(), error) // fsutil.LockFile(path + ".lock")
func (s *TokenStore) Delete() error                  // missing file is not an error
func (s *TokenStore) Exists() bool

type LoginOptions struct{ SkipBrowserOpen, AppReturn bool }
func Login(ctx context.Context, cfg OAuthConfig, out io.Writer, opt LoginOptions) (*Token, error)
func exchangeCode(ctx context.Context, cfg OAuthConfig, code, verifier, redirectURI, endpoint string) (*Token, error)
func refreshToken(ctx context.Context, cfg OAuthConfig, refresh, endpoint string) (*Token, error) // invalid_grant → ErrAuthRevoked
func Revoke(ctx context.Context, accessToken string) error // POST token=<access> to revokeEndpoint; 200 and 400 (already revoked) are success
```

- [ ] **Step 1: Write the failing tests**

```go
package linear

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestAuthorizeURL_PKCEAndScopes(t *testing.T) {
	u, err := url.Parse(authorizeURL(OAuthConfig{ClientID: "cid"}, "http://localhost:18531/callback", "st", "chal"))
	require.NoError(t, err)
	q := u.Query()
	assert.Equal(t, "cid", q.Get("client_id"))
	assert.Equal(t, "code", q.Get("response_type"))
	assert.Equal(t, Scopes, q.Get("scope"))
	assert.Equal(t, "S256", q.Get("code_challenge_method"))
	assert.Equal(t, "chal", q.Get("code_challenge"))
	assert.Equal(t, "user", q.Get("actor"))
	assert.Equal(t, "st", q.Get("state"))
}

func TestExchangeCode_SendsVerifierNoSecret(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.NoError(t, r.ParseForm())
		assert.Equal(t, "authorization_code", r.PostForm.Get("grant_type"))
		assert.Equal(t, "ver", r.PostForm.Get("code_verifier"))
		assert.Empty(t, r.PostForm.Get("client_secret"))
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"access_token":"a1","refresh_token":"r1","expires_in":86399,"token_type":"Bearer"}`))
	}))
	t.Cleanup(srv.Close)
	tok, err := exchangeCode(context.Background(), OAuthConfig{ClientID: "cid"}, "code", "ver", "http://localhost:18531/callback", srv.URL)
	require.NoError(t, err)
	assert.Equal(t, "r1", tok.RefreshToken)
	assert.False(t, tok.IsExpired())
}

func TestRefreshToken_InvalidGrantIsRevoked(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"error":"invalid_grant"}`))
	}))
	t.Cleanup(srv.Close)
	_, err := refreshToken(context.Background(), OAuthConfig{ClientID: "cid"}, "r1", srv.URL)
	assert.ErrorIs(t, err, ErrAuthRevoked)
}

func TestRefreshToken_ServerErrorIsNotRevoked(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	}))
	t.Cleanup(srv.Close)
	_, err := refreshToken(context.Background(), OAuthConfig{ClientID: "cid"}, "r1", srv.URL)
	require.Error(t, err)
	assert.NotErrorIs(t, err, ErrAuthRevoked)
}

func TestTokenStore_RoundTripAndExpiry(t *testing.T) {
	s := NewTokenStore(t.TempDir(), 3)
	assert.True(t, strings.HasSuffix(s.path, "linear_token_3.json"))
	require.NoError(t, s.Save(&Token{AccessToken: "a", RefreshToken: "r", Expiry: time.Now().Add(time.Hour).Format(time.RFC3339)}))
	got, err := s.Load()
	require.NoError(t, err)
	assert.False(t, got.IsExpired())
	assert.True(t, (&Token{}).IsExpired())
	require.NoError(t, s.Delete())
	require.NoError(t, s.Delete()) // idempotent
}

func TestLogin_FullLoopbackFlow(t *testing.T) {
	tokenSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		_, _ = w.Write([]byte(`{"access_token":"a1","refresh_token":"r1","expires_in":86399}`))
	}))
	t.Cleanup(tokenSrv.Close)
	old := tokenEndpoint
	tokenEndpoint = tokenSrv.URL
	t.Cleanup(func() { tokenEndpoint = old })
	setOpenBrowser(t, func(raw string) {
		u, _ := url.Parse(raw)
		cb := u.Query().Get("redirect_uri") + "?code=c1&state=" + u.Query().Get("state")
		go func() { resp, err := http.Get(cb); if err == nil { resp.Body.Close() } }() //nolint:noctx
	})
	tok, err := Login(context.Background(), OAuthConfig{ClientID: "cid"}, &strings.Builder{}, LoginOptions{})
	require.NoError(t, err)
	assert.Equal(t, "a1", tok.AccessToken)
}
```

`setOpenBrowser(t, f)` is a test helper in `oauth_test.go`. It swaps the package's `openBrowserFunc` under its mutex and restores it in `t.Cleanup` (the `internal/jira/auth.go` `openBrowserFunc` precedent).

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/linear/`
Expected: FAIL (package does not exist / undefined symbols).

- [ ] **Step 3: Implement**

`token_store.go` copies `jira.TokenStore` (`internal/jira/auth.go:72-150`) with the file name `linear_token_<id>.json` and the lock error text `locking linear token`.

`oauth.go`:

```go
func authorizeURL(cfg OAuthConfig, redirectURI, state, challenge string) string {
	q := url.Values{
		"client_id":             {cfg.ClientID},
		"redirect_uri":          {redirectURI},
		"response_type":         {"code"},
		"scope":                 {Scopes},
		"state":                 {state},
		"code_challenge":        {challenge},
		"code_challenge_method": {"S256"},
		"actor":                 {"user"},
		"prompt":                {"consent"},
	}
	return authorizeEndpoint + "?" + q.Encode()
}

// redirectPorts must each be registered as http://localhost:<port>/callback on
// the Linear OAuth app: Linear matches redirect URIs exactly, so there is no
// random-port fallback (unlike jira.listenLocal).
var redirectPorts = []int{18531, 18532, 18533, 18534, 18535}

func listenLocal() (net.Listener, error) {
	for _, p := range redirectPorts {
		if ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", p)); err == nil {
			return ln, nil
		}
	}
	return nil, fmt.Errorf("ports %d-%d are busy; close the program holding them and retry", redirectPorts[0], redirectPorts[len(redirectPorts)-1])
}

func postToken(ctx context.Context, endpoint string, form url.Values) (*Token, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("token request: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		if form.Get("grant_type") == "refresh_token" && strings.Contains(string(body), "invalid_grant") {
			return nil, fmt.Errorf("%w: %s", ErrAuthRevoked, strings.TrimSpace(string(body)))
		}
		return nil, fmt.Errorf("token endpoint returned %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	var t Token
	if err := json.Unmarshal(body, &t); err != nil {
		return nil, fmt.Errorf("parsing token: %w", err)
	}
	if t.ExpiresIn > 0 {
		t.Expiry = time.Now().Add(time.Duration(t.ExpiresIn) * time.Second).UTC().Format(time.RFC3339)
	}
	return &t, nil
}

func exchangeCode(ctx context.Context, cfg OAuthConfig, code, verifier, redirectURI, endpoint string) (*Token, error) {
	return postToken(ctx, endpoint, url.Values{
		"grant_type": {"authorization_code"}, "code": {code}, "redirect_uri": {redirectURI},
		"client_id": {cfg.ClientID}, "code_verifier": {verifier},
	})
}

func refreshToken(ctx context.Context, cfg OAuthConfig, refresh, endpoint string) (*Token, error) {
	t, err := postToken(ctx, endpoint, url.Values{
		"grant_type": {"refresh_token"}, "refresh_token": {refresh}, "client_id": {cfg.ClientID},
	})
	if err != nil {
		return nil, err
	}
	if t.RefreshToken == "" { // Linear rotates, but never lose the old one if a response omits it
		t.RefreshToken = refresh
	}
	return t, nil
}
```

`Login` follows the shape of `jira.Login` (`internal/jira/auth.go:382`) with these differences:
- `listenLocal` above;
- a fresh `auth.NewPKCEPair()`;
- `authorizeURL(cfg, redirectURI, state, pkce.Challenge)`;
- `oauthpage.Success("Linear", opt.AppReturn)`;
- `exchangeCode(ctx, cfg, cb.Code, pkce.Verifier, redirectURI, tokenEndpoint)`.

The verifier is never logged.

`Revoke` posts `token=<access>` to `revokeEndpoint` and treats 200 and 400 as done.

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/linear/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/linear/oauth.go internal/linear/token_store.go internal/linear/oauth_test.go
git commit -m "feat(linear): OAuth with PKCE, rotating refresh, token store"
```

---

### Task 5: `internal/linear` — mapping and mention parsing

**Files:**
- Create: `internal/linear/mapping.go`
- Test: `internal/linear/mapping_test.go`

**Interfaces:**
- Produces:

```go
func StatusCategory(stateType string) string   // Global Constraints mapping; unknown → "todo"
func MentionedUserIDs(bodyData string) []string // de-duplicated, in document order; never nil
```

- [ ] **Step 1: Check the mention node shape against the live docs**

Linear comment `bodyData` is a ProseMirror JSON document. Fetch the Linear GraphQL schema reference for `Comment.bodyData` (https://studio.apollographql.com/public/Linear-API/variant/current/schema/reference/objects/Comment) and the developer docs on mentions. Confirm the user-mention node's `type` (expected `suggestion_userMentions`) and its id attribute (expected `attrs.id`). If they differ, use the documented names in Step 2's fixtures and in `MentionedUserIDs`, and add a one-line comment citing the source.

- [ ] **Step 2: Write the failing tests**

```go
package linear

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestStatusCategory(t *testing.T) {
	for in, want := range map[string]string{
		"triage": "todo", "backlog": "todo", "unstarted": "todo",
		"started": "in_progress", "completed": "done", "canceled": "done", "something_new": "todo",
	} {
		assert.Equal(t, want, StatusCategory(in), in)
	}
}

func TestMentionedUserIDs(t *testing.T) {
	doc := `{"type":"doc","content":[{"type":"paragraph","content":[
	  {"type":"text","text":"hi "},
	  {"type":"suggestion_userMentions","attrs":{"id":"user-1","label":"Ann"}},
	  {"type":"text","text":" and "},
	  {"type":"suggestion_userMentions","attrs":{"id":"user-2","label":"Bo"}},
	  {"type":"suggestion_userMentions","attrs":{"id":"user-1","label":"Ann"}}]}]}`
	assert.Equal(t, []string{"user-1", "user-2"}, MentionedUserIDs(doc))
}

func TestMentionedUserIDs_Malformed(t *testing.T) {
	assert.Equal(t, []string{}, MentionedUserIDs(""))
	assert.Equal(t, []string{}, MentionedUserIDs("{not json"))
	assert.Equal(t, []string{}, MentionedUserIDs(`{"type":"doc"}`))
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `go test ./internal/linear/ -run 'TestStatusCategory|TestMentioned'`
Expected: FAIL (undefined).

- [ ] **Step 4: Implement**

```go
package linear

import "encoding/json"

// StatusCategory maps a Linear workflow-state type onto the tracker-neutral
// status_category every Jira consumer already reads.
func StatusCategory(stateType string) string {
	switch stateType {
	case "started":
		return "in_progress"
	case "completed", "canceled":
		return "done"
	default: // triage, backlog, unstarted, and any type Linear adds later
		return "todo"
	}
}

type pmNode struct {
	Type    string          `json:"type"`
	Attrs   map[string]any  `json:"attrs"`
	Content []pmNode        `json:"content"`
}

// mentionNodeType is the ProseMirror node Linear uses for a user mention in
// Comment.bodyData.
const mentionNodeType = "suggestion_userMentions"

// MentionedUserIDs returns the user ids mentioned in a comment's bodyData.
// A missing or malformed document yields no mentions, never an error: a
// comment must still be stored when its rich body cannot be read.
func MentionedUserIDs(bodyData string) []string {
	out := []string{}
	var root pmNode
	if bodyData == "" || json.Unmarshal([]byte(bodyData), &root) != nil {
		return out
	}
	seen := map[string]bool{}
	var walk func(n pmNode)
	walk = func(n pmNode) {
		if n.Type == mentionNodeType {
			if id, ok := n.Attrs["id"].(string); ok && id != "" && !seen[id] {
				seen[id] = true
				out = append(out, id)
			}
		}
		for _, c := range n.Content {
			walk(c)
		}
	}
	walk(root)
	return out
}
```

- [ ] **Step 5: Run the tests and commit**

Run: `go test ./internal/linear/ -run 'TestStatusCategory|TestMentioned'` → PASS.

```bash
git add internal/linear/mapping.go internal/linear/mapping_test.go
git commit -m "feat(linear): state-type mapping and comment mention parsing"
```

---

### Task 6: `internal/linear` — GraphQL client (auth, single-flight refresh, rate limits)

**Files:**
- Create: `internal/linear/client.go`
- Test: `internal/linear/client_test.go`

**Interfaces:**
- Consumes: Task 4 (`TokenStore`, `refreshToken`, `ErrAuthRevoked`, `tokenEndpoint`).
- Produces:

```go
var graphqlEndpoint = "https://api.linear.app/graphql"
var ErrRateLimited = errors.New("linear rate limited")

type Client struct{ /* endpoint, tokenURL, cfg, store, http, mu, logger, gate */ }
func NewClient(cfg OAuthConfig, store *TokenStore) *Client
func (c *Client) SetLogger(l *log.Logger)
// Do runs one GraphQL operation and decodes resp.data into out.
func (c *Client) Do(ctx context.Context, query string, vars map[string]any, out any) error
```

Behaviour:
- **Before each request:** if the last response reported `X-RateLimit-Requests-Remaining < 5` or `X-RateLimit-Complexity-Remaining < 20000`, wait until the matching `*-Reset` time (epoch ms). If that is more than 10 minutes away, return `ErrRateLimited` without waiting.
- **On HTTP 401, or a GraphQL error with `extensions.code == "AUTHENTICATION_ERROR"`:**
  - refresh once (single-flight: under `c.mu` and `store.Lock`, re-load the token first, and refresh only if the stored access token still equals the one the failing request used — the `jira.refreshIfCurrent` rule);
  - then retry;
  - a second auth failure returns `ErrAuthRevoked`.
- **On a GraphQL error with `extensions.code == "RATELIMITED"`** (Linear sends it with HTTP 400): return `fmt.Errorf("%w: …", ErrRateLimited)` with no retry. The syncer turns it into a held watermark.
- **Any other GraphQL error:** return its first message.
- **An expired token at load:** refresh before the request (the `jira.getAccessToken` pattern).

- [ ] **Step 1: Write the failing tests**

```go
package linear

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func newTestClient(t *testing.T, gql http.HandlerFunc, token http.HandlerFunc) (*Client, *TokenStore) {
	t.Helper()
	g := httptest.NewServer(gql)
	t.Cleanup(g.Close)
	store := NewTokenStore(t.TempDir(), 1)
	require.NoError(t, store.Save(&Token{AccessToken: "a0", RefreshToken: "r0", Expiry: time.Now().Add(time.Hour).Format(time.RFC3339)}))
	c := NewClient(OAuthConfig{ClientID: "cid"}, store)
	c.endpoint = g.URL
	if token != nil {
		tk := httptest.NewServer(token)
		t.Cleanup(tk.Close)
		c.tokenURL = tk.URL
	}
	return c, store
}

func TestClient_DecodesData(t *testing.T) {
	c, _ := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "Bearer a0", r.Header.Get("Authorization"))
		_, _ = w.Write([]byte(`{"data":{"viewer":{"id":"user-1"}}}`))
	}, nil)
	var out struct{ Viewer struct{ ID string } }
	require.NoError(t, c.Do(context.Background(), `query { viewer { id } }`, nil, &out))
	assert.Equal(t, "user-1", out.Viewer.ID)
}

func TestClient_401RefreshesAndSavesRotatedPair(t *testing.T) {
	var calls atomic.Int32
	c, store := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if calls.Add(1) == 1 {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		assert.Equal(t, "Bearer a1", r.Header.Get("Authorization"))
		_, _ = w.Write([]byte(`{"data":{}}`))
	}, func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		assert.Equal(t, "r0", r.PostForm.Get("refresh_token"))
		_, _ = w.Write([]byte(`{"access_token":"a1","refresh_token":"r1","expires_in":86399}`))
	})
	require.NoError(t, c.Do(context.Background(), `query { viewer { id } }`, nil, &struct{}{}))
	saved, err := store.Load()
	require.NoError(t, err)
	assert.Equal(t, "r1", saved.RefreshToken) // the rotated refresh token is persisted before use
}

func TestClient_RepeatedAuthFailureIsRevoked(t *testing.T) {
	c, _ := newTestClient(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}, func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"access_token":"a1","refresh_token":"r1","expires_in":86399}`))
	})
	err := c.Do(context.Background(), `query { viewer { id } }`, nil, &struct{}{})
	assert.ErrorIs(t, err, ErrAuthRevoked)
}

func TestClient_RateLimitedIsTyped(t *testing.T) {
	c, _ := newTestClient(t, func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		_ = json.NewEncoder(w).Encode(map[string]any{"errors": []any{map[string]any{
			"message": "rate limited", "extensions": map[string]any{"code": "RATELIMITED"}}}})
	}, nil)
	err := c.Do(context.Background(), `query { viewer { id } }`, nil, &struct{}{})
	assert.ErrorIs(t, err, ErrRateLimited)
}

func TestClient_GateRefusesLongWait(t *testing.T) {
	reset := time.Now().Add(time.Hour).UnixMilli()
	c, _ := newTestClient(t, func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("X-RateLimit-Complexity-Remaining", "10")
		w.Header().Set("X-RateLimit-Complexity-Reset", jsonInt(reset))
		_, _ = w.Write([]byte(`{"data":{}}`))
	}, nil)
	require.NoError(t, c.Do(context.Background(), `query { a }`, nil, &struct{}{}))
	err := c.Do(context.Background(), `query { a }`, nil, &struct{}{})
	assert.ErrorIs(t, err, ErrRateLimited)
}

func TestClient_ConcurrentRefreshSingleFlight(t *testing.T) {
	var refreshes atomic.Int32
	c, _ := newTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") == "Bearer a0" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_, _ = w.Write([]byte(`{"data":{}}`))
	}, func(w http.ResponseWriter, _ *http.Request) {
		refreshes.Add(1)
		_, _ = w.Write([]byte(`{"access_token":"a1","refresh_token":"r1","expires_in":86399}`))
	})
	var wg sync.WaitGroup
	for range 8 {
		wg.Add(1)
		go func() { defer wg.Done(); assert.NoError(t, c.Do(context.Background(), `query { a }`, nil, &struct{}{})) }()
	}
	wg.Wait()
	assert.Equal(t, int32(1), refreshes.Load())
}

func jsonInt(v int64) string { b, _ := json.Marshal(v); return string(b) }
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/linear/ -run TestClient`
Expected: FAIL (undefined `NewClient`).

- [ ] **Step 3: Implement**

The request body is `{"query": q, "variables": vars}`. The response decodes into:

```go
type gqlResponse struct {
	Data   json.RawMessage `json:"data"`
	Errors []struct {
		Message    string `json:"message"`
		Extensions struct {
			Code string `json:"code"`
		} `json:"extensions"`
	} `json:"errors"`
}
```

Classify in this order:
1. HTTP 401, or any error code `AUTHENTICATION_ERROR`: auth failure.
2. Any error code `RATELIMITED`: `ErrRateLimited`.
3. Any other errors: `fmt.Errorf("linear graphql: %s", errs[0].Message)`.
4. A non-200 status with no parsable errors: `fmt.Errorf("linear graphql: HTTP %d", status)`.

Record the four `X-RateLimit-*-Remaining/Reset` headers after every response into a small `gate` struct guarded by its own mutex. `getAccessToken` and `refreshIfCurrent` are `internal/jira/client.go:250-325` adapted to `refreshToken(ctx, c.cfg, tok.RefreshToken, c.tokenEndpoint())`, where `tokenEndpoint()` returns `c.tokenURL` if set, else the package var. The HTTP client timeout is 30 s.

- [ ] **Step 4: Run the tests (with `-race` once)**

Run: `go test -race ./internal/linear/ -run TestClient`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/linear/client.go internal/linear/client_test.go
git commit -m "feat(linear): GraphQL client with single-flight refresh and rate-limit gate"
```

---

### Task 7: `internal/linear` — queries and the Syncer

**Files:**
- Create: `internal/linear/queries.go`, `internal/linear/syncer.go`
- Test: `internal/linear/syncer_test.go`, `internal/linear/fake_test.go`

**Interfaces:**
- Consumes: Task 2 DB API, Task 5 `StatusCategory`/`MentionedUserIDs`, Task 6 `Client.Do`/`ErrAuthRevoked`/`ErrRateLimited`.
- Produces:

```go
type Viewer struct{ UserID, Email, Name, OrgID, OrgName, URLKey string }
func (c *Client) FetchViewer(ctx context.Context) (Viewer, error)

type Syncer struct{ /* client, db, accountID, backfillDays, now, logger */ }
func NewSyncer(client *Client, database *db.DB, accountID int64, backfillDays int) *Syncer
func (s *Syncer) AccountID() int64
func (s *Syncer) SetLogger(l *log.Logger)
// Sync runs one pass over every selected team; returns issues upserted. A team
// error is recorded on that team and the pass continues; ErrAuthRevoked aborts
// the pass at once. Returns the first error seen.
func (s *Syncer) Sync(ctx context.Context) (int, error)
```

The GraphQL operations live in `queries.go` as constants. The fields come from Linear's public schema (spec §3.2). Every connection passes `first`. Pagination uses `pageInfo { hasNextPage endCursor }` + `after`.

```go
const queryViewer = `query { viewer { id name email organization { id name urlKey } teams(first: 100) { nodes { id } } } }`

const queryTeams = `query($after: String) { teams(first: 50, after: $after) { nodes { id key name } pageInfo { hasNextPage endCursor } } }`

const queryUsers = `query($after: String) { users(first: 100, after: $after, includeDisabled: true) { nodes { id name displayName email } pageInfo { hasNextPage endCursor } } }`

// Issues changed since $since in one team, archived ones included (they become
// is_deleted). On a first pass the filter also takes every open issue.
const queryIssues = `query($filter: IssueFilter!, $after: String) {
  issues(filter: $filter, first: 25, after: $after, includeArchived: true, orderBy: updatedAt) {
    nodes {
      id identifier previousIdentifiers title description url priority estimate dueDate
      createdAt updatedAt completedAt canceledAt archivedAt trashed startedAt
      team { id key } state { name type } assignee { id name email } creator { id name email }
      cycle { id } project { id } parent { id }
      labels(first: 20) { nodes { name } }
      relations(first: 20) { nodes { id type relatedIssue { id } } }
      history(first: 50) { nodes { id createdAt actor { id name }
        fromState { id name } toState { id name } fromAssignee { id name } toAssignee { id name } } }
    }
    pageInfo { hasNextPage endCursor }
  } }`

const queryComments = `query($filter: CommentFilter!, $after: String) {
  comments(filter: $filter, first: 50, after: $after) {
    nodes { id body bodyData createdAt updatedAt user { id name } issue { id identifier } }
    pageInfo { hasNextPage endCursor } } }`

const queryTeamPlanning = `query($team: String!) { team(id: $team) {
  cycles(first: 50, orderBy: updatedAt) { nodes { id number name startsAt endsAt completedAt progress } }
  projects(first: 50, orderBy: updatedAt) { nodes { id name state progress targetDate url lead { id } } } } }`
```

Filters built in Go:
- Issues: `{"team": {"id": {"eq": teamID}}, "updatedAt": {"gte": since}}`.
- Issues on a first pass (empty watermark): `{"team": …, "or": [{"updatedAt": {"gte": since}}, {"state": {"type": {"nin": ["completed","canceled"]}}}]}`.
- Comments: `{"issue": {"team": {"id": {"eq": teamID}}}, "updatedAt": {"gte": since}}`.

`since` is the stored watermark, or `now - backfillDays` on a first pass.

Mapping one issue node to `db.LinearIssue`:
- `IsDeleted = archivedAt != nil || trashed`.
- `StatusCategory = StatusCategory(state.type)`.
- `StateChangedAt` = `changedAt` of the newest history entry with a `toState`, else `startedAt` when `state.type == "started"`, else `''`.
- `PreviousKeys = previousIdentifiers`.
- `DescriptionText = description`; `RawJSON` = the node's raw JSON.

History nodes become entries:
- `field="status"` when `toState != nil`;
- `field="assignee"` when `fromAssignee` or `toAssignee` is set;
- one node can yield both.

Relations replace the issue's stored ones (`ReplaceLinearRelations`), keeping only `type` in `blocks`, `related`, `duplicate`.

Team selection on each pass:
- `UpsertLinearTeams(account, allTeams, selectNew)`, where `selectNew[t] = true` for teams in `viewer.teams`;
- `ListLinearTeams` then gives the selected ones.

Per selected team, in order: issues (all pages), comments (all pages), planning. On success: `RecordLinearSyncSuccess(account, team, maxUpdatedAt, now)`, where `maxUpdatedAt` is the largest `updatedAt` seen across issues and comments (`''` if none). On error: `RecordLinearSyncError` and move to the next team. `ErrAuthRevoked` returns at once. After the teams: `UpsertLinearUsers` (all pages) and `BackfillLinearSlackIDs(account)`.

- [ ] **Step 1: Write the fake server and the failing tests**

`fake_test.go` is a `fakeLinear` `httptest` handler that:
- decodes `{"query","variables"}` and dispatches on a substring of the query (`viewer {`, `teams(`, `users(`, `issues(`, `comments(`, `team(id:`);
- serves canned pages from fields the test sets, `issuePages [][]map[string]any` among them;
- records every request's variables;
- can be told to return a GraphQL error on a given call number.

`syncer_test.go`:

```go
func TestSyncer_FirstPassStoresIssuesCommentsAndHistory(t *testing.T) {
	f := newFakeLinear(t)
	f.viewerTeams = []string{"t-1"}
	f.teams = []map[string]any{{"id": "t-1", "key": "ENG", "name": "Eng"}, {"id": "t-2", "key": "OPS", "name": "Ops"}}
	f.issuePages = [][]map[string]any{{issueNode("i-1", "ENG-1", "started", "2026-10-02T00:00:00.000Z")}}
	f.commentPages = [][]map[string]any{{commentNode("c-1", "i-1", "ENG-1", `{"type":"doc","content":[{"type":"suggestion_userMentions","attrs":{"id":"user-9"}}]}`, "2026-10-03T00:00:00.000Z")}}
	d, s := newTestSyncer(t, f)

	n, err := s.Sync(context.Background())
	require.NoError(t, err)
	assert.Equal(t, 1, n)

	issues, _ := d.GetLinearIssueByKey("ENG-1")
	require.Len(t, issues, 1)
	assert.Equal(t, "in_progress", issues[0].StatusCategory)
	var mentions string
	require.NoError(t, d.QueryRow(`SELECT mentioned_user_ids FROM linear_comments WHERE id='c-1'`).Scan(&mentions))
	assert.Equal(t, `["user-9"]`, mentions)
	var hist int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM linear_issue_history WHERE field='status'`).Scan(&hist))
	assert.Equal(t, 1, hist)
	// Only the viewer's team was selected and synced; the watermark is the newest updatedAt seen.
	st, _ := d.GetLinearSyncState(s.AccountID(), "t-1")
	assert.Equal(t, "2026-10-03T00:00:00.000Z", st.Watermark)
	assert.Empty(t, f.issueFiltersForTeam("t-2"))
	// First pass asked for open issues too.
	assert.Contains(t, f.lastIssueFilterJSON("t-1"), `"nin":["completed","canceled"]`)
}

func TestSyncer_SecondPassUsesWatermark(t *testing.T) {
	f := newFakeLinear(t)
	f.viewerTeams = []string{"t-1"}
	f.teams = []map[string]any{{"id": "t-1", "key": "ENG", "name": "Eng"}}
	f.issuePages = [][]map[string]any{{issueNode("i-1", "ENG-1", "started", "2026-10-02T00:00:00.000Z")}}
	_, s := newTestSyncer(t, f)
	_, err := s.Sync(context.Background())
	require.NoError(t, err)
	_, err = s.Sync(context.Background())
	require.NoError(t, err)
	got := f.lastIssueFilterJSON("t-1")
	assert.Contains(t, got, `"gte":"2026-10-02T00:00:00.000Z"`)
	assert.NotContains(t, got, `"nin"`)
}

func TestSyncer_PageErrorHoldsWatermark(t *testing.T) {
	f := newFakeLinear(t)
	f.viewerTeams = []string{"t-1"}
	f.teams = []map[string]any{{"id": "t-1", "key": "ENG", "name": "Eng"}}
	f.issuePages = [][]map[string]any{
		{issueNode("i-1", "ENG-1", "started", "2026-10-02T00:00:00.000Z")},
		{issueNode("i-2", "ENG-2", "started", "2026-10-04T00:00:00.000Z")},
	}
	f.failIssuePage = 2 // RATELIMITED on the second page
	d, s := newTestSyncer(t, f)
	require.NoError(t, d.RecordLinearSyncSuccess(s.AccountID(), "t-1", "2026-09-01T00:00:00.000Z", "x"))
	_, err := s.Sync(context.Background())
	require.ErrorIs(t, err, ErrRateLimited)
	st, _ := d.GetLinearSyncState(s.AccountID(), "t-1")
	assert.Equal(t, "2026-09-01T00:00:00.000Z", st.Watermark)
	assert.Contains(t, st.LastError, "rate limited")
	got, _ := d.GetLinearIssueByKey("ENG-1") // page 1 is kept: upserts are idempotent
	assert.Len(t, got, 1)
}

func TestSyncer_TeamMoveKeepsOneRow(t *testing.T) {
	f := newFakeLinear(t)
	f.viewerTeams = []string{"t-1"}
	f.teams = []map[string]any{{"id": "t-1", "key": "ENG", "name": "Eng"}}
	f.issuePages = [][]map[string]any{{issueNode("i-1", "ENG-12", "unstarted", "2026-10-02T00:00:00.000Z")}}
	d, s := newTestSyncer(t, f)
	_, err := s.Sync(context.Background())
	require.NoError(t, err)
	moved := issueNode("i-1", "OPS-40", "unstarted", "2026-10-05T00:00:00.000Z")
	moved["previousIdentifiers"] = []string{"ENG-12"}
	f.issuePages = [][]map[string]any{{moved}}
	_, err = s.Sync(context.Background())
	require.NoError(t, err)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM linear_issues WHERE id='i-1'`).Scan(&n))
	assert.Equal(t, 1, n)
	got, _ := d.GetLinearIssueByKey("ENG-12")
	require.Len(t, got, 1)
	assert.Equal(t, "OPS-40", got[0].Key)
}

func TestSyncer_ArchivedIssueIsDeleted(t *testing.T) {
	f := newFakeLinear(t)
	f.viewerTeams = []string{"t-1"}
	f.teams = []map[string]any{{"id": "t-1", "key": "ENG", "name": "Eng"}}
	node := issueNode("i-1", "ENG-1", "completed", "2026-10-02T00:00:00.000Z")
	node["archivedAt"] = "2026-10-02T00:00:00.000Z"
	f.issuePages = [][]map[string]any{{node}}
	d, s := newTestSyncer(t, f)
	_, err := s.Sync(context.Background())
	require.NoError(t, err)
	var del int
	require.NoError(t, d.QueryRow(`SELECT is_deleted FROM linear_issues WHERE id='i-1'`).Scan(&del))
	assert.Equal(t, 1, del)
}

func TestSyncer_AuthRevokedAbortsPass(t *testing.T) {
	f := newFakeLinear(t)
	f.viewerTeams = []string{"t-1", "t-2"}
	f.teams = []map[string]any{{"id": "t-1", "key": "ENG"}, {"id": "t-2", "key": "OPS"}}
	f.alwaysUnauthorized = true
	_, s := newTestSyncer(t, f)
	_, err := s.Sync(context.Background())
	assert.ErrorIs(t, err, ErrAuthRevoked)
}
```

`issueNode(id, key, stateType, updatedAt)` returns a minimal node:
- `team {id:"t-1", key: prefix of key}`, `state {name, type}`, `assignee: nil`;
- `history.nodes` with one `toState` entry at `updatedAt`;
- empty `labels` / `relations`.

`commentNode` builds a comment node the same way. `newTestSyncer(t, f)` does the following:
- opens a test DB with `db.Open(":memory:")`, closed in `t.Cleanup`;
- creates a Linear account;
- saves a non-expired token;
- makes a `Client` pointed at `f.URL`, whose token URL refuses with `invalid_grant` when `alwaysUnauthorized` is set;
- uses a fixed `now` of `2026-10-10T00:00:00Z`.

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/linear/ -run TestSyncer`
Expected: FAIL (undefined `NewSyncer`).

- [ ] **Step 3: Implement `queries.go` and `syncer.go`** per the Interfaces and mapping rules above. Keep node structs next to their queries. Paginate with one generic helper:

```go
// paginate calls fetch with each page's cursor until hasNextPage is false.
func paginate(ctx context.Context, fetch func(ctx context.Context, after *string) (pageInfo, error)) error {
	var after *string
	for {
		pi, err := fetch(ctx, after)
		if err != nil {
			return err
		}
		if !pi.HasNextPage {
			return nil
		}
		cur := pi.EndCursor
		after = &cur
	}
}
```

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/linear/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/linear/queries.go internal/linear/syncer.go internal/linear/syncer_test.go internal/linear/fake_test.go
git commit -m "feat(linear): incremental team sync of issues, comments, history and planning"
```

---

### Task 8: Linear → Slack user resolution by email

**Files:**
- Create: `internal/db/linear_users.go`
- Test: `internal/db/linear_users_test.go`

**Interfaces:**
- Consumes: Task 2 `linear_user_map`, the Slack `users` table.
- Produces:

```go
// ResolveLinearUsersByEmail maps every unmapped linear_user_map row whose
// email equals (case-insensitively) a non-deleted, non-bot Slack user's email,
// preferring Slack account 1 ("1:" prefix), then the lowest id. Rows mapped by
// hand (match_method = 'manual') are never touched. Returns rows mapped.
func (db *DB) ResolveLinearUsersByEmail(now string) (int64, error)
```

- [ ] **Step 1: Write the failing test**

```go
func TestResolveLinearUsersByEmail(t *testing.T) {
	d := openTestDB(t)
	_, err := d.Exec(`INSERT INTO users (id, name, email) VALUES ('1:U1','ann','Ann@Example.com'), ('2:U9','ann2','ann@example.com'), ('1:U2','bot','bot@example.com')`)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE users SET is_bot = 1 WHERE id = '1:U2'`)
	require.NoError(t, err)
	require.NoError(t, d.UpsertLinearUsers([]LinearUser{{ID: "u-1", Email: "ann@example.com"}, {ID: "u-2", Email: "bot@example.com"}, {ID: "u-3", Email: "x@example.com"}}))
	_, err = d.Exec(`INSERT INTO linear_user_map (linear_user_id, email, slack_user_id, match_method) VALUES ('u-4','ann@example.com','1:U7','manual')`)
	require.NoError(t, err)

	n, err := d.ResolveLinearUsersByEmail("2026-10-10T00:00:00Z")
	require.NoError(t, err)
	assert.Equal(t, int64(1), n)
	var slack, method string
	require.NoError(t, d.QueryRow(`SELECT slack_user_id, match_method FROM linear_user_map WHERE linear_user_id='u-1'`).Scan(&slack, &method))
	assert.Equal(t, "1:U1", slack)
	assert.Equal(t, "email", method)
	require.NoError(t, d.QueryRow(`SELECT slack_user_id FROM linear_user_map WHERE linear_user_id='u-4'`).Scan(&slack))
	assert.Equal(t, "1:U7", slack) // manual mapping kept
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `go test ./internal/db/ -run TestResolveLinearUsersByEmail` → FAIL (undefined).

- [ ] **Step 3: Implement**

```sql
UPDATE linear_user_map SET
  slack_user_id = (SELECT u.id FROM users u
                   WHERE LOWER(u.email) = LOWER(linear_user_map.email) AND u.email != ''
                     AND u.is_deleted = 0 AND COALESCE(u.is_bot_override, u.is_bot) = 0
                   ORDER BY (u.id LIKE '1:%') DESC, u.id LIMIT 1),
  match_method = 'email', match_confidence = 1.0, resolved_at = ?
WHERE slack_user_id = '' AND match_method != 'manual' AND email != ''
  AND EXISTS (SELECT 1 FROM users u WHERE LOWER(u.email) = LOWER(linear_user_map.email) AND u.email != ''
              AND u.is_deleted = 0 AND COALESCE(u.is_bot_override, u.is_bot) = 0)
```

Return `RowsAffected()`. The Syncer (Task 7) calls `ResolveLinearUsersByEmail` right before `BackfillLinearSlackIDs`. Add that call in `syncer.go` and extend `TestSyncer_FirstPassStoresIssuesCommentsAndHistory`: seed a Slack user `1:U1` with `user-1`'s email, give the issue `assignee {id: "user-1"}`, and assert the stored `assignee_slack_id = '1:U1'`.

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/db/ -run TestResolveLinearUsersByEmail && go test ./internal/linear/` → PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/db/linear_users.go internal/db/linear_users_test.go internal/linear/syncer.go internal/linear/syncer_test.go
git commit -m "feat(linear): map Linear users to Slack users by email"
```

---

### Task 9: Config and daemon phase `phaseLinearSync`

**Files:**
- Modify: `internal/config/config.go` (new `LinearConfig`, defaults)
- Modify: `internal/daemon/daemon.go` (syncer interface, setter, phase, call next to `phaseJiraSync`)
- Modify: `cmd/sync.go` (`wireLinearSyncers`, called where `wireJiraSyncers` is called)
- Test: `internal/daemon/linear_sync_test.go`, `internal/config/config_test.go` (defaults)

**Interfaces:**
- Consumes: Task 7 `Syncer`, Task 2 `SetLinearAccountAuthState`, `ListEnabledLinearAccounts`.
- Produces:

```go
// config
type LinearConfig struct {
	Enabled          bool `mapstructure:"enabled"`
	SyncIntervalMins int  `mapstructure:"sync_interval_mins"`
	BackfillDays     int  `mapstructure:"backfill_days"`
}
const (
	DefaultLinearEnabled          = false
	DefaultLinearSyncIntervalMins = 15
	DefaultLinearBackfillDays     = 90
)
// Config gains: Linear LinearConfig `mapstructure:"linear"`

// daemon
type linearAccountSyncer interface {
	Sync(ctx context.Context) (int, error)
	AccountID() int64
}
func (d *Daemon) SetLinearSyncers(s []*linear.Syncer)
func (d *Daemon) phaseLinearSync(ctx context.Context)
```

`phaseLinearSync` mirrors `phaseJiraSync` (`internal/daemon/daemon.go:779-875`) minus the board analyzer and target reflection:
- interval gate on `d.lastLinear`;
- per-account `Sync`;
- `ctx.Err() != nil` → leave the state alone;
- `errors.Is(err, linear.ErrAuthRevoked)` → `SetLinearAccountAuthState(id, "revoked", err.Error())`;
- every other error is logged only;
- one account's failure never stops the others.

Copy the doc comment's reasoning, in one paragraph.

- [ ] **Step 1: Write the failing tests**

```go
package daemon

type fakeLinearSyncer struct {
	id  int64
	err error
	n   int
	ran *int
}

func (f fakeLinearSyncer) Sync(context.Context) (int, error) { *f.ran++; return f.n, f.err }
func (f fakeLinearSyncer) AccountID() int64                  { return f.id }

func TestPhaseLinearSync_RevokedMarksAccount(t *testing.T) {
	d, database := newTestDaemonWithDB(t) // use the helper the jira phase tests use; grep internal/daemon/*_test.go for phaseJiraSync
	a1, _ := database.CreateLinearAccount("")
	a2, _ := database.CreateLinearAccount("")
	ran := 0
	d.linearSyncers = []linearAccountSyncer{
		fakeLinearSyncer{id: a1, err: fmt.Errorf("refresh: %w", linear.ErrAuthRevoked), ran: &ran},
		fakeLinearSyncer{id: a2, n: 3, ran: &ran},
	}
	d.phaseLinearSync(context.Background())
	assert.Equal(t, 2, ran) // the second account still synced
	acc, _ := database.GetLinearAccount(a1)
	assert.Equal(t, "revoked", acc.Status)
	acc2, _ := database.GetLinearAccount(a2)
	assert.Equal(t, "ok", acc2.Status)
}

func TestPhaseLinearSync_OtherErrorLeavesState(t *testing.T) {
	d, database := newTestDaemonWithDB(t)
	a1, _ := database.CreateLinearAccount("")
	ran := 0
	d.linearSyncers = []linearAccountSyncer{fakeLinearSyncer{id: a1, err: linear.ErrRateLimited, ran: &ran}}
	d.phaseLinearSync(context.Background())
	acc, _ := database.GetLinearAccount(a1)
	assert.Equal(t, "ok", acc.Status)
}

func TestPhaseLinearSync_IntervalGate(t *testing.T) {
	d, database := newTestDaemonWithDB(t)
	a1, _ := database.CreateLinearAccount("")
	ran := 0
	d.linearSyncers = []linearAccountSyncer{fakeLinearSyncer{id: a1, ran: &ran}}
	d.phaseLinearSync(context.Background())
	d.phaseLinearSync(context.Background())
	assert.Equal(t, 1, ran)
}
```

Before writing, find how the existing `phaseJiraSync` tests build a daemon with a DB (`grep -n "phaseJiraSync" internal/daemon/*_test.go`) and use that helper. If there isn't one, construct it the way those tests do.

In `internal/config/config_test.go`, assert that `config.Load` on an empty file yields `Linear.SyncIntervalMins == 15`, `BackfillDays == 90`, `Enabled == false`.

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/daemon/ -run TestPhaseLinearSync && go test ./internal/config/ -run Linear` → FAIL.

- [ ] **Step 3: Implement**

- **Config:** add the struct, add the field next to `Jira` in `Config`, and in the defaults block: `v.SetDefault("linear.enabled", DefaultLinearEnabled)`, `v.SetDefault("linear.sync_interval_mins", DefaultLinearSyncIntervalMins)`, `v.SetDefault("linear.backfill_days", DefaultLinearBackfillDays)`.
- **Daemon:**
  - fields `linearSyncers []linearAccountSyncer` and `lastLinear time.Time`;
  - `SetLinearSyncers`;
  - call `d.phaseLinearSync(ctx)` right after `d.phaseJiraSync(ctx)` (`internal/daemon/daemon.go:453`).
- **`cmd/sync.go`:**

```go
// wireLinearSyncers builds one Linear syncer per enabled account with a token
// file. An account without one is flagged "error" (only from "ok", so a
// revoked account does not churn) — the buildAtlassianClients rule.
func wireLinearSyncers(d *daemon.Daemon, cfg *config.Config, database *db.DB, logger *log.Logger) {
	if !cfg.Linear.Enabled {
		return
	}
	accounts, err := database.ListEnabledLinearAccounts()
	if err != nil {
		logger.Printf("linear: failed to list accounts: %v", err)
		return
	}
	oauthCfg := resolveLinearOAuthConfig()
	var syncers []*linear.Syncer
	for _, acct := range accounts {
		store := linear.NewTokenStore(cfg.WorkspaceDir(), acct.ID)
		if !store.Exists() {
			if acct.Status == "ok" {
				if err := database.SetLinearAccountAuthState(acct.ID, "error", "no token — re-login required"); err != nil {
					logger.Printf("linear: account %d: record auth state: %v", acct.ID, err)
				}
			}
			continue
		}
		client := linear.NewClient(oauthCfg, store)
		client.SetLogger(subLogger(logger, "[linear] "))
		s := linear.NewSyncer(client, database, acct.ID, cfg.Linear.BackfillDays)
		s.SetLogger(subLogger(logger, "[linear] "))
		syncers = append(syncers, s)
	}
	d.SetLinearSyncers(syncers)
}
```

`resolveLinearOAuthConfig` is defined in Task 11's `cmd/linear.go`. If Task 9 lands first, define it here in `cmd/sync.go` and let Task 11 use it:

```go
func resolveLinearOAuthConfig() linear.OAuthConfig {
	id := os.Getenv("WATCHTOWER_LINEAR_CLIENT_ID")
	if id == "" {
		id = linear.DefaultLinearClientID
	}
	return linear.OAuthConfig{ClientID: id}
}
```

Call `wireLinearSyncers(d, cfg, database, logger)` at each call site of `wireJiraSyncers` (`grep -n "wireJiraSyncers(" cmd/*.go`).

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/daemon/ -run TestPhaseLinearSync && go test ./internal/config/ && go build ./...` → PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/config/config.go internal/config/config_test.go internal/daemon/daemon.go internal/daemon/linear_sync_test.go cmd/sync.go
git commit -m "feat(daemon): phaseLinearSync with per-account isolation and revoked state"
```

---

### Task 10: OWNER-01 — Linear rung (Go + Swift twin + inventory)

**Files:**
- Modify: `internal/db/owner.go`, `internal/db/owner_test.go`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/OwnerQueries.swift`, the Swift `Owner`/`OwnerSource` model (find with `grep -rn "enum OwnerSource" WatchtowerDesktop/Sources`), `WatchtowerDesktop/Tests/Core/OwnerQueriesTests.swift`
- Modify: `docs/inventory/owner-identity.md` (OWNER-01 text and guards), `docs/inventory/README.md` changelog line if that file keeps one

**Interfaces:**
- Produces:

```go
const OwnerSourceLinear OwnerSource = "linear"
// Owner gains:
//   LinearUserIDs []string // owner_user_id of every enabled, non-removed linear account, by id; nil when none
```

- **Ladder:** Slack #1 → Google #1 → Jira #1 → **Linear #1** (the first enabled, non-removed `linear_accounts` row by id with a non-empty `owner_user_id`; `ID = "linear:" + owner_user_id`).
- **Enrichment:** `Email` falls back to the Linear owner email after Jira; `DisplayName` falls back to the Linear owner display name after Jira; `LinearUserIDs` is filled whichever rung won.
- **Swift:** `Owner` gains `linearUserIDs: [String]`, and `OwnerSource` gains `.linear`.

This change was approved by the owner in ask #162. Per CLAUDE.md, the code, the guard tests and the inventory entry land in **one commit**. The existing OWNER-01 fixture cases must keep passing unmodified: extend the tables, never edit an existing row.

- [ ] **Step 1: Extend the Go guard test**

In `TestOwner01_ResolveOwnerLadder`, add rows to the existing fixture table (keep its struct shape; add a `linear` seed field if the table seeds per-source, following how its `jira` seeds work):
- **Linear-only:** `ID = "linear:user-1"`, `Source = "linear"`, `Email = "owner@example.com"`, `DisplayName = "Owner"`, `LinearUserIDs = ["user-1"]`.
- **Jira + Linear:** the Jira rung wins `ID`, and `LinearUserIDs` is still filled.
- **Removed or disabled Linear account:** it is skipped.

In `TestOwner01_SlackInstallIDUnchanged`, connect a Linear account as well and assert that `ID` is unchanged and `LinearUserIDs == ["user-1"]`.

- [ ] **Step 2: Run to see it fail**

Run: `go test ./internal/db/ -run TestOwner01` → FAIL.

- [ ] **Step 3: Implement Go**

```go
type ownerLinear struct{ UserID, Email, DisplayName string }

// ownerLinearAccount is the Linear rung: the first enabled, non-removed Linear
// account that recorded its connecting person's identity (viewer at connect).
func (db *DB) ownerLinearAccount() (ownerLinear, error) {
	var l ownerLinear
	err := db.QueryRow(`SELECT owner_user_id, owner_email, owner_display_name FROM linear_accounts
		WHERE enabled = 1 AND status != 'removed' AND owner_user_id != '' ORDER BY id LIMIT 1`).
		Scan(&l.UserID, &l.Email, &l.DisplayName)
	if errors.Is(err, sql.ErrNoRows) {
		return ownerLinear{}, nil
	}
	if err != nil {
		return ownerLinear{}, fmt.Errorf("resolving owner linear account: %w", err)
	}
	return l, nil
}

// ownerLinearUserIDs lists the owner's Linear user id on every enabled,
// non-removed account (one per workspace), by account id.
func (db *DB) ownerLinearUserIDs() ([]string, error) { /* SELECT owner_user_id ... ORDER BY id; nil when none */ }
```

In `ResolveOwner`, add `case linear.UserID != "": o.ID, o.Source = "linear:"+linear.UserID, OwnerSourceLinear` after the Jira case. Pass `linear` to `enrichOwner`, `ownerEmail` and `ownerDisplayName` as the last fallback in each. Fill `o.LinearUserIDs` in `enrichOwner`. Update `ErrNoOwner`'s text to `"connect Slack, Google, Jira or Linear first"`. Grep the tests for the old text (`grep -rn "Google or Jira first" internal cmd`) and update any exact-string assertion as part of this commit; it is the same contract, reworded.

- [ ] **Step 4: Swift twin**

In `OwnerQueries.swift`:
- add `private struct OwnerLinear { var userID = ""; var email = ""; var displayName = "" }` and `ownerLinearAccount(_:)` with the same SQL;
- add the rung after Jira: `"linear:" + linear.userID`, `.linear`;
- add the fallbacks in `ownerEmail` and `ownerDisplayName`;
- add `ownerLinearUserIDs(_:)` and fill `linearUserIDs` in `enrich`;
- update the doc comment's ladder line to `Slack #1 → Google #1 → Jira #1 → Linear #1`.

Add the same three fixture rows to `testOwner01ResolveOwnerLadder` and the Linear connection to `testOwner01SlackInstallIDUnchanged`.

Run: `make test-swift FILTER=OwnerQueriesTests && make lint-swift` → PASS.

- [ ] **Step 5: Inventory**

In `docs/inventory/owner-identity.md` OWNER-01:
- **Observable:** the ladder becomes `Slack #1 → Google #1 → Jira #1 → Linear #1`.
- **Mechanism:** add the Linear rung sentence (`ID = "linear:" + owner_user_id`, `Source = "linear"`, first enabled non-removed `linear_accounts` row by id) and `LinearUserIDs` to the enrichment list.
- **Test guards:** name the new fixture rows.
- Add a dated line under the entry: `Amended 2026-10-15: Linear rung (ask #162).`

- [ ] **Step 6: Run and commit together**

Run: `go test ./internal/db/ ./internal/inbox/ ./internal/daemon/ -run 'Owner'` → PASS.

```bash
git add internal/db/owner.go internal/db/owner_test.go WatchtowerDesktop/Sources WatchtowerDesktop/Tests/Core/OwnerQueriesTests.swift docs/inventory/owner-identity.md
git commit -m "feat(owner): Linear rung in ResolveOwner and its Swift twin (OWNER-01 amended, ask #162)"
```

---

### Task 11: CLI `watchtower linear …` and build flags

**Files:**
- Create: `cmd/linear.go`
- Modify: `Makefile` (LDFLAGS), `scripts/build-app.sh` (ldflags line), the CI/release workflow that passes `JIRA_ID` (`grep -rn "JIRA_ID" .github scripts Makefile`)
- Test: `cmd/linear_test.go`

**Interfaces:**
- Consumes: Tasks 2, 4, 6, 7; `resolveLinearOAuthConfig` (Task 9).
- Produces commands. Each opens the DB the `openJiraCmdDB` way (`cmd/jira.go:313`) and shares the persistent `--account` flag:
  - **`linear add [--label L] [--no-open] [--app-return]`:**
    1. `linear.Login`;
    2. `CreateLinearAccount(label)`;
    3. save the token under the lock (copy `saveJiraTokenLocked`, `cmd/jira.go:2012`, with `linear.TokenStore`);
    4. `FetchViewer` → `UpdateLinearAccountConnection` + `SetLinearAccountOwner`;
    5. set config `linear.enabled = true` (copy `enableJiraPhase`).

    If the `org_id` is already connected, refuse with `this Linear workspace is already connected as account N`, delete the new row's token, and mark the new row removed.
  - **`linear login [--account N]`:** re-consent an existing account and overwrite its token; set status `ok` on success.
  - **`linear accounts [--json]`:** ID, Name, Workspace URL, Status, Enabled, Error. JSON keys: `id`, `label`, `org_name`, `url`, `status`, `enabled`, `error`.
  - **`linear enable|disable <id>`**, **`linear remove <id>`:**
    - `remove` does a best-effort `linear.Revoke` with the stored access token, then deletes the token file and calls `SetLinearAccountRemoved`;
    - it prints `Linear account N removed. Token deleted; synced data kept.`;
    - a removed account is refused by enable, disable and login (copy `errJiraAccountRemoved`).
  - **`linear teams [--account N] [--json]`**, **`linear teams select|deselect <TEAM-KEY>...`**.
  - **`linear sync [--account N]`:** one `Syncer.Sync` per account. It prints `account N: M issues synced`, then the per-team `last_error` if any. The exit code is non-zero only for `ErrAuthRevoked`, which also sets the account to `revoked`.
  - **`linear status`:** accounts plus `ListLinearSyncStates` rows (team key, last synced, error).

- [ ] **Step 1: Write the failing tests**

Test the account-resolution and printing helpers with a test DB, without OAuth (the `cmd/jira*_test.go` precedent: `grep -ln "runJiraAccounts\|resolveJiraAccount" cmd/*_test.go`):

```go
func TestResolveLinearAccount(t *testing.T) {
	database := openCmdTestDB(t) // the cmd tests' helper; grep cmd/*_test.go for how they open a DB
	_, err := resolveLinearAccount(database, 0)
	assert.ErrorContains(t, err, "no Linear workspace connected")
	a, _ := database.CreateLinearAccount("A")
	got, err := resolveLinearAccount(database, 0)
	require.NoError(t, err)
	assert.Equal(t, a, got.ID)
	b, _ := database.CreateLinearAccount("B")
	_, err = resolveLinearAccount(database, 0)
	assert.ErrorContains(t, err, "--account")
	require.NoError(t, database.SetLinearAccountRemoved(b))
	_, err = resolveLinearAccount(database, b)
	assert.ErrorContains(t, err, "was removed")
}

func TestPrintLinearAccountsJSON(t *testing.T) {
	database := openCmdTestDB(t)
	id, _ := database.CreateLinearAccount("Work")
	require.NoError(t, database.UpdateLinearAccountConnection(id, "org-1", "acme", "Acme"))
	var buf bytes.Buffer
	require.NoError(t, printLinearAccounts(&buf, database, true))
	var rows []map[string]any
	require.NoError(t, json.Unmarshal(buf.Bytes(), &rows))
	require.Len(t, rows, 1)
	assert.Equal(t, "https://linear.app/acme", rows[0]["url"])
	for _, k := range []string{"id", "label", "org_name", "url", "status", "enabled", "error"} {
		assert.Contains(t, rows[0], k)
	}
}

func TestLinearCommandsRegistered(t *testing.T) {
	for _, name := range []string{"add", "login", "accounts", "enable", "disable", "remove", "teams", "sync", "status"} {
		c, _, err := linearCmd.Find([]string{name})
		require.NoError(t, err, name)
		assert.Equal(t, name, c.Name())
	}
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./cmd/ -run 'Linear'` → FAIL.

- [ ] **Step 3: Implement**

Write `cmd/linear.go` per the Interfaces, reusing the Jira command shapes cited there. `resolveLinearAccount` returns `"no Linear workspace connected; run 'watchtower linear add'"`, `"several Linear workspaces are connected; pass --account"`, and `"linear account N was removed; run 'watchtower linear add' to connect it again"`. Register `linearCmd` on the root the way `jiraCmd` is registered (`grep -n "AddCommand(jiraCmd)" cmd/*.go`).

Build flags: append `-X watchtower/internal/linear.DefaultLinearClientID=$(LINEAR_ID)` to `LDFLAGS` in the `Makefile` (define `LINEAR_ID ?=` next to `JIRA_ID`), and `-X watchtower/internal/linear.DefaultLinearClientID=${LINEAR_ID}` to `scripts/build-app.sh`. Pass `LINEAR_ID` wherever the release workflow passes `JIRA_ID`. It is a public client id (PKCE, no secret), so it can live in the same place as the other ids.

- [ ] **Step 4: Run the tests and a build**

Run: `go test ./cmd/ -run 'Linear' && go build ./... && go run . linear --help` → PASS, and the help lists the subcommands.

- [ ] **Step 5: Commit**

```bash
git add cmd/linear.go cmd/linear_test.go Makefile scripts/build-app.sh .github
git commit -m "feat(cmd): watchtower linear add|login|accounts|teams|sync|status|remove"
```

---

### Task 12: Inventory `linear.md`, feature notes, CLAUDE.md pointer

**Files:**
- Create: `docs/inventory/linear.md`, `docs/features/linear.md`
- Modify: `docs/inventory/README.md` (module map row), `CLAUDE.md` (Feature Notes bullet)
- Test: rename the four guard tests named below to the `TestLinear0N_` convention (they already exist from Tasks 2, 4, 6, 7, 9; renaming keeps one test per contract)

**Interfaces:** documentation only, plus the guard-test renames.

Contracts, with their guard tests:
- **LINEAR-01, the watermark is honest:** a team's watermark advances only after every page of issues and comments of that team succeeded. Guards: `TestLinear01_PageErrorHoldsWatermark` (renamed from `TestSyncer_PageErrorHoldsWatermark`), `TestLinear01_ErrorKeepsWatermark` (renamed from `TestLinearSyncState_ErrorKeepsWatermark`).
- **LINEAR-02, the rotated token pair is saved before use, single-flight:** guards `TestLinear02_RefreshSavesRotatedPair` (renamed from `TestClient_401RefreshesAndSavesRotatedPair`) and `TestLinear02_ConcurrentRefreshSingleFlight`.
- **LINEAR-03, auth loss marks the account revoked and never deletes data:** guards `TestLinear03_RevokedMarksAccount` (renamed from `TestPhaseLinearSync_RevokedMarksAccount`) and `TestLinearAccount_Lifecycle` (soft delete).
- **LINEAR-04, issues are keyed by UUID and keys move:** guard `TestLinear04_TeamMoveKeepsOneRow`.

`docs/features/linear.md` covers:
- architecture (connector → `linear_*` → `tracker_*`);
- OAuth (PKCE, ports 18531–18535 to register, rotation);
- sync (per-team watermark with `gte`, first-pass open issues, 90-day backfill, page sizes and complexity);
- mapping tables;
- the views and their columns;
- CLI;
- v1 limits:
  - permanently deleted issues are not detected;
  - history is capped at 50 entries per issue per pass;
  - Slack mapping is by email only;
  - consumers come in Plan 2.

Use the house format of `docs/inventory/owner-identity.md` for `linear.md`.

CLAUDE.md bullet, in the Feature Notes list near the Jira entries:

```markdown
- [Linear connector (2026-10-15, Plan 1 of 3: schema, tracker_* views, connector; consumers and Desktop pending)](docs/features/linear.md) — `internal/linear/` PKCE OAuth with rotating refresh (fixed loopback ports 18531–18535), GraphQL client with single-flight refresh and rate-limit gate, per-team `gte` watermark sync of issues/comments/history/cycles/projects/relations, `linear_*` tables (00116), tracker-neutral `tracker_*` views over Jira + Linear (00117), `phaseLinearSync`, `watchtower linear …`, OWNER-01 Linear rung; LINEAR-01..04.
```

- [ ] **Step 1: Rename the guard tests and run them**

Run: `go test ./internal/db/ ./internal/linear/ ./internal/daemon/ -run 'TestLinear0'` → PASS (all four contracts' guards).

- [ ] **Step 2: Write the docs**, per the outline above.

- [ ] **Step 3: Commit**

```bash
git add docs/inventory/linear.md docs/inventory/README.md docs/features/linear.md CLAUDE.md internal
git commit -m "docs(linear): inventory LINEAR-01..04, feature note, CLAUDE.md pointer"
```

---

## Phase gate (controller, once, after Task 12)

`bash scripts/dev-health.sh`, then `make test`, `go test ./cmd/...`, `make test-swift`, `make lint-all`. Then do the manual check below. It needs a Linear OAuth app with the redirect URIs `http://localhost:18531/callback` … `18535` registered, and `WATCHTOWER_LINEAR_CLIENT_ID` set. The owner runs it via an ask:
1. `watchtower linear add`;
2. `watchtower linear teams`;
3. `watchtower linear sync`;
4. `sqlite3 <db> "SELECT tracker, key, status_category FROM tracker_issues LIMIT 20"`.

## Dependencies

| Task | Depends on |
|---|---|
| 1 | none |
| 2 | 1 |
| 3 | 2 |
| 4 | none |
| 5 | none |
| 6 | 4 |
| 7 | 2, 5, 6 |
| 8 | 2, 7 |
| 9 | 7 |
| 10 | 1 |
| 11 | 7, 9 |
| 12 | 2, 6, 7, 9 |

Parallel lanes (owner preference, CLAUDE.md "Parallel lanes only when the plan says so"):
- **lane A:** 1 → 2 → 3 → 10;
- **lane B:** 4 → 5 → 6;
- then 7 → 8 → 9 → 11 → 12 on the merged branch.

Only Task 10 touches Swift.
