# Developer Knowledge Base Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Watchtower addressable from inside a developer's agent session — composite read-only MCP tools over the real-world data it already holds, plus a skill pack that teaches the dev's agent how to use them, installed and removed from the CLI.

**Architecture:** Three layers. The *data layer* adds one FTS migration, two db query functions, and three MCP tools (`get_task_context`, `find_experts`, `list_situations`/`get_situation`) — all mechanical SQL, no AI, read-only. The *know-how layer* is four markdown skills embedded in the Go binary with `//go:embed`. The *control layer* is `watchtower integrate claude-code`, which installs both and never clobbers user edits.

**Tech Stack:** Go 1.25, `modernc.org/sqlite` via `database/sql`, goose migrations, `github.com/modelcontextprotocol/go-sdk/mcp`, cobra CLI.

**Spec:** `docs/superpowers/specs/2026-08-09-dev-knowledge-base-design.md`

## Global Constraints

- **DEV-01 — read-only forever.** Every tool added here is a read. The MCP connection is `PRAGMA query_only=ON` (`cmd/mcp.go` calls `database.SetReadOnly()`); no tool in this plan may take a writable handle.
- **DEV-02 — no AI in the data layer.** Every new tool is mechanical SQL. No `digest.Generator`, no prompt, no model call. If a tool seems to need a model, it is the wrong tool.
- **DEV-03 — evidence, not verdicts.** `find_experts` never asserts expertise; every candidate carries countable evidence with a resolvable ref, and the response carries the ranking weights that produced the order.
- **DEV-04 — the installer never clobbers.** Only files carrying the `x-watchtower-pack` marker *and* matching a shipped content hash are rewritten or removed. A user-edited file is left alone and reported as drifted.
- **DEV-05 — pull only.** Nothing added here initiates contact with the developer. No hooks, no notifications, no context injection.
- **Namespaced Slack ids.** Since migration 00048, `users.id`, `messages.channel_id`, and `messages.user_id` hold `"<slack_account_id>:<raw Slack id>"`. Never construct a bare `U…`/`C…` id; pass through whatever the DB holds.
- **MCP conventions** (`internal/mcp/server.go`): register in `NewServer`; clamp list sizes with `listLimit(n)` (default 50, cap 200); return results via `jsonResult` / `jsonListResult`; return failures as `errResult(msg), nil, nil` — a soft error value, never a Go `error`.
- **Migration conventions** (CLAUDE.md): goose file in `internal/db/migrations/`, mirror the DDL into `internal/db/schema.sql`, and regenerate the golden snapshot with `go test ./internal/db/ -run TestSchemaGolden -update`.
- **Verification** (`feedback_verify_real_exit_code`): never pipe a verification command through `tail`; redirect to a log file and check `$?` explicitly.
- **Everything committed to the repo is in English** — code, comments, commit messages, docs.

## File Structure

**Slice 1 — data layer**

| File | Responsibility |
|---|---|
| `internal/db/migrations/00052_transcripts_fts.sql` | Create `transcripts_fts` + sync triggers + backfill existing rows |
| `internal/db/schema.sql` | Mirror of the above (embedded, injected into AI prompts) |
| `internal/db/search.go` | `SearchTranscripts` next to the existing `SearchMessages` — both are FTS readers |
| `internal/db/situations.go` | `ListSituations(SituationFilter)` next to `ListOpenSituations` |
| `internal/db/ideas.go` | `GetJiraCommentsByIssueKey` next to `ListJiraCommentsSince` (where `JiraComment` already lives) |
| `internal/mcp/situations.go` | `list_situations` / `get_situation` tools |
| `internal/mcp/taskcontext.go` | `get_task_context` — the composite dossier |
| `internal/mcp/experts.go` | `find_experts` — evidence collection + ranking |
| `internal/mcp/server.go` | Register the three new tool groups |

**Slice 2 — know-how + control**

| File | Responsibility |
|---|---|
| `internal/devpack/skills/watchtower-task-context/SKILL.md` | Skill: dossier for a ticket |
| `internal/devpack/skills/watchtower-who-to-ask/SKILL.md` | Skill: who knows / who decides / how to approach |
| `internal/devpack/skills/watchtower-whats-changed/SKILL.md` | Skill: what moved while heads-down |
| `internal/devpack/skills/watchtower-why-decision/SKILL.md` | Skill: decision archaeology with provenance |
| `internal/devpack/pack.go` | `//go:embed skills/*`, the pack manifest, content hashing |
| `internal/devpack/install.go` | Install / status / remove against a target skills directory |
| `cmd/integrate.go` | The `watchtower integrate` command tree |
| `docs/inventory/dev-surface.md` | DEV-01..05 behavioral contracts |
| `docs/inventory/README.md` | Module → inventory-file mapping entry |

---

## Task 1: `transcripts_fts` migration

Meeting transcripts have no keyword search at all — no FTS table and not one `transcript_text LIKE` in the repo. This builds the index the way `messages_fts` is built (`schema.sql:88-120`).

**Files:**
- Create: `internal/db/migrations/00052_transcripts_fts.sql`
- Modify: `internal/db/schema.sql` (after the `meeting_transcripts` table, ~line 1092)
- Test: `internal/db/db_test.go` (new test function)

**Interfaces:**
- Consumes: nothing.
- Produces: the `transcripts_fts` virtual table with columns `(text, transcript_id UNINDEXED, title UNINDEXED)`, kept in sync with `meeting_transcripts` by three triggers.

- [ ] **Step 1: Write the failing test**

Append to `internal/db/db_test.go`:

```go
func TestTranscriptsFTSIndexesAndTracksRows(t *testing.T) {
	database := setupTestDB(t)

	id, err := database.InsertMeetingTranscript(db.MeetingTranscript{
		Title:          "Roadmap sync",
		TranscriptText: "[Я] we decided to postpone the payments migration",
	})
	require.NoError(t, err)

	// Insert is indexed.
	var got int64
	err = database.QueryRow(
		`SELECT transcript_id FROM transcripts_fts WHERE transcripts_fts MATCH 'payments'`,
	).Scan(&got)
	require.NoError(t, err)
	assert.Equal(t, id, got)

	// Porter stemming works the same way it does for messages_fts.
	var n int
	err = database.QueryRow(
		`SELECT count(*) FROM transcripts_fts WHERE transcripts_fts MATCH 'decide'`,
	).Scan(&n)
	require.NoError(t, err)
	assert.Equal(t, 1, n)

	// Update re-indexes rather than duplicating.
	_, err = database.Exec(
		`UPDATE meeting_transcripts SET transcript_text = ? WHERE id = ?`,
		"[Я] we shipped the invoicing rewrite", id)
	require.NoError(t, err)

	err = database.QueryRow(
		`SELECT count(*) FROM transcripts_fts WHERE transcripts_fts MATCH 'payments'`,
	).Scan(&n)
	require.NoError(t, err)
	assert.Equal(t, 0, n, "stale text must not survive an update")

	err = database.QueryRow(
		`SELECT count(*) FROM transcripts_fts WHERE transcripts_fts MATCH 'invoicing'`,
	).Scan(&n)
	require.NoError(t, err)
	assert.Equal(t, 1, n)

	// Delete removes the row from the index.
	_, err = database.Exec(`DELETE FROM meeting_transcripts WHERE id = ?`, id)
	require.NoError(t, err)

	err = database.QueryRow(`SELECT count(*) FROM transcripts_fts`).Scan(&n)
	require.NoError(t, err)
	assert.Equal(t, 0, n)
}
```

Check the file's existing helper name first: `internal/db/db_test.go` already opens temp databases — reuse whatever helper the neighbouring tests use (grep for `func setupTestDB` / `openTestDB` in that file and match it) rather than adding another.

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/db/ -run TestTranscriptsFTSIndexesAndTracksRows -v > /tmp/t1.log 2>&1; echo "exit=$?"
```

Expected: FAIL — `no such table: transcripts_fts`.

- [ ] **Step 3: Write the migration**

Create `internal/db/migrations/00052_transcripts_fts.sql`:

```sql
-- +goose Up
-- Full-text index over meeting transcripts. Meetings are the highest-signal
-- material Watchtower holds and were the only source with no keyword search:
-- the dev surface's task dossier and decision archaeology both read it.
CREATE VIRTUAL TABLE IF NOT EXISTS transcripts_fts USING fts5(
    text,
    transcript_id UNINDEXED,
    title UNINDEXED,
    tokenize='porter unicode61'
);

CREATE TRIGGER IF NOT EXISTS meeting_transcripts_ai AFTER INSERT ON meeting_transcripts
WHEN NEW.transcript_text != ''
BEGIN
    DELETE FROM transcripts_fts WHERE transcript_id = NEW.id;
    INSERT INTO transcripts_fts(text, transcript_id, title)
    VALUES (NEW.transcript_text, NEW.id, NEW.title);
END;

CREATE TRIGGER IF NOT EXISTS meeting_transcripts_ad AFTER DELETE ON meeting_transcripts
BEGIN
    DELETE FROM transcripts_fts WHERE transcript_id = OLD.id;
END;

CREATE TRIGGER IF NOT EXISTS meeting_transcripts_au AFTER UPDATE OF transcript_text, title ON meeting_transcripts
BEGIN
    DELETE FROM transcripts_fts WHERE transcript_id = OLD.id;
    INSERT INTO transcripts_fts(text, transcript_id, title)
    SELECT NEW.transcript_text, NEW.id, NEW.title
    WHERE NEW.transcript_text != '';
END;

-- Backfill transcripts recorded before this index existed.
INSERT INTO transcripts_fts(text, transcript_id, title)
SELECT transcript_text, id, title FROM meeting_transcripts WHERE transcript_text != '';

-- +goose Down
DROP TRIGGER IF EXISTS meeting_transcripts_au;
DROP TRIGGER IF EXISTS meeting_transcripts_ad;
DROP TRIGGER IF EXISTS meeting_transcripts_ai;
DROP TABLE IF EXISTS transcripts_fts;
```

- [ ] **Step 4: Mirror the DDL into `schema.sql`**

Copy the four `CREATE` statements (virtual table + three triggers, **not** the backfill `INSERT`) into `internal/db/schema.sql` immediately after the `meeting_transcripts` table definition and its indexes. `schema.sql` describes a fresh database, so it carries structure only.

- [ ] **Step 5: Run test to verify it passes**

```bash
go test ./internal/db/ -run TestTranscriptsFTSIndexesAndTracksRows -v > /tmp/t1.log 2>&1; echo "exit=$?"
```

Expected: PASS.

- [ ] **Step 6: Regenerate the schema golden snapshot and run the full db suite**

```bash
go test ./internal/db/ -run TestSchemaGolden -update > /tmp/t1b.log 2>&1; echo "exit=$?"
go test ./internal/db/ > /tmp/t1c.log 2>&1; echo "exit=$?"
```

Expected: both exit 0. If `TestAllTablesExist` fails, add `transcripts_fts` to its table list the way `memory_fts` is handled (`internal/db/db_test.go:261`).

- [ ] **Step 7: Commit**

```bash
git add internal/db/migrations/00052_transcripts_fts.sql internal/db/schema.sql internal/db/db_test.go internal/db/testdata/
git commit -m "feat(db): full-text index over meeting transcripts

Meetings were the only source with no keyword search at all. Mirrors the
messages_fts pattern: FTS5 virtual table, insert/update/delete triggers,
and a backfill for transcripts recorded before the index existed."
```

---

## Task 2: `SearchTranscripts` query function

**Files:**
- Modify: `internal/db/search.go` (append after `SearchMessages` and its helpers)
- Modify: `internal/db/models.go` (add `TranscriptHit`) — or define it in `search.go` next to its only consumer; follow whichever the file already does for `MemoryHit`-style result structs.
- Test: `internal/db/search_test.go`

**Interfaces:**
- Consumes: `transcripts_fts` (Task 1); `sanitizeFTS5Query(string) string` (`internal/db/search.go:154`).
- Produces:
  ```go
  type TranscriptHit struct {
      ID        int64
      Title     string
      EventID   string
      CreatedAt string
      Snippet   string // ±200 chars around the first match
  }
  func (db *DB) SearchTranscripts(query string, limit int) ([]TranscriptHit, error)
  ```

- [ ] **Step 1: Write the failing test**

Create or append to `internal/db/search_test.go`:

```go
func TestSearchTranscriptsFindsAndSnippets(t *testing.T) {
	database := setupTestDB(t)

	hit, err := database.InsertMeetingTranscript(db.MeetingTranscript{
		Title:          "Payments sync",
		TranscriptText: "[Я] the decision is to keep tokens in a file, not the keychain",
	})
	require.NoError(t, err)
	_, err = database.InsertMeetingTranscript(db.MeetingTranscript{
		Title:          "Unrelated",
		TranscriptText: "[Я] discussed hiring",
	})
	require.NoError(t, err)

	got, err := database.SearchTranscripts("keychain", 10)
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, hit, got[0].ID)
	assert.Equal(t, "Payments sync", got[0].Title)
	assert.Contains(t, got[0].Snippet, "keychain")

	// Empty query is a no-op, not an error — mirrors SearchMessages.
	empty, err := database.SearchTranscripts("", 10)
	require.NoError(t, err)
	assert.Empty(t, empty)

	// FTS5 operators are sanitized away rather than erroring.
	safe, err := database.SearchTranscripts(`keychain OR "`, 10)
	require.NoError(t, err)
	assert.NotEmpty(t, safe)
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/db/ -run TestSearchTranscriptsFindsAndSnippets -v > /tmp/t2.log 2>&1; echo "exit=$?"
```

Expected: FAIL — `database.SearchTranscripts undefined`.

- [ ] **Step 3: Implement**

Append to `internal/db/search.go`:

```go
// TranscriptHit is one full-text match in a meeting transcript: enough to
// decide whether to fetch the whole thing, never the whole thing itself.
type TranscriptHit struct {
	ID        int64  `json:"id"`
	Title     string `json:"title"`
	EventID   string `json:"event_id,omitempty"`
	CreatedAt string `json:"created_at"`
	Snippet   string `json:"snippet"`
}

// SearchTranscripts runs a full-text search over meeting transcripts via
// transcripts_fts, newest first. The query is sanitized the same way
// SearchMessages sanitizes its input, so caller text can never inject FTS5
// operators. An empty query returns no rows and no error.
func (db *DB) SearchTranscripts(query string, limit int) ([]TranscriptHit, error) {
	sanitized := sanitizeFTS5Query(query)
	if sanitized == "" {
		return nil, nil
	}
	if limit <= 0 {
		limit = 20
	}

	rows, err := db.Query(`
		SELECT mt.id, mt.title, COALESCE(mt.event_id, ''), mt.created_at,
		       snippet(transcripts_fts, 0, '', '', '…', 40)
		FROM transcripts_fts
		JOIN meeting_transcripts mt ON mt.id = transcripts_fts.transcript_id
		WHERE transcripts_fts MATCH ?
		ORDER BY mt.created_at DESC
		LIMIT ?`, sanitized, limit)
	if err != nil {
		return nil, fmt.Errorf("searching transcripts: %w", err)
	}
	defer rows.Close()

	var out []TranscriptHit
	for rows.Next() {
		var h TranscriptHit
		if err := rows.Scan(&h.ID, &h.Title, &h.EventID, &h.CreatedAt, &h.Snippet); err != nil {
			return nil, fmt.Errorf("scanning transcript hit: %w", err)
		}
		out = append(out, h)
	}
	return out, rows.Err()
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
go test ./internal/db/ -run TestSearchTranscripts -v > /tmp/t2.log 2>&1; echo "exit=$?"
```

Expected: PASS. If the `snippet()` call errors, confirm column 0 of `transcripts_fts` is `text` — `snippet()` indexes columns positionally.

- [ ] **Step 5: Commit**

```bash
git add internal/db/search.go internal/db/search_test.go
git commit -m "feat(db): SearchTranscripts full-text query over meeting transcripts"
```

---

## Task 3: `ListSituations` filtered query

The dashboard's only list function is `ListOpenSituations()` — no status filter, no `since`, no limit — because it was written for exactly one screen.

**Files:**
- Modify: `internal/db/situations.go` (after `ListOpenSituations`, ~line 88)
- Test: `internal/db/situations_test.go`

**Interfaces:**
- Consumes: `situationSelectCols`, `scanSituation` (both already in `internal/db/situations.go`).
- Produces:
  ```go
  type SituationFilter struct {
      Status   string // "" = any; one of open|done|dismissed|converted|stale|snoozed
      SinceISO string // "" = no bound; compares against last_signal_at
      Limit    int    // <= 0 means 50
  }
  func (db *DB) ListSituations(f SituationFilter) ([]DashboardSituation, error)
  ```

- [ ] **Step 1: Write the failing test**

Append to `internal/db/situations_test.go`:

```go
func TestListSituationsFiltersByStatusAndSince(t *testing.T) {
	database := setupTestDB(t)

	mk := func(title, status, lastSignal string, rank float64) int {
		t.Helper()
		res, err := database.Exec(`INSERT INTO situations (title, status, rank, last_signal_at)
			VALUES (?, ?, ?, ?)`, title, status, rank, lastSignal)
		require.NoError(t, err)
		id, err := res.LastInsertId()
		require.NoError(t, err)
		return int(id)
	}

	openNew := mk("fresh open", "open", "2026-08-08T10:00:00Z", 5)
	mk("old open", "open", "2026-08-01T10:00:00Z", 9)
	mk("done one", "done", "2026-08-08T11:00:00Z", 7)

	// Status filter.
	got, err := database.ListSituations(db.SituationFilter{Status: "open"})
	require.NoError(t, err)
	require.Len(t, got, 2)
	assert.Equal(t, "old open", got[0].Title, "highest rank first")

	// Since filter applies to last_signal_at.
	got, err = database.ListSituations(db.SituationFilter{Status: "open", SinceISO: "2026-08-05T00:00:00Z"})
	require.NoError(t, err)
	require.Len(t, got, 1)
	assert.Equal(t, openNew, got[0].ID)

	// No filter returns every status.
	got, err = database.ListSituations(db.SituationFilter{})
	require.NoError(t, err)
	assert.Len(t, got, 3)

	// Limit is honored.
	got, err = database.ListSituations(db.SituationFilter{Limit: 1})
	require.NoError(t, err)
	assert.Len(t, got, 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/db/ -run TestListSituationsFiltersByStatusAndSince -v > /tmp/t3.log 2>&1; echo "exit=$?"
```

Expected: FAIL — `undefined: db.SituationFilter`.

- [ ] **Step 3: Implement**

Append to `internal/db/situations.go` after `ListOpenSituations`:

```go
// SituationFilter narrows ListSituations. The zero value lists every
// situation, newest-ranked first, capped at the default limit.
type SituationFilter struct {
	Status   string // "" = any status
	SinceISO string // "" = no bound; filters on last_signal_at
	Limit    int    // <= 0 = 50
}

// ListSituations lists dashboard situations with optional status/recency
// filters. ListOpenSituations remains the pipeline's unfiltered read; this is
// the filtered surface the MCP tools and any recency-scoped caller need.
func (db *DB) ListSituations(f SituationFilter) ([]DashboardSituation, error) {
	query := `SELECT ` + situationSelectCols + ` FROM situations`
	var conds []string
	var args []any

	if f.Status != "" {
		conds = append(conds, "status = ?")
		args = append(args, f.Status)
	}
	if f.SinceISO != "" {
		conds = append(conds, "last_signal_at >= ?")
		args = append(args, f.SinceISO)
	}
	if len(conds) > 0 {
		query += " WHERE " + strings.Join(conds, " AND ")
	}

	limit := f.Limit
	if limit <= 0 {
		limit = 50
	}
	query += " ORDER BY rank DESC, updated_at DESC LIMIT ?"
	args = append(args, limit)

	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("listing situations: %w", err)
	}
	defer rows.Close()

	var out []DashboardSituation
	for rows.Next() {
		s, err := scanSituation(rows)
		if err != nil {
			return nil, fmt.Errorf("scanning situation: %w", err)
		}
		out = append(out, *s)
	}
	return out, rows.Err()
}
```

Add `"strings"` to the file's imports if it is not already there.

- [ ] **Step 4: Run test to verify it passes**

```bash
go test ./internal/db/ -run TestListSituations -v > /tmp/t3.log 2>&1; echo "exit=$?"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/db/situations.go internal/db/situations_test.go
git commit -m "feat(db): ListSituations with status/since/limit filters"
```

---

## Task 4: `GetJiraCommentsByIssueKey`

The only reader today is `ListJiraCommentsSince(accountID, keys, since)`, which demands an account id and a time bound. A dossier wants one issue's comments, oldest first.

**Files:**
- Modify: `internal/db/ideas.go` (next to `ListJiraCommentsSince`, ~line 571)
- Test: `internal/db/ideas_test.go`

**Interfaces:**
- Consumes: the `jira_comments` table and the existing `JiraComment` struct (`internal/db/ideas.go:517`).
- Produces: `func (db *DB) GetJiraCommentsByIssueKey(issueKey string, limit int) ([]JiraComment, error)` — chronological (oldest first), `limit <= 0` means 100.

- [ ] **Step 1: Write the failing test**

Append to `internal/db/ideas_test.go`:

```go
func TestGetJiraCommentsByIssueKeyReturnsChronologically(t *testing.T) {
	database := setupTestDB(t)
	seedJiraAccount(t, database) // reuse whatever the neighbouring jira tests use

	ins := func(id, key, body, updated string) {
		t.Helper()
		_, err := database.Exec(`INSERT INTO jira_comments
			(account_id, issue_key, id, author, author_account_id, body_text, created_at, updated_at, synced_at)
			VALUES (1, ?, ?, 'Petya', 'acc-1', ?, ?, ?, ?)`,
			key, id, body, updated, updated, updated)
		require.NoError(t, err)
	}
	ins("c2", "PROJ-1", "second", "2026-08-02T10:00:00Z")
	ins("c1", "PROJ-1", "first", "2026-08-01T10:00:00Z")
	ins("c3", "OTHER-9", "other issue", "2026-08-03T10:00:00Z")

	got, err := database.GetJiraCommentsByIssueKey("PROJ-1", 0)
	require.NoError(t, err)
	require.Len(t, got, 2)
	assert.Equal(t, "first", got[0].BodyText, "oldest first")
	assert.Equal(t, "second", got[1].BodyText)

	// Unknown key is empty, not an error.
	none, err := database.GetJiraCommentsByIssueKey("NOPE-1", 0)
	require.NoError(t, err)
	assert.Empty(t, none)
}
```

If no `seedJiraAccount` helper exists in that package's tests, insert the account row inline:
```go
_, err := database.Exec(`INSERT INTO jira_accounts (id, cloud_id, site_url, site_name, label, status, enabled)
	VALUES (1, 'cloud-1', 'https://x.atlassian.net', 'X', 'X', 'ok', 1)`)
require.NoError(t, err)
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/db/ -run TestGetJiraCommentsByIssueKey -v > /tmp/t4.log 2>&1; echo "exit=$?"
```

Expected: FAIL — `database.GetJiraCommentsByIssueKey undefined`.

- [ ] **Step 3: Implement**

Append near `ListJiraCommentsSince` in `internal/db/ideas.go`:

```go
// GetJiraCommentsByIssueKey returns one issue's comments oldest-first.
// Deliberately NOT account-scoped: an issue key is site-ambiguous by nature
// (the documented v1 limitation of the Jira multi-account design), and the
// dossier's caller addresses issues by bare key like every other reader.
func (db *DB) GetJiraCommentsByIssueKey(issueKey string, limit int) ([]JiraComment, error) {
	if issueKey == "" {
		return nil, nil
	}
	if limit <= 0 {
		limit = 100
	}
	rows, err := db.Query(`SELECT account_id, issue_key, id, author, author_account_id,
			body_text, created_at, updated_at
		FROM jira_comments WHERE issue_key = ?
		ORDER BY updated_at ASC, id ASC LIMIT ?`, issueKey, limit)
	if err != nil {
		return nil, fmt.Errorf("getting comments for %s: %w", issueKey, err)
	}
	defer rows.Close()

	var out []JiraComment
	for rows.Next() {
		var c JiraComment
		if err := rows.Scan(&c.AccountID, &c.IssueKey, &c.ID, &c.Author,
			&c.AuthorAccountID, &c.BodyText, &c.CreatedAt, &c.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scanning jira comment: %w", err)
		}
		out = append(out, c)
	}
	return out, rows.Err()
}
```

Match the field names to the actual `JiraComment` struct at `internal/db/ideas.go:517` before writing the scan — read it first.

- [ ] **Step 4: Run test to verify it passes**

```bash
go test ./internal/db/ -run TestGetJiraCommentsByIssueKey -v > /tmp/t4.log 2>&1; echo "exit=$?"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/db/ideas.go internal/db/ideas_test.go
git commit -m "feat(db): GetJiraCommentsByIssueKey for per-issue comment reads"
```

---

## Task 5: `list_situations` / `get_situation` MCP tools

The secretary's dashboard — the product's central artifact — currently exists only in the Desktop app.

**Files:**
- Create: `internal/mcp/situations.go`
- Modify: `internal/mcp/server.go` (add `registerSituations(srv.s, database)` to `NewServer`, ~line 122)
- Test: `internal/mcp/situations_test.go`

**Interfaces:**
- Consumes: `db.ListSituations(db.SituationFilter{...})` (Task 3), `db.GetSituation(int)`, `db.ListSituationSignals(int)`.
- Produces: MCP tools `list_situations` (args `status`, `since`, `limit`) and `get_situation` (arg `id`).

- [ ] **Step 1: Write the failing test**

Create `internal/mcp/situations_test.go`:

```go
package mcp

import (
	"context"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestListSituationsReturnsOpenOnesRanked(t *testing.T) {
	database := seedDB(t)
	_, err := database.Exec(`INSERT INTO situations (title, status, rank, priority, why_matters, last_signal_at)
		VALUES ('Payments migration stalled', 'open', 9, 'high', 'blocks the release', '2026-08-08T10:00:00Z'),
		       ('Old thing', 'done', 1, 'low', '', '2026-08-01T10:00:00Z')`)
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_situations",
		Arguments: map[string]any{"status": "open"},
	})
	if err != nil {
		t.Fatalf("calling list_situations: %v", err)
	}
	if res.IsError {
		t.Fatalf("tool error: %s", textContent(t, res))
	}
	out := textContent(t, res)
	if !contains(out, "Payments migration stalled") {
		t.Fatalf("expected the open situation in output, got: %s", out)
	}
	if contains(out, "Old thing") {
		t.Fatalf("done situation must not appear under status=open: %s", out)
	}
}

func TestGetSituationIncludesSignalsAndMissingIdIsSoftError(t *testing.T) {
	database := seedDB(t)
	if _, err := database.Exec(`INSERT INTO situations (id, title, status, why_matters, summary)
		VALUES (1, 'Release blocked', 'open', 'ship date at risk', 'the migration is stuck')`); err != nil {
		t.Fatalf("seed situation: %v", err)
	}
	if _, err := database.Exec(`INSERT INTO inbox_items (id, trigger_type, channel_id, message_ts, sender_user_id, snippet, status)
		VALUES (10, 'mention', '1:C1', '111.1', '1:U2', 'we cannot ship until this lands', 'pending')`); err != nil {
		t.Fatalf("seed inbox item: %v", err)
	}
	if _, err := database.Exec(`INSERT INTO situation_signals (situation_id, inbox_item_id) VALUES (1, 10)`); err != nil {
		t.Fatalf("seed signal: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_situation",
		Arguments: map[string]any{"id": 1},
	})
	if err != nil {
		t.Fatalf("calling get_situation: %v", err)
	}
	out := textContent(t, res)
	if !contains(out, "we cannot ship until this lands") {
		t.Fatalf("expected signal text in the situation detail, got: %s", out)
	}

	missing, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_situation",
		Arguments: map[string]any{"id": 999},
	})
	if err != nil {
		t.Fatalf("calling get_situation: %v", err)
	}
	if !missing.IsError {
		t.Fatalf("a missing id must be a soft tool error, got: %s", textContent(t, missing))
	}
}

// contains is a tiny readability wrapper over strings.Contains.
func contains(haystack, needle string) bool { return strings.Contains(haystack, needle) }
```

Add the `strings` import. Check `internal/mcp/server_test.go` first — if a `contains` helper already exists there, use it and delete this one rather than shadowing.

Verify the `inbox_items` insert columns against the real schema before running (`grep -n -A30 "CREATE TABLE IF NOT EXISTS inbox_items" internal/db/schema.sql`) — the table has NOT NULL columns beyond the ones above.

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/mcp/ -run TestListSituations -v > /tmp/t5.log 2>&1; echo "exit=$?"
```

Expected: FAIL — tool `list_situations` not found.

- [ ] **Step 3: Implement**

Create `internal/mcp/situations.go`:

```go
package mcp

import (
	"context"
	"strconv"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

type listSituationsArgs struct {
	Status string `json:"status,omitempty" jsonschema:"filter by status: open|done|dismissed|converted|stale|snoozed (default: open)"`
	Since  string `json:"since,omitempty" jsonschema:"only situations with a signal on/after this date (YYYY-MM-DD)"`
	Limit  int    `json:"limit,omitempty" jsonschema:"max results, 0 = default (50), capped at 200"`
}

type getSituationArgs struct {
	ID int `json:"id" jsonschema:"situation id from list_situations"`
}

// situationRow is the list shape: what the situation is and why it matters,
// without the full chronology (that is get_situation's job).
type situationRow struct {
	ID           int    `json:"id"`
	Title        string `json:"title"`
	Status       string `json:"status"`
	Priority     string `json:"priority"`
	Kind         string `json:"kind"`
	WhyMatters   string `json:"why_matters,omitempty"`
	LastSignalAt string `json:"last_signal_at,omitempty"`
}

// situationSignal is one member message folded into a situation.
type situationSignal struct {
	SenderUserID string `json:"sender"`
	ChannelID    string `json:"channel_id,omitempty"`
	MessageTS    string `json:"message_ts,omitempty"`
	Snippet      string `json:"snippet"`
	Permalink    string `json:"permalink,omitempty"`
}

// situationDetail is the get_situation shape: the row plus the secretary card
// and the signals that produced it.
type situationDetail struct {
	situationRow
	Summary            string            `json:"summary,omitempty"`
	Chronology         string            `json:"chronology,omitempty"`
	ConvertedTargetID  int               `json:"converted_target_id,omitempty"`
	ConvertedTrackID   int               `json:"converted_track_id,omitempty"`
	Signals            []situationSignal `json:"signals"`
}

func registerSituations(s *mcpsdk.Server, database *db.DB) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name: "list_situations",
		Description: "List the secretary's situations — clustered stories from Slack, Jira, " +
			"mail and calendar that need the owner's attention. Use to answer " +
			"'what is going on' or 'what changed recently'.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args listSituationsArgs) (*mcpsdk.CallToolResult, any, error) {
		if msg := validateEnum("status", args.Status,
			"open", "done", "dismissed", "converted", "stale", "snoozed"); msg != "" {
			return errResult(msg), nil, nil
		}
		since, sinceMsg := dateBound(args.Since, "since", "T00:00:00Z")
		if sinceMsg != "" {
			return errResult(sinceMsg), nil, nil
		}
		status := args.Status
		if status == "" {
			status = "open"
		}

		situations, err := database.ListSituations(db.SituationFilter{
			Status:   status,
			SinceISO: since,
			Limit:    listLimit(args.Limit),
		})
		if err != nil {
			return errResult("listing situations: " + err.Error()), nil, nil
		}
		rows := make([]situationRow, 0, len(situations))
		for i := range situations {
			rows = append(rows, renderSituationRow(&situations[i]))
		}
		return jsonListResult(rows)
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name: "get_situation",
		Description: "Fetch one situation by id: the secretary's card (why it matters, summary, " +
			"chronology) plus the member messages it was built from.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args getSituationArgs) (*mcpsdk.CallToolResult, any, error) {
		s, err := database.GetSituation(args.ID)
		if err != nil {
			return errResult("no situation with id " + strconv.Itoa(args.ID)), nil, nil
		}
		signals, err := database.ListSituationSignals(args.ID)
		if err != nil {
			return errResult("listing signals: " + err.Error()), nil, nil
		}
		detail := situationDetail{
			situationRow:      renderSituationRow(&s),
			Summary:           s.Summary,
			Chronology:        s.Chronology,
			ConvertedTargetID: s.ConvertedTargetID,
			ConvertedTrackID:  s.ConvertedTrackID,
			Signals:           make([]situationSignal, 0, len(signals)),
		}
		for _, item := range signals {
			detail.Signals = append(detail.Signals, situationSignal{
				SenderUserID: item.SenderUserID,
				ChannelID:    item.ChannelID,
				MessageTS:    item.MessageTS,
				Snippet:      item.Snippet,
				Permalink:    item.Permalink,
			})
		}
		return jsonResult(detail)
	})
}

func renderSituationRow(s *db.DashboardSituation) situationRow {
	return situationRow{
		ID:           s.ID,
		Title:        s.Title,
		Status:       s.Status,
		Priority:     s.Priority,
		Kind:         s.Kind,
		WhyMatters:   s.WhyMatters,
		LastSignalAt: s.LastSignalAt,
	}
}
```

Check `db.DashboardSituation`'s field types (`internal/db/models.go:565-588`) — if `ConvertedTargetID`/`ConvertedTrackID` are `*int`, dereference safely rather than assigning.

Register it in `internal/mcp/server.go`'s `NewServer`, next to the other `register…` calls:

```go
	registerSituations(srv.s, database)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
go test ./internal/mcp/ -run "TestListSituations|TestGetSituation" -v > /tmp/t5.log 2>&1; echo "exit=$?"
```

Expected: PASS. `dateBound` already exists in the package (used by `list_transcripts`); reuse it rather than parsing dates again.

- [ ] **Step 5: Commit**

```bash
git add internal/mcp/situations.go internal/mcp/situations_test.go internal/mcp/server.go
git commit -m "feat(mcp): expose the secretary dashboard via list_situations/get_situation"
```

---

## Task 6: `get_task_context` — the ticket dossier

**Files:**
- Create: `internal/mcp/taskcontext.go`
- Modify: `internal/mcp/server.go` (`registerTaskContext(srv.s, database)`)
- Test: `internal/mcp/taskcontext_test.go`

**Interfaces:**
- Consumes: `db.GetJiraIssueByKey`, `db.GetJiraCommentsByIssueKey` (Task 4), `db.GetJiraSlackLinksByIssue`, `db.GetThreadReplies`, `db.GetMessagesByTS`, `db.SearchTranscripts` (Task 2), `db.ListIdeas`, `db.ListIdeaMentions`.
- Produces: MCP tool `get_task_context` (arg `key`).

- [ ] **Step 1: Write the failing test**

Create `internal/mcp/taskcontext_test.go`:

```go
package mcp

import (
	"context"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestGetTaskContextAssemblesTheDossier(t *testing.T) {
	database := seedDB(t)
	seedTaskContextFixture(t, database)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_task_context",
		Arguments: map[string]any{"key": "PROJ-1"},
	})
	if err != nil {
		t.Fatalf("calling get_task_context: %v", err)
	}
	if res.IsError {
		t.Fatalf("tool error: %s", textContent(t, res))
	}
	out := textContent(t, res)

	for _, want := range []string{
		"Rewrite the payment flow",            // the issue itself
		"do not touch the legacy adapter",     // a comment
		"we agreed to keep the old endpoint",  // a linked thread reply
		"keep tokens in a file",               // a meeting transcript hit
		"Token storage: file, not keychain",   // a registry decision
	} {
		if !contains(out, want) {
			t.Fatalf("dossier missing %q; got: %s", want, out)
		}
	}
}

func TestGetTaskContextOnUnknownKeyIsSoftError(t *testing.T) {
	database := seedDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_task_context",
		Arguments: map[string]any{"key": "NOPE-1"},
	})
	if err != nil {
		t.Fatalf("calling get_task_context: %v", err)
	}
	if !res.IsError {
		t.Fatalf("unknown key must be a soft tool error, got: %s", textContent(t, res))
	}
}

func TestGetTaskContextOmitsEmptySections(t *testing.T) {
	database := seedDB(t)
	seedJiraIssueOnly(t, database) // issue exists, nothing else does
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_task_context",
		Arguments: map[string]any{"key": "PROJ-2"},
	})
	if err != nil {
		t.Fatalf("calling get_task_context: %v", err)
	}
	if res.IsError {
		t.Fatalf("an issue with no surrounding material must still return a dossier: %s", textContent(t, res))
	}
	out := textContent(t, res)
	for _, absent := range []string{"\"threads\"", "\"meetings\"", "\"decisions\""} {
		if contains(out, absent) {
			t.Fatalf("empty section %s must be omitted, got: %s", absent, out)
		}
	}
}
```

Write the two seed helpers in the same file. `seedTaskContextFixture` must insert: a `jira_accounts` row; a `jira_issues` row (`account_id=1, key='PROJ-1', summary='Rewrite the payment flow'`, plus its NOT NULL columns `project_key`, `status`, `status_category`, `created_at`, `updated_at`, `synced_at`); a `jira_comments` row with `body_text='do not touch the legacy adapter'`; a `channels` row and two `messages` rows forming a thread (parent + reply `'we agreed to keep the old endpoint'`, the reply sharing the parent's `thread_ts`); a `jira_slack_links` row pointing at the parent message; a `meeting_transcripts` row whose text contains `'PROJ-1'` and `'keep tokens in a file'`; and an `ideas` row (`kind='decision'`, `title='Token storage: file, not keychain'`) with an `idea_mentions` row (`source='jira'`, `ref='PROJ-1'`). Read each table's NOT NULL columns from `internal/db/schema.sql` before writing the inserts.

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/mcp/ -run TestGetTaskContext -v > /tmp/t6.log 2>&1; echo "exit=$?"
```

Expected: FAIL — tool `get_task_context` not found.

- [ ] **Step 3: Implement**

Create `internal/mcp/taskcontext.go`:

```go
package mcp

import (
	"context"
	"strings"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

// Per-section caps keep the dossier context-window-sized. A dossier that
// blows the window is worse than a partial one: the agent silently loses the
// tail, usually the recent material.
const (
	taskContextMaxComments = 30
	taskContextMaxThreads  = 8
	taskContextMaxReplies  = 25
	taskContextMaxMeetings = 5
	taskContextMaxIdeas    = 15
)

type getTaskContextArgs struct {
	Key string `json:"key" jsonschema:"Jira issue key, e.g. PROJ-123"`
}

type taskIssue struct {
	Key         string `json:"key"`
	Summary     string `json:"summary"`
	Description string `json:"description,omitempty"`
	Status      string `json:"status"`
	IssueType   string `json:"issue_type,omitempty"`
	Priority    string `json:"priority,omitempty"`
	Assignee    string `json:"assignee,omitempty"`
	Reporter    string `json:"reporter,omitempty"`
	SprintName  string `json:"sprint,omitempty"`
	UpdatedAt   string `json:"updated_at,omitempty"`
}

type taskComment struct {
	Author    string `json:"author"`
	Body      string `json:"body"`
	UpdatedAt string `json:"updated_at"`
}

type taskMessage struct {
	Sender    string `json:"sender"`
	Text      string `json:"text"`
	TS        string `json:"ts"`
	Permalink string `json:"permalink,omitempty"`
}

// taskThread is a linked Slack conversation. jira_slack_links names one
// message; the value is the discussion around it, so the tool resolves the
// message to its thread and returns the replies.
type taskThread struct {
	ChannelID   string        `json:"channel_id"`
	ChannelName string        `json:"channel,omitempty"`
	Messages    []taskMessage `json:"messages"`
}

type taskMeeting struct {
	TranscriptID int64  `json:"transcript_id"`
	Title        string `json:"title"`
	CreatedAt    string `json:"created_at"`
	Snippet      string `json:"snippet"`
}

type taskDecision struct {
	ID      int64  `json:"id"`
	Kind    string `json:"kind"`
	Title   string `json:"title"`
	Essence string `json:"essence,omitempty"`
	Status  string `json:"status"`
}

// taskContext is the dossier. Every section but the issue is omitempty: a
// section with nothing in it is absent, never an empty array, so the agent
// can tell "nothing found" from "not looked for".
type taskContext struct {
	Issue     taskIssue      `json:"issue"`
	Comments  []taskComment  `json:"comments,omitempty"`
	Threads   []taskThread   `json:"threads,omitempty"`
	Meetings  []taskMeeting  `json:"meetings,omitempty"`
	Decisions []taskDecision `json:"decisions,omitempty"`
	People    []string       `json:"people,omitempty"`
	Notes     []string       `json:"notes,omitempty"`
}

func registerTaskContext(s *mcpsdk.Server, database *db.DB) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name: "get_task_context",
		Description: "Assemble everything Watchtower knows about a Jira issue: the ticket and its " +
			"comments, the Slack threads where it was discussed, meetings that mentioned it, " +
			"recorded decisions, and the people involved. Use before starting work on a ticket — " +
			"it carries the context the ticket text does not.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args getTaskContextArgs) (*mcpsdk.CallToolResult, any, error) {
		key := strings.TrimSpace(args.Key)
		if key == "" {
			return errResult("key is required, e.g. PROJ-123"), nil, nil
		}

		issue, err := database.GetJiraIssueByKey(key)
		if err != nil {
			return errResult("loading issue: " + err.Error()), nil, nil
		}
		if issue == nil {
			return errResult("no issue with key " + key), nil, nil
		}

		out := taskContext{Issue: taskIssue{
			Key:         issue.Key,
			Summary:     issue.Summary,
			Description: issue.DescriptionText,
			Status:      issue.Status,
			IssueType:   issue.IssueType,
			Priority:    issue.Priority,
			Assignee:    issue.AssigneeDisplayName,
			Reporter:    issue.ReporterDisplayName,
			SprintName:  issue.SprintName,
			UpdatedAt:   issue.UpdatedAt,
		}}
		people := newPersonSet()
		people.add(issue.AssigneeDisplayName)
		people.add(issue.ReporterDisplayName)

		out.Comments, out.Notes = collectTaskComments(database, key, people, out.Notes)
		out.Threads, out.Notes = collectTaskThreads(database, key, people, out.Notes)
		out.Meetings, out.Notes = collectTaskMeetings(database, key, out.Notes)
		out.Decisions, out.Notes = collectTaskDecisions(database, key, out.Notes)
		out.People = people.list()

		return jsonResult(out)
	})
}
```

Then write the four `collect…` helpers in the same file. Each returns its section plus an appended note, and **degrades rather than fails** — a source that errors adds a note like `"jira comments unavailable: <err>"` and leaves the section empty, because a dossier missing one source is still worth having:

```go
func collectTaskComments(database *db.DB, key string, people *personSet, notes []string) ([]taskComment, []string) {
	rows, err := database.GetJiraCommentsByIssueKey(key, taskContextMaxComments)
	if err != nil {
		return nil, append(notes, "jira comments unavailable: "+err.Error())
	}
	out := make([]taskComment, 0, len(rows))
	for _, c := range rows {
		people.add(c.Author)
		out = append(out, taskComment{Author: c.Author, Body: c.BodyText, UpdatedAt: c.UpdatedAt})
	}
	if len(out) == 0 {
		return nil, notes
	}
	return out, notes
}

func collectTaskThreads(database *db.DB, key string, people *personSet, notes []string) ([]taskThread, []string) {
	links, err := database.GetJiraSlackLinksByIssue(key)
	if err != nil {
		return nil, append(notes, "linked slack threads unavailable: "+err.Error())
	}
	var out []taskThread
	seen := map[string]bool{}
	for _, l := range links {
		if len(out) >= taskContextMaxThreads {
			break
		}
		// link_type 'track'/'decision' rows carry no message_ts — nothing to
		// resolve to a thread, so they contribute no conversation here.
		if l.ChannelID == "" || l.MessageTS == "" {
			continue
		}
		anchors, err := database.GetMessagesByTS(l.ChannelID, []string{l.MessageTS})
		if err != nil || len(anchors) == 0 {
			continue
		}
		anchor := anchors[0]
		threadTS := anchor.ThreadTS
		if threadTS == "" {
			threadTS = anchor.TS
		}
		dedupeKey := l.ChannelID + "|" + threadTS
		if seen[dedupeKey] {
			continue
		}
		seen[dedupeKey] = true

		msgs := []db.Message{anchor}
		replies, err := database.GetThreadReplies(l.ChannelID, threadTS)
		if err == nil {
			msgs = append(msgs, replies...)
		}
		if len(msgs) > taskContextMaxReplies {
			msgs = msgs[:taskContextMaxReplies]
		}

		thread := taskThread{ChannelID: l.ChannelID}
		if ch, err := database.GetChannelByID(l.ChannelID); err == nil && ch != nil {
			thread.ChannelName = ch.Name
		}
		for _, m := range msgs {
			name, err := database.UserNameByID(m.UserID)
			if err != nil || name == "" {
				name = m.UserID
			}
			people.add(name)
			thread.Messages = append(thread.Messages, taskMessage{
				Sender: name, Text: m.Text, TS: m.TS, Permalink: m.Permalink,
			})
		}
		out = append(out, thread)
	}
	return out, notes
}

func collectTaskMeetings(database *db.DB, key string, notes []string) ([]taskMeeting, []string) {
	hits, err := database.SearchTranscripts(key, taskContextMaxMeetings)
	if err != nil {
		return nil, append(notes, "meeting search unavailable: "+err.Error())
	}
	out := make([]taskMeeting, 0, len(hits))
	for _, h := range hits {
		out = append(out, taskMeeting{
			TranscriptID: h.ID, Title: h.Title, CreatedAt: h.CreatedAt, Snippet: h.Snippet,
		})
	}
	if len(out) == 0 {
		return nil, notes
	}
	return out, notes
}

func collectTaskDecisions(database *db.DB, key string, notes []string) ([]taskDecision, []string) {
	// idea_mentions stores a bare issue key as the ref for source='jira'
	// (internal/prompts/defaults.go:1701), and (source, ref) is indexed — so
	// this is an exact lookup, not a search.
	ideas, err := database.ListIdeas(db.IdeaFilter{Limit: 200})
	if err != nil {
		return nil, append(notes, "registry unavailable: "+err.Error())
	}
	var out []taskDecision
	for i := range ideas {
		if len(out) >= taskContextMaxIdeas {
			break
		}
		mentions, err := database.ListIdeaMentions(ideas[i].ID)
		if err != nil {
			continue
		}
		for _, m := range mentions {
			if m.Source == "jira" && strings.EqualFold(m.Ref, key) {
				out = append(out, taskDecision{
					ID: ideas[i].ID, Kind: ideas[i].Kind, Title: ideas[i].Title,
					Essence: ideas[i].Essence, Status: ideas[i].Status,
				})
				break
			}
		}
	}
	if len(out) == 0 {
		return nil, notes
	}
	return out, notes
}

// personSet collects display names in first-seen order without duplicates.
type personSet struct {
	seen  map[string]bool
	order []string
}

func newPersonSet() *personSet { return &personSet{seen: map[string]bool{}} }

func (p *personSet) add(name string) {
	name = strings.TrimSpace(name)
	if name == "" || p.seen[name] {
		return
	}
	p.seen[name] = true
	p.order = append(p.order, name)
}

func (p *personSet) list() []string { return p.order }
```

Register in `NewServer`: `registerTaskContext(srv.s, database)`.

Verify every db signature used here against the real code before writing (`GetMessagesByTS`, `GetThreadReplies`, `GetChannelByID`, `UserNameByID`, `ListIdeas`, `ListIdeaMentions`, and the `db.JiraIssue` field names) — the plan names them from `internal/db`, but confirm the exact types.

- [ ] **Step 4: Run tests to verify they pass**

```bash
go test ./internal/mcp/ -run TestGetTaskContext -v > /tmp/t6.log 2>&1; echo "exit=$?"
```

Expected: PASS, all three tests.

- [ ] **Step 5: Add the ref-scan note to the decisions collector**

`collectTaskDecisions` scans up to 200 ideas and their mentions. That is acceptable for a registry of this size, but it is an N+1 read. Add a comment stating the bound explicitly so the next reader knows it is deliberate and where the ceiling is:

```go
// Bounded N+1: at most 200 ideas × their mentions. The registry is
// owner-triaged and small; if it ever grows, replace this with a single
// join over idea_mentions(source, ref) — the index already exists.
```

- [ ] **Step 6: Commit**

```bash
git add internal/mcp/taskcontext.go internal/mcp/taskcontext_test.go internal/mcp/server.go
git commit -m "feat(mcp): get_task_context assembles the dossier a ticket lacks

Issue + comments, the Slack threads it was discussed in (resolved from the
linked message to the whole thread), meetings that mentioned the key,
recorded decisions, and the people involved. Empty sections are omitted;
a failing source degrades to a note instead of failing the dossier."
```

---

## Task 7: `find_experts` — who to go to

**Files:**
- Create: `internal/mcp/experts.go`
- Modify: `internal/mcp/server.go` (`registerExperts(srv.s, database)`)
- Test: `internal/mcp/experts_test.go`

**Interfaces:**
- Consumes: `db.SearchMessages`, `db.GetJiraIssueByKey`, `db.GetJiraCommentsByIssueKey` (Task 4), `db.GetJiraSlackLinksByIssue`, `db.GetThreadReplies`, `db.GetUserByEmail`, `db.GetUserByID`, `db.GetLatestPeopleCard`, `db.GetJiraUserMapByAccountID`.
- Produces: MCP tool `find_experts` (args `topic`, `issue_key`, `emails`, `limit`).

- [ ] **Step 1: Write the failing test**

Create `internal/mcp/experts_test.go`:

```go
package mcp

import (
	"context"
	"encoding/json"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"
)

type expertsEnvelope struct {
	Candidates []struct {
		UserID   string `json:"user_id"`
		Name     string `json:"name"`
		Score    float64 `json:"score"`
		Evidence []struct {
			Kind     string `json:"kind"`
			Detail   string `json:"detail"`
			Count    int    `json:"count"`
			LastSeen string `json:"last_seen"`
			Ref      string `json:"ref"`
		} `json:"evidence"`
	} `json:"candidates"`
	Weights   map[string]float64 `json:"weights"`
	Unmatched []string           `json:"unmatched_emails,omitempty"`
}

func TestFindExpertsRanksByEvidenceAndAlwaysCitesIt(t *testing.T) {
	database := seedDB(t)
	seedExpertsFixture(t, database) // petya: 3 messages on "payments"; anya: 1
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "find_experts",
		Arguments: map[string]any{"topic": "payments"},
	})
	if err != nil {
		t.Fatalf("calling find_experts: %v", err)
	}
	if res.IsError {
		t.Fatalf("tool error: %s", textContent(t, res))
	}

	var env expertsEnvelope
	if err := json.Unmarshal([]byte(textContent(t, res)), &env); err != nil {
		t.Fatalf("decoding result: %v", err)
	}
	if len(env.Candidates) < 2 {
		t.Fatalf("expected both candidates, got %d", len(env.Candidates))
	}
	if env.Candidates[0].Name != "petya" {
		t.Fatalf("expected the heavier contributor first, got %s", env.Candidates[0].Name)
	}
	// DEV-03: every candidate carries evidence with a resolvable ref.
	for _, c := range env.Candidates {
		if len(c.Evidence) == 0 {
			t.Fatalf("candidate %s has no evidence", c.Name)
		}
		for _, e := range c.Evidence {
			if e.Ref == "" {
				t.Fatalf("candidate %s has evidence with no ref: %+v", c.Name, e)
			}
		}
	}
	// DEV-03: the weights that produced the order ship with the answer.
	if len(env.Weights) == 0 {
		t.Fatalf("ranking weights must ship with the response")
	}
}

func TestFindExpertsReportsUnmatchedEmails(t *testing.T) {
	database := seedDB(t)
	seedExpertsFixture(t, database)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name: "find_experts",
		Arguments: map[string]any{
			"emails": []string{"PETYA@Example.COM", "ghost@nowhere.invalid"},
		},
	})
	if err != nil {
		t.Fatalf("calling find_experts: %v", err)
	}
	var env expertsEnvelope
	if err := json.Unmarshal([]byte(textContent(t, res)), &env); err != nil {
		t.Fatalf("decoding result: %v", err)
	}
	// Case-folded match: the mixed-case address resolves to the seeded user.
	if len(env.Candidates) != 1 || env.Candidates[0].Name != "petya" {
		t.Fatalf("expected the case-folded email to match petya, got %+v", env.Candidates)
	}
	// The unmatchable address is reported, never silently dropped.
	if len(env.Unmatched) != 1 || env.Unmatched[0] != "ghost@nowhere.invalid" {
		t.Fatalf("expected the unmatched email reported, got %+v", env.Unmatched)
	}
}

func TestFindExpertsRequiresAnInput(t *testing.T) {
	database := seedDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "find_experts",
		Arguments: map[string]any{},
	})
	if err != nil {
		t.Fatalf("calling find_experts: %v", err)
	}
	if !res.IsError {
		t.Fatalf("a call with no topic/issue_key/emails must be a soft error")
	}
}
```

`seedExpertsFixture` inserts: a `channels` row (`1:C1`, name `payments`); two `users` rows (`1:U1` name `petya` email `petya@example.com`; `1:U2` name `anya` email `anya@example.com`); four `messages` rows whose text contains `payments` — three by `1:U1`, one by `1:U2`, each with a distinct `ts`/`ts_unix`. Read the `messages` table's NOT NULL columns from `internal/db/schema.sql` before writing the inserts, and let the FTS triggers index them (insert into `messages`, never into `messages_fts` directly).

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/mcp/ -run TestFindExperts -v > /tmp/t7.log 2>&1; echo "exit=$?"
```

Expected: FAIL — tool `find_experts` not found.

- [ ] **Step 3: Implement**

Create `internal/mcp/experts.go`:

```go
package mcp

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

// Ranking weights, shipped verbatim in every response (DEV-03) so the caller
// can explain the order rather than trust it.
var expertWeights = map[string]float64{
	"messages": 1.0,
	"thread":   1.5,
	"jira":     2.0,
	"code":     2.5,
}

// expertRecencyHalfLifeDays decays evidence: a conversation from last week
// says more about who is in it now than one from last spring.
const expertRecencyHalfLifeDays = 45.0

const expertMessageScanLimit = 200

type findExpertsArgs struct {
	Topic    string   `json:"topic,omitempty" jsonschema:"free-text subject, e.g. 'payment retries'"`
	IssueKey string   `json:"issue_key,omitempty" jsonschema:"Jira issue key to find the people around"`
	Emails   []string `json:"emails,omitempty" jsonschema:"email addresses (e.g. git commit authors) to resolve to people"`
	Limit    int      `json:"limit,omitempty" jsonschema:"max candidates, 0 = default (10)"`
}

// expertEvidence is one countable, referenced reason a person is a candidate.
// It never asserts expertise — it states what happened, with a ref.
type expertEvidence struct {
	Kind     string `json:"kind"`
	Detail   string `json:"detail"`
	Count    int    `json:"count"`
	LastSeen string `json:"last_seen,omitempty"`
	Ref      string `json:"ref"`
}

type expertCandidate struct {
	UserID string  `json:"user_id"`
	Name   string  `json:"name"`
	Email  string  `json:"email,omitempty"`
	Score  float64 `json:"score"`

	Evidence []expertEvidence `json:"evidence"`

	// Straight from the person's people card: who decides, and how to
	// approach them. Absent when the person has no card yet.
	DecisionRole       string `json:"decision_role,omitempty"`
	CommunicationGuide string `json:"communication_guide,omitempty"`
	CommunicationStyle string `json:"communication_style,omitempty"`
	ActiveHours        string `json:"active_hours,omitempty"`
}

type expertsResult struct {
	Candidates      []expertCandidate  `json:"candidates"`
	Weights         map[string]float64 `json:"weights"`
	RecencyHalfLife string             `json:"recency_half_life"`
	UnmatchedEmails []string           `json:"unmatched_emails,omitempty"`
	Notes           []string           `json:"notes,omitempty"`
}

func registerExperts(s *mcpsdk.Server, database *db.DB) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name: "find_experts",
		Description: "Find who to go to about a topic, a Jira issue, or a set of email addresses " +
			"(e.g. git commit authors). Returns ranked candidates with the evidence behind each " +
			"one — messages, thread participation, Jira roles — plus their decision role and " +
			"communication guide where known. Evidence, not verdicts: judge it yourself.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args findExpertsArgs) (*mcpsdk.CallToolResult, any, error) {
		if args.Topic == "" && args.IssueKey == "" && len(args.Emails) == 0 {
			return errResult("provide one of: topic, issue_key, emails"), nil, nil
		}
		limit := args.Limit
		if limit <= 0 {
			limit = 10
		}

		acc := newExpertAccumulator()
		result := expertsResult{
			Weights:         expertWeights,
			RecencyHalfLife: fmt.Sprintf("%.0f days", expertRecencyHalfLifeDays),
		}

		if args.Topic != "" {
			result.Notes = collectMessageEvidence(database, args.Topic, acc, result.Notes)
		}
		if args.IssueKey != "" {
			result.Notes = collectIssueEvidence(database, args.IssueKey, acc, result.Notes)
			result.Notes = collectLinkedThreadEvidence(database, args.IssueKey, acc, result.Notes)
		}
		if len(args.Emails) > 0 {
			result.UnmatchedEmails = collectCodeEvidence(database, args.Emails, acc)
		}

		result.Candidates = acc.rank(database, limit)
		return jsonResult(result)
	})
}
```

Then the accumulator and collectors in the same file:

```go
// expertAccumulator groups evidence by user id and computes the weighted,
// recency-decayed score.
type expertAccumulator struct {
	byUser map[string]*expertCandidate
	scores map[string]float64
}

func newExpertAccumulator() *expertAccumulator {
	return &expertAccumulator{byUser: map[string]*expertCandidate{}, scores: map[string]float64{}}
}

// add records one evidence entry for a user. tsUnix is the evidence's time
// (0 = unknown, which scores as fully decayed-neutral: weight × 1).
func (a *expertAccumulator) add(userID string, e expertEvidence, tsUnix float64) {
	if userID == "" {
		return
	}
	c, ok := a.byUser[userID]
	if !ok {
		c = &expertCandidate{UserID: userID}
		a.byUser[userID] = c
	}
	c.Evidence = append(c.Evidence, e)

	decay := 1.0
	if tsUnix > 0 {
		ageDays := time.Since(time.Unix(int64(tsUnix), 0)).Hours() / 24
		if ageDays > 0 {
			decay = math.Pow(0.5, ageDays/expertRecencyHalfLifeDays)
		}
	}
	a.scores[userID] += expertWeights[e.Kind] * float64(max(e.Count, 1)) * decay
}

// rank resolves names and people-card enrichments, then orders by score.
func (a *expertAccumulator) rank(database *db.DB, limit int) []expertCandidate {
	out := make([]expertCandidate, 0, len(a.byUser))
	for id, c := range a.byUser {
		c.Score = a.scores[id]
		if u, err := database.GetUserByID(id); err == nil && u != nil {
			c.Name = u.Name
			c.Email = u.Email
		}
		if c.Name == "" {
			c.Name = id
		}
		if card, err := database.GetLatestPeopleCard(id); err == nil && card != nil {
			c.DecisionRole = card.DecisionRole
			c.CommunicationGuide = card.CommunicationGuide
			c.CommunicationStyle = card.CommunicationStyle
			c.ActiveHours = card.ActiveHoursJSON
		}
		out = append(out, *c)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Score > out[j].Score })
	if len(out) > limit {
		out = out[:limit]
	}
	return out
}

func collectMessageEvidence(database *db.DB, topic string, acc *expertAccumulator, notes []string) []string {
	msgs, err := database.SearchMessages(topic, db.SearchOpts{Limit: expertMessageScanLimit})
	if err != nil {
		return append(notes, "message search unavailable: "+err.Error())
	}
	type agg struct {
		count   int
		lastTS  string
		lastTSU float64
		channel string
	}
	byUser := map[string]*agg{}
	for _, m := range msgs {
		if m.UserID == "" {
			continue
		}
		a, ok := byUser[m.UserID]
		if !ok {
			a = &agg{}
			byUser[m.UserID] = a
		}
		a.count++
		if m.TSUnix > a.lastTSU {
			a.lastTSU, a.lastTS, a.channel = m.TSUnix, m.TS, m.ChannelID
		}
	}
	for userID, a := range byUser {
		channelName := a.channel
		if ch, err := database.GetChannelByID(a.channel); err == nil && ch != nil {
			channelName = "#" + ch.Name
		}
		acc.add(userID, expertEvidence{
			Kind:     "messages",
			Detail:   fmt.Sprintf("%d messages matching %q, most recently in %s", a.count, topic, channelName),
			Count:    a.count,
			LastSeen: time.Unix(int64(a.lastTSU), 0).UTC().Format("2006-01-02"),
			Ref:      a.channel + "|" + a.lastTS,
		}, a.lastTSU)
	}
	if len(msgs) == expertMessageScanLimit {
		notes = append(notes, fmt.Sprintf(
			"message evidence capped at the %d most relevant matches", expertMessageScanLimit))
	}
	return notes
}

func collectIssueEvidence(database *db.DB, key string, acc *expertAccumulator, notes []string) []string {
	issue, err := database.GetJiraIssueByKey(key)
	if err != nil {
		return append(notes, "issue lookup unavailable: "+err.Error())
	}
	if issue == nil {
		return append(notes, "no issue with key "+key)
	}
	if issue.AssigneeSlackID != "" {
		acc.add(issue.AssigneeSlackID, expertEvidence{
			Kind: "jira", Detail: "assignee of " + key, Count: 1, Ref: key,
		}, 0)
	}
	if issue.ReporterSlackID != "" {
		acc.add(issue.ReporterSlackID, expertEvidence{
			Kind: "jira", Detail: "reporter of " + key, Count: 1, Ref: key,
		}, 0)
	}

	comments, err := database.GetJiraCommentsByIssueKey(key, 100)
	if err != nil {
		return append(notes, "issue comments unavailable: "+err.Error())
	}
	byAuthor := map[string]int{}
	for _, c := range comments {
		if c.AuthorAccountID == "" {
			continue
		}
		byAuthor[c.AuthorAccountID]++
	}
	for atlassianID, n := range byAuthor {
		m, err := database.GetJiraUserMapByAccountID(atlassianID)
		if err != nil || m == nil || m.SlackUserID == "" {
			continue
		}
		acc.add(m.SlackUserID, expertEvidence{
			Kind:   "jira",
			Detail: fmt.Sprintf("%d comments on %s", n, key),
			Count:  n,
			Ref:    key,
		}, 0)
	}
	return notes
}

func collectLinkedThreadEvidence(database *db.DB, key string, acc *expertAccumulator, notes []string) []string {
	links, err := database.GetJiraSlackLinksByIssue(key)
	if err != nil {
		return append(notes, "linked threads unavailable: "+err.Error())
	}
	seen := map[string]bool{}
	for _, l := range links {
		if l.ChannelID == "" || l.MessageTS == "" {
			continue
		}
		anchors, err := database.GetMessagesByTS(l.ChannelID, []string{l.MessageTS})
		if err != nil || len(anchors) == 0 {
			continue
		}
		threadTS := anchors[0].ThreadTS
		if threadTS == "" {
			threadTS = anchors[0].TS
		}
		if seen[l.ChannelID+"|"+threadTS] {
			continue
		}
		seen[l.ChannelID+"|"+threadTS] = true

		msgs := append([]db.Message{anchors[0]}, mustReplies(database, l.ChannelID, threadTS)...)
		byUser := map[string]int{}
		latest := map[string]float64{}
		for _, m := range msgs {
			if m.UserID == "" {
				continue
			}
			byUser[m.UserID]++
			if m.TSUnix > latest[m.UserID] {
				latest[m.UserID] = m.TSUnix
			}
		}
		for userID, n := range byUser {
			acc.add(userID, expertEvidence{
				Kind:     "thread",
				Detail:   fmt.Sprintf("%d messages in the thread discussing %s", n, key),
				Count:    n,
				LastSeen: time.Unix(int64(latest[userID]), 0).UTC().Format("2006-01-02"),
				Ref:      l.ChannelID + "|" + threadTS,
			}, latest[userID])
		}
	}
	return notes
}

// mustReplies returns thread replies, treating a read failure as "no replies"
// — the anchor message alone is still usable evidence.
func mustReplies(database *db.DB, channelID, threadTS string) []db.Message {
	replies, err := database.GetThreadReplies(channelID, threadTS)
	if err != nil {
		return nil
	}
	return replies
}

// collectCodeEvidence resolves email addresses (typically git commit authors)
// to people. Matching is case-folded because git authorship carries mixed
// case; an address that resolves to nobody is RETURNED as unmatched, never
// dropped, so the caller can see the code signal was incomplete.
func collectCodeEvidence(database *db.DB, emails []string, acc *expertAccumulator) []string {
	var unmatched []string
	for _, raw := range emails {
		email := strings.ToLower(strings.TrimSpace(raw))
		if email == "" {
			continue
		}
		userID := ""
		if u, err := database.GetUserByEmailFold(email); err == nil && u != nil {
			userID = u.ID
		}
		if userID == "" {
			if id, err := database.GetSlackUserIDByEmail(email); err == nil && id != "" {
				userID = id
			}
		}
		if userID == "" {
			unmatched = append(unmatched, raw)
			continue
		}
		acc.add(userID, expertEvidence{
			Kind: "code", Detail: "authored code as " + email, Count: 1, Ref: email,
		}, 0)
	}
	return unmatched
}
```

Add `"math"` to the imports. **`GetUserByEmail` is an exact, case-sensitive match** — to make the case-folded lookup real, either add a `LOWER(email) = LOWER(?)` variant in `internal/db/users.go` or lower-case both sides in a new small query. Do the former: add

```go
// GetUserByEmailFold matches an email case-insensitively. Git authorship and
// directory data disagree about case constantly; GetUserByEmail's exact match
// is right for synced Slack data and wrong for anything a human typed.
func (db *DB) GetUserByEmailFold(email string) (*User, error)
```

next to `GetUserByEmail` (`internal/db/users.go:102`), with a matching test in `internal/db/users_test.go`, and call it from `collectCodeEvidence`.

Register in `NewServer`: `registerExperts(srv.s, database)`.

- [ ] **Step 4: Run tests to verify they pass**

```bash
go test ./internal/mcp/ -run TestFindExperts -v > /tmp/t7.log 2>&1; echo "exit=$?"
go test ./internal/db/ -run TestGetUserByEmailFold -v >> /tmp/t7.log 2>&1; echo "exit=$?"
```

Expected: PASS.

- [ ] **Step 5: Run the whole backend suite and vet**

```bash
gofmt -l ./cmd ./internal > /tmp/fmt.log 2>&1; echo "gofmt files: $(wc -l < /tmp/fmt.log)"
go vet ./... > /tmp/vet.log 2>&1; echo "vet exit=$?"
go test ./... > /tmp/all.log 2>&1; echo "test exit=$?"
```

Expected: gofmt lists nothing, vet exit 0, tests exit 0.

- [ ] **Step 6: Commit**

```bash
git add internal/mcp/experts.go internal/mcp/experts_test.go internal/mcp/server.go internal/db/users.go internal/db/users_test.go
git commit -m "feat(mcp): find_experts answers 'who do I go to' with evidence

Ranks candidates from message, thread, Jira and git-author signals, each
entry countable and referenced, with the ranking weights shipped in the
response. Enriched with decision role and communication guide from people
cards. Unmatched git emails are reported, never silently dropped."
```

---

## Task 8: The skill pack — content and embedding

**Files:**
- Create: `internal/devpack/skills/watchtower-task-context/SKILL.md`
- Create: `internal/devpack/skills/watchtower-who-to-ask/SKILL.md`
- Create: `internal/devpack/skills/watchtower-whats-changed/SKILL.md`
- Create: `internal/devpack/skills/watchtower-why-decision/SKILL.md`
- Create: `internal/devpack/pack.go`
- Test: `internal/devpack/pack_test.go`

**Interfaces:**
- Consumes: nothing (markdown + embed).
- Produces:
  ```go
  type Skill struct {
      Name    string // directory name, e.g. "watchtower-who-to-ask"
      Content string // full SKILL.md text
      SHA256  string // hex digest of Content
  }
  func Skills() []Skill        // sorted by Name
  const MarkerKey = "x-watchtower-pack"
  ```

- [ ] **Step 1: Write the failing test**

Create `internal/devpack/pack_test.go`:

```go
package devpack

import (
	"strings"
	"testing"
)

func TestSkillsShipWithValidFrontmatter(t *testing.T) {
	skills := Skills()
	if len(skills) != 4 {
		t.Fatalf("expected 4 skills, got %d", len(skills))
	}
	want := map[string]bool{
		"watchtower-task-context":  true,
		"watchtower-who-to-ask":    true,
		"watchtower-whats-changed": true,
		"watchtower-why-decision":  true,
	}
	for _, s := range skills {
		if !want[s.Name] {
			t.Fatalf("unexpected skill %q", s.Name)
		}
		if !strings.HasPrefix(s.Content, "---\n") {
			t.Fatalf("%s: SKILL.md must open with YAML frontmatter", s.Name)
		}
		for _, field := range []string{"name:", "description:", MarkerKey + ":"} {
			if !strings.Contains(s.Content, field) {
				t.Fatalf("%s: frontmatter missing %q", s.Name, field)
			}
		}
		if !strings.Contains(s.Content, "name: "+s.Name) {
			t.Fatalf("%s: frontmatter name must match the directory name", s.Name)
		}
		if len(s.SHA256) != 64 {
			t.Fatalf("%s: expected a hex sha256, got %q", s.Name, s.SHA256)
		}
	}
}

func TestSkillsAreSortedAndStable(t *testing.T) {
	a, b := Skills(), Skills()
	for i := range a {
		if a[i].SHA256 != b[i].SHA256 || a[i].Name != b[i].Name {
			t.Fatalf("Skills() is not deterministic at index %d", i)
		}
		if i > 0 && a[i-1].Name >= a[i].Name {
			t.Fatalf("Skills() must be sorted by name")
		}
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/devpack/ -v > /tmp/t8.log 2>&1; echo "exit=$?"
```

Expected: FAIL — package does not exist.

- [ ] **Step 3: Write the four skill files**

`internal/devpack/skills/watchtower-task-context/SKILL.md`:

```markdown
---
name: watchtower-task-context
description: Use when starting work on a ticket, when the user names a Jira key ("I'm picking up PROJ-123"), or before planning an implementation for a keyed task — pulls the context the ticket text does not carry.
x-watchtower-pack: v1
---

# Task Context (Watchtower)

A ticket says *what* in three lines. The *why*, the constraints agreed in a thread, the decision made on a call, the caveat someone dropped in a channel — none of that is in the ticket. Watchtower has it.

## Steps

1. Call `get_task_context` with the issue key. One call returns the issue and its comments, the Slack threads where it was discussed, meetings that mentioned it, recorded decisions, and the people involved.
2. Read the whole dossier before summarising. The value is usually in the threads, not the ticket body.
3. Present, in this order:
   - **What changed since the ticket was written.** Anything in a thread, comment, or meeting that contradicts or narrows the ticket text. Lead with this — it is the highest-value content and the easiest to bury.
   - **What is actually being asked**, as the latest material defines it.
   - **Decisions already made** that constrain the approach, with who made them and where.
   - **Open questions** nobody answered. Say plainly that they are unanswered.
   - **Who owns what** — assignee, reporter, and the people active in the discussion.
4. If a section is absent from the dossier, say nothing about it. An absent section means no material was found, not that it was checked and empty.

## Rules

- Never present ticket text and thread material as one voice. Attribute: "the ticket says X, but Petya narrowed it in #payments on Aug 3".
- If the dossier's `notes` field reports a source was unavailable, surface that — the dev must know the picture is partial.
- Do not start implementing off the dossier unless asked. Report, then wait.
```

`internal/devpack/skills/watchtower-who-to-ask/SKILL.md`:

```markdown
---
name: watchtower-who-to-ask
description: Use when the user is blocked, does not know who owns a subsystem, asks "who knows about X" or "who do I ask", or is about to guess at unfamiliar code — finds who knows, who decides, and how to approach them.
x-watchtower-pack: v1
---

# Who To Ask (Watchtower)

"I don't know who to go to" is an information problem *and* a social one. Answer both.

## Steps

1. **Work out what kind of question it is.**
   - About a file or a piece of code → run `git log --format='%ae' -20 -- <path>` (and `git blame` where a specific region matters) to collect author emails, then call `find_experts` with `emails: [...]`.
   - About a topic → call `find_experts` with `topic: "..."`.
   - About a ticket → call `find_experts` with `issue_key: "PROJ-123"`.
   - You may combine inputs in one call when the question spans them.
2. Read the `evidence` on each candidate and the `weights` that ordered them. If the ordering does not match the evidence you would weigh, say so and reorder — the weights are a default, not an authority.
3. Expand the top candidates with `get_person` when you need more on how to approach them.

## Present three answers, never one

1. **Who knows.** Cite the evidence. Weight conversational signal alongside authorship: the person who wrote the code two years ago may have left the team; the person arguing about it last week is in it.
2. **Who decides.** From `decision_role` on the candidate, the Jira assignee, and track ownership. Asking the knower when you needed the decider is a common and expensive mistake — call it out explicitly when they are different people.
3. **How to approach.** Channel versus DM, their observed active hours, and the `communication_guide` / `communication_style` from their people card. Phrase this as what tends to work with this person, not as instructions about them.

## Rules

- Never assert expertise the evidence does not support. "Three messages six months ago" is a weak signal — say so rather than promoting them.
- If `unmatched_emails` comes back non-empty, report it: those authors could not be resolved to people, so the code signal is incomplete.
- `active_hours` is *observed activity*, not a calendar. Never present it as free/busy.
- If nothing scores well, say the honest thing: nobody in the data clearly owns this, and suggest the channel where the topic lives instead.
```

`internal/devpack/skills/watchtower-whats-changed/SKILL.md`:

```markdown
---
name: watchtower-whats-changed
description: Use when returning to work after a break, before continuing long-running work, at the end of a long agent-driven session, or when the user asks whether anything changed while they were heads-down.
x-watchtower-pack: v1
---

# What Changed (Watchtower)

Deep in the tunnel, the ground moves: requirements change, someone else solves it, the approach gets vetoed on a call. This surfaces only what would change what the dev is doing right now.

## Steps

1. Call `list_situations` with `status: "open"` and, when the dev has been heads-down for a known stretch, `since` set to roughly when they went in.
2. Work out what they are currently doing: the git branch name, recent commits, the working directory, the current conversation. If a Jira key is inferable (branch names usually carry one), call `get_task_context` for it.
3. Expand only the situations that plausibly touch the current work — use `get_situation` for those, not for all of them.

## Present

- **Lead with anything that would change the current approach.** That is the only reason this skill exists.
- Then, at most a handful of one-line mentions of everything else open. Do not expand them.
- Then stop. Do not list every situation, do not summarise the week.

## Rules

- Relevance beats completeness here. A noisy answer trains the dev to stop asking, and then the skill is worth nothing.
- If nothing is relevant, say exactly that in one line. "Nothing that touches what you're on" is a good answer, not a failure.
- Never present a situation as urgent because its priority field says `high`. Judge against what the dev is doing.
```

`internal/devpack/skills/watchtower-why-decision/SKILL.md`:

```markdown
---
name: watchtower-why-decision
description: Use when asking why something is built the way it is, doing archaeology on a constraint, revisiting a design choice, or before "cleaning up" code that looks wrong — finds the decision and its provenance.
x-watchtower-pack: v1
---

# Why This Decision (Watchtower)

Code that looks wrong is often code that was argued about. Find the argument before changing the code.

## Steps

1. Call `list_ideas` with `kind: "decision"` and a `query` naming the subject — the registry searches mention quotes, not just titles. Expand promising hits with `get_idea` to get the mention trail.
2. Call `memory_recall` for the same subject — the memory vault holds beliefs and episodes the registry does not.
3. Call `list_messages` with a `query` for the original discussion.
4. Search meeting material for the subject, and pull the full text with `get_transcript` when a hit looks load-bearing.

## Present

For each decision found:

- **What was decided**, in one sentence.
- **Who decided it, where, and when** — the provenance, always. A message ref, a meeting, a ticket.
- **What the alternative was**, if the material says.
- **What has happened since** that might have invalidated it.

## Rules

- **Every claim carries provenance.** An unprovenanced "we decided X" is worse than no answer, because it will be believed and repeated.
- Distinguish a *recorded decision* from *someone's opinion in a thread*. Both are useful; conflating them is not.
- If nothing is found, say so plainly. Do not reconstruct a plausible rationale from the code — that is invention, and it is exactly what this skill exists to prevent.
- When the dev is about to change something and you found a decision that covers it, lead with the decision.
```

- [ ] **Step 4: Write the embed**

Create `internal/devpack/pack.go`:

```go
// Package devpack ships the Watchtower skill pack: markdown skills that teach
// a developer's coding agent how to use Watchtower's MCP tools. The files are
// embedded in the binary so `watchtower integrate` can install them without a
// network fetch or a second artifact to keep in sync.
package devpack

import (
	"crypto/sha256"
	"embed"
	"encoding/hex"
	"io/fs"
	"path"
	"sort"
	"strings"
)

//go:embed skills/*/SKILL.md
var skillFS embed.FS

// MarkerKey is the frontmatter key stamped on every shipped skill. The
// installer removes or rewrites ONLY files carrying it (DEV-04), so a file a
// user wrote by hand in the same directory is never touched.
const MarkerKey = "x-watchtower-pack"

// Skill is one shipped skill: its directory name, its full SKILL.md text, and
// the digest the installer compares against to detect user edits.
type Skill struct {
	Name    string
	Content string
	SHA256  string
}

// Skills returns the embedded pack, sorted by name. The result is stable
// across calls — the installer's drift detection depends on it.
func Skills() []Skill {
	entries, err := fs.ReadDir(skillFS, "skills")
	if err != nil {
		// An embed failure is a build-time defect, not a runtime condition.
		panic("devpack: reading embedded skills: " + err.Error())
	}
	out := make([]Skill, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		b, err := skillFS.ReadFile(path.Join("skills", e.Name(), "SKILL.md"))
		if err != nil {
			panic("devpack: reading " + e.Name() + ": " + err.Error())
		}
		content := string(b)
		sum := sha256.Sum256([]byte(content))
		out = append(out, Skill{
			Name:    e.Name(),
			Content: content,
			SHA256:  hex.EncodeToString(sum[:]),
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// HasMarker reports whether content carries the pack marker, i.e. whether the
// installer is allowed to touch the file at all.
func HasMarker(content string) bool {
	return strings.Contains(content, MarkerKey+":")
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
go test ./internal/devpack/ -v > /tmp/t8.log 2>&1; echo "exit=$?"
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/devpack/
git commit -m "feat(devpack): embed the Watchtower skill pack

Four skills teaching a coding agent how to use the MCP surface: task
dossiers, who-to-ask routing, what-changed catch-up, and decision
archaeology. Each carries the x-watchtower-pack marker the installer keys
on so user-authored files are never touched."
```

---

## Task 9: Installer — install, status, remove

**Files:**
- Create: `internal/devpack/install.go`
- Test: `internal/devpack/install_test.go`

**Interfaces:**
- Consumes: `Skills()`, `HasMarker`, `MarkerKey` (Task 8).
- Produces:
  ```go
  type State string // "installed" | "updated" | "unchanged" | "drifted" | "missing" | "foreign"
  type SkillStatus struct {
      Name  string
      State State
      Path  string
  }
  func Install(skillsDir string) ([]SkillStatus, error)
  func Status(skillsDir string) ([]SkillStatus, error)
  func Remove(skillsDir string) ([]SkillStatus, error)
  ```

- [ ] **Step 1: Write the failing test**

Create `internal/devpack/install_test.go`:

```go
package devpack

import (
	"os"
	"path/filepath"
	"testing"
)

func TestInstallWritesThePackAndIsIdempotent(t *testing.T) {
	dir := t.TempDir()

	first, err := Install(dir)
	if err != nil {
		t.Fatalf("install: %v", err)
	}
	if len(first) != len(Skills()) {
		t.Fatalf("expected a status per skill, got %d", len(first))
	}
	for _, s := range first {
		if s.State != StateInstalled {
			t.Fatalf("%s: expected installed on a fresh dir, got %s", s.Name, s.State)
		}
		if _, err := os.Stat(s.Path); err != nil {
			t.Fatalf("%s: file not written: %v", s.Name, err)
		}
	}

	second, err := Install(dir)
	if err != nil {
		t.Fatalf("reinstall: %v", err)
	}
	for _, s := range second {
		if s.State != StateUnchanged {
			t.Fatalf("%s: re-running install must be a no-op, got %s", s.Name, s.State)
		}
	}
}

func TestInstallNeverClobbersAUserEditedSkill(t *testing.T) {
	dir := t.TempDir()
	if _, err := Install(dir); err != nil {
		t.Fatalf("install: %v", err)
	}

	target := filepath.Join(dir, "watchtower-who-to-ask", "SKILL.md")
	edited := "---\nname: watchtower-who-to-ask\ndescription: mine now\n" +
		MarkerKey + ": v1\n---\n\nMy own instructions.\n"
	if err := os.WriteFile(target, []byte(edited), 0o644); err != nil {
		t.Fatalf("editing: %v", err)
	}

	got, err := Install(dir)
	if err != nil {
		t.Fatalf("reinstall: %v", err)
	}
	for _, s := range got {
		if s.Name == "watchtower-who-to-ask" && s.State != StateDrifted {
			t.Fatalf("expected drifted, got %s", s.State)
		}
	}
	after, err := os.ReadFile(target)
	if err != nil {
		t.Fatalf("reading back: %v", err)
	}
	if string(after) != edited {
		t.Fatalf("DEV-04 violated: a user-edited skill was overwritten")
	}
}

func TestRemoveDeletesOnlyMarkedFiles(t *testing.T) {
	dir := t.TempDir()
	if _, err := Install(dir); err != nil {
		t.Fatalf("install: %v", err)
	}

	// A neighbouring skill that is not ours, in the same directory.
	foreignDir := filepath.Join(dir, "someones-own-skill")
	if err := os.MkdirAll(foreignDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	foreign := filepath.Join(foreignDir, "SKILL.md")
	if err := os.WriteFile(foreign, []byte("---\nname: someones-own-skill\n---\n"), 0o644); err != nil {
		t.Fatalf("write foreign: %v", err)
	}

	// A skill with our name but no marker — must be treated as foreign.
	unmarked := filepath.Join(dir, "watchtower-task-context", "SKILL.md")
	if err := os.WriteFile(unmarked, []byte("---\nname: watchtower-task-context\n---\nmine\n"), 0o644); err != nil {
		t.Fatalf("write unmarked: %v", err)
	}

	if _, err := Remove(dir); err != nil {
		t.Fatalf("remove: %v", err)
	}

	if _, err := os.Stat(foreign); err != nil {
		t.Fatalf("remove deleted a foreign skill: %v", err)
	}
	if _, err := os.Stat(unmarked); err != nil {
		t.Fatalf("remove deleted an unmarked file bearing our name: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "watchtower-why-decision", "SKILL.md")); !os.IsNotExist(err) {
		t.Fatalf("expected our marked skill to be gone, got err=%v", err)
	}
}

func TestStatusReportsMissingWithoutWriting(t *testing.T) {
	dir := t.TempDir()

	got, err := Status(dir)
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	for _, s := range got {
		if s.State != StateMissing {
			t.Fatalf("%s: expected missing, got %s", s.Name, s.State)
		}
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("status must not write anything, found %d entries", len(entries))
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./internal/devpack/ -run "TestInstall|TestRemove|TestStatus" -v > /tmp/t9.log 2>&1; echo "exit=$?"
```

Expected: FAIL — `undefined: Install`.

- [ ] **Step 3: Implement**

Create `internal/devpack/install.go`:

```go
package devpack

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
)

// State is what happened (or would happen) to one skill file.
type State string

const (
	StateInstalled State = "installed" // written fresh
	StateUpdated   State = "updated"   // replaced a previously shipped version
	StateUnchanged State = "unchanged" // already byte-identical to what we ship
	StateDrifted   State = "drifted"   // user-edited: left alone (DEV-04)
	StateMissing   State = "missing"   // not present (status only)
	StateForeign   State = "foreign"   // present without our marker: never touched
	StateRemoved   State = "removed"   // deleted by Remove
)

// SkillStatus is one skill's outcome, always with the path so the CLI can
// report exactly which file it touched.
type SkillStatus struct {
	Name  string
	State State
	Path  string
}

// Install writes the pack into skillsDir, one directory per skill. A file we
// did not ship — or one a user has edited since we shipped it — is left
// untouched and reported (DEV-04). Every shipped version's digest is recorded
// in a sidecar so a later run can tell "user edited it" from "we changed it".
func Install(skillsDir string) ([]SkillStatus, error) {
	skills := Skills()
	out := make([]SkillStatus, 0, len(skills))
	for _, s := range skills {
		dir := filepath.Join(skillsDir, s.Name)
		file := filepath.Join(dir, "SKILL.md")

		state, err := planFor(file, s)
		if err != nil {
			return nil, err
		}
		if state == StateInstalled || state == StateUpdated {
			if err := os.MkdirAll(dir, 0o755); err != nil {
				return nil, fmt.Errorf("creating %s: %w", dir, err)
			}
			if err := os.WriteFile(file, []byte(s.Content), 0o644); err != nil {
				return nil, fmt.Errorf("writing %s: %w", file, err)
			}
			if err := writeShippedDigest(dir, s.SHA256); err != nil {
				return nil, err
			}
		}
		out = append(out, SkillStatus{Name: s.Name, State: state, Path: file})
	}
	return out, nil
}

// planFor decides what Install would do to one file, without writing.
func planFor(file string, s Skill) (State, error) {
	existing, err := os.ReadFile(file)
	if os.IsNotExist(err) {
		return StateInstalled, nil
	}
	if err != nil {
		return "", fmt.Errorf("reading %s: %w", file, err)
	}
	content := string(existing)
	if !HasMarker(content) {
		// Someone else's file living under a name we also use.
		return StateForeign, nil
	}
	sum := sha256.Sum256(existing)
	current := hex.EncodeToString(sum[:])
	if current == s.SHA256 {
		return StateUnchanged, nil
	}
	// The file differs from what we ship. If it still matches the digest we
	// recorded when we last wrote it, the difference is ours (a new pack
	// version) and we may update. Otherwise the user edited it.
	shipped, err := readShippedDigest(filepath.Dir(file))
	if err != nil {
		return "", err
	}
	if shipped != "" && shipped == current {
		return StateUpdated, nil
	}
	return StateDrifted, nil
}

// Status reports what Install would do, writing nothing.
func Status(skillsDir string) ([]SkillStatus, error) {
	skills := Skills()
	out := make([]SkillStatus, 0, len(skills))
	for _, s := range skills {
		file := filepath.Join(skillsDir, s.Name, "SKILL.md")
		if _, err := os.Stat(file); os.IsNotExist(err) {
			out = append(out, SkillStatus{Name: s.Name, State: StateMissing, Path: file})
			continue
		}
		state, err := planFor(file, s)
		if err != nil {
			return nil, err
		}
		if state == StateInstalled {
			state = StateMissing
		}
		out = append(out, SkillStatus{Name: s.Name, State: state, Path: file})
	}
	return out, nil
}

// Remove deletes only the skills we shipped and still own: the file must
// carry our marker. A user-edited copy is kept (it is theirs now) and
// reported as drifted; anything without the marker is left as foreign.
func Remove(skillsDir string) ([]SkillStatus, error) {
	skills := Skills()
	out := make([]SkillStatus, 0, len(skills))
	for _, s := range skills {
		dir := filepath.Join(skillsDir, s.Name)
		file := filepath.Join(dir, "SKILL.md")

		existing, err := os.ReadFile(file)
		if os.IsNotExist(err) {
			out = append(out, SkillStatus{Name: s.Name, State: StateMissing, Path: file})
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("reading %s: %w", file, err)
		}
		if !HasMarker(string(existing)) {
			out = append(out, SkillStatus{Name: s.Name, State: StateForeign, Path: file})
			continue
		}
		state, err := planFor(file, s)
		if err != nil {
			return nil, err
		}
		if state == StateDrifted {
			out = append(out, SkillStatus{Name: s.Name, State: StateDrifted, Path: file})
			continue
		}
		if err := os.RemoveAll(dir); err != nil {
			return nil, fmt.Errorf("removing %s: %w", dir, err)
		}
		out = append(out, SkillStatus{Name: s.Name, State: StateRemoved, Path: file})
	}
	return out, nil
}

// The sidecar records the digest of what WE last wrote, which is how a pack
// upgrade is told apart from a user edit. It lives next to the skill so
// removing the directory removes it too.
const shippedDigestFile = ".watchtower-shipped"

func writeShippedDigest(dir, digest string) error {
	p := filepath.Join(dir, shippedDigestFile)
	if err := os.WriteFile(p, []byte(digest+"\n"), 0o644); err != nil {
		return fmt.Errorf("writing %s: %w", p, err)
	}
	return nil
}

func readShippedDigest(dir string) (string, error) {
	b, err := os.ReadFile(filepath.Join(dir, shippedDigestFile))
	if os.IsNotExist(err) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("reading shipped digest: %w", err)
	}
	return string(trimNewline(b)), nil
}

func trimNewline(b []byte) []byte {
	for len(b) > 0 && (b[len(b)-1] == '\n' || b[len(b)-1] == '\r') {
		b = b[:len(b)-1]
	}
	return b
}
```

Note the test writes an edited file whose digest matches neither the shipped content nor the sidecar, so `planFor` returns `StateDrifted` — that is the DEV-04 path under test.

- [ ] **Step 4: Run tests to verify they pass**

```bash
go test ./internal/devpack/ -v > /tmp/t9.log 2>&1; echo "exit=$?"
```

Expected: PASS, all six tests in the package.

- [ ] **Step 5: Commit**

```bash
git add internal/devpack/install.go internal/devpack/install_test.go
git commit -m "feat(devpack): installer that never clobbers user edits

Install/Status/Remove key on the pack marker plus a shipped-digest sidecar,
so a pack upgrade is distinguishable from a user edit: ours gets updated,
theirs gets reported as drifted and left alone (DEV-04)."
```

---

## Task 10: `watchtower integrate` CLI

**Files:**
- Create: `cmd/integrate.go`
- Test: `cmd/integrate_test.go`

**Interfaces:**
- Consumes: `devpack.Install/Status/Remove`, `devpack.SkillStatus` (Task 9); `Constants`-style CLI path resolution already used by `cmd` (`os.Executable`).
- Produces: commands `watchtower integrate claude-code [--scope user|project] [--path DIR] [--skills-only]`, `watchtower integrate status [--scope ...]`, `watchtower integrate remove [--scope ...]`.

- [ ] **Step 1: Write the failing test**

Create `cmd/integrate_test.go`:

```go
package cmd

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResolveSkillsDirUserScopeUsesHome(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	got, err := resolveSkillsDir("user", "")
	if err != nil {
		t.Fatalf("resolving: %v", err)
	}
	want := filepath.Join(home, ".claude", "skills")
	if got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestResolveSkillsDirProjectScopeUsesCwd(t *testing.T) {
	dir := t.TempDir()
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	t.Cleanup(func() { _ = os.Chdir(cwd) })
	if err := os.Chdir(dir); err != nil {
		t.Fatalf("chdir: %v", err)
	}

	got, err := resolveSkillsDir("project", "")
	if err != nil {
		t.Fatalf("resolving: %v", err)
	}
	// t.TempDir may hand back a symlinked path (/var vs /private/var on
	// macOS); compare resolved forms.
	gotReal, _ := filepath.EvalSymlinks(got)
	wantReal, _ := filepath.EvalSymlinks(filepath.Join(dir, ".claude", "skills"))
	if gotReal != wantReal {
		t.Fatalf("got %q, want %q", gotReal, wantReal)
	}
}

func TestResolveSkillsDirExplicitPathWins(t *testing.T) {
	got, err := resolveSkillsDir("user", "/tmp/somewhere/skills")
	if err != nil {
		t.Fatalf("resolving: %v", err)
	}
	if got != "/tmp/somewhere/skills" {
		t.Fatalf("explicit --path must win, got %q", got)
	}
}

func TestResolveSkillsDirRejectsUnknownScope(t *testing.T) {
	if _, err := resolveSkillsDir("global", ""); err == nil {
		t.Fatalf("expected an error for an unknown scope")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
go test ./cmd/ -run TestResolveSkillsDir -v > /tmp/t10.log 2>&1; echo "exit=$?"
```

Expected: FAIL — `undefined: resolveSkillsDir`.

- [ ] **Step 3: Implement**

Create `cmd/integrate.go`:

```go
package cmd

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/spf13/cobra"

	"watchtower/internal/devpack"
)

var integrateCmd = &cobra.Command{
	Use:   "integrate",
	Short: "Wire Watchtower into your coding agent",
	Long: `Install Watchtower's MCP server and skill pack into a coding agent.

Nothing installs itself: this command is the only thing that writes to your
agent's configuration, and 'integrate remove' undoes exactly what it wrote.`,
}

var integrateClaudeCodeCmd = &cobra.Command{
	Use:   "claude-code",
	Short: "Register the MCP server and install the skill pack for Claude Code",
	RunE:  runIntegrateClaudeCode,
}

var integrateStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Report what is installed, missing, or edited",
	RunE:  runIntegrateStatus,
}

var integrateRemoveCmd = &cobra.Command{
	Use:   "remove",
	Short: "Remove the skill pack (and unregister the MCP server)",
	RunE:  runIntegrateRemove,
}

var (
	integrateScope      string
	integratePath       string
	integrateSkillsOnly bool
)

func init() {
	rootCmd.AddCommand(integrateCmd)
	integrateCmd.AddCommand(integrateClaudeCodeCmd, integrateStatusCmd, integrateRemoveCmd)

	for _, c := range []*cobra.Command{integrateClaudeCodeCmd, integrateStatusCmd, integrateRemoveCmd} {
		c.Flags().StringVar(&integrateScope, "scope", "user",
			"where skills live: user (~/.claude/skills) or project (./.claude/skills)")
		c.Flags().StringVar(&integratePath, "path", "",
			"explicit skills directory (overrides --scope)")
	}
	integrateClaudeCodeCmd.Flags().BoolVar(&integrateSkillsOnly, "skills-only", false,
		"install the skill pack without registering the MCP server")
}

// resolveSkillsDir turns --scope/--path into one directory. An explicit path
// always wins; otherwise user scope is the home directory and project scope
// is the current working directory.
func resolveSkillsDir(scope, explicit string) (string, error) {
	if explicit != "" {
		return explicit, nil
	}
	switch scope {
	case "user":
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("determining home directory: %w", err)
		}
		return filepath.Join(home, ".claude", "skills"), nil
	case "project":
		cwd, err := os.Getwd()
		if err != nil {
			return "", fmt.Errorf("determining working directory: %w", err)
		}
		return filepath.Join(cwd, ".claude", "skills"), nil
	default:
		return "", fmt.Errorf("unknown scope %q: use user or project", scope)
	}
}

func runIntegrateClaudeCode(cmd *cobra.Command, args []string) error {
	dir, err := resolveSkillsDir(integrateScope, integratePath)
	if err != nil {
		return err
	}
	results, err := devpack.Install(dir)
	if err != nil {
		return err
	}
	fmt.Printf("Skills (%s):\n", dir)
	printSkillStatuses(results)

	if integrateSkillsOnly {
		return nil
	}
	return registerMCPWithClaudeCode()
}

func runIntegrateStatus(cmd *cobra.Command, args []string) error {
	dir, err := resolveSkillsDir(integrateScope, integratePath)
	if err != nil {
		return err
	}
	results, err := devpack.Status(dir)
	if err != nil {
		return err
	}
	fmt.Printf("Skills (%s):\n", dir)
	printSkillStatuses(results)

	bin, err := os.Executable()
	if err == nil {
		fmt.Printf("\nCLI binary: %s\n", bin)
	}
	return nil
}

func runIntegrateRemove(cmd *cobra.Command, args []string) error {
	dir, err := resolveSkillsDir(integrateScope, integratePath)
	if err != nil {
		return err
	}
	results, err := devpack.Remove(dir)
	if err != nil {
		return err
	}
	fmt.Printf("Skills (%s):\n", dir)
	printSkillStatuses(results)

	if _, err := exec.LookPath("claude"); err != nil {
		fmt.Println("\nclaude CLI not found — remove the MCP server yourself with:")
		fmt.Println("  claude mcp remove watchtower")
		return nil
	}
	out, err := exec.Command("claude", "mcp", "remove", "watchtower").CombinedOutput()
	if err != nil {
		fmt.Printf("\nCould not unregister the MCP server (%v). Remove it with:\n", err)
		fmt.Println("  claude mcp remove watchtower")
		fmt.Printf("%s\n", out)
		return nil
	}
	fmt.Println("\nMCP server unregistered.")
	return nil
}

func printSkillStatuses(results []devpack.SkillStatus) {
	for _, r := range results {
		note := ""
		switch r.State {
		case devpack.StateDrifted:
			note = "  (you edited this — left alone)"
		case devpack.StateForeign:
			note = "  (not ours — left alone)"
		}
		fmt.Printf("  %-26s %s%s\n", r.Name, r.State, note)
	}
}

// registerMCPWithClaudeCode registers this binary as the watchtower MCP
// server. When the claude CLI is absent we print the exact command instead of
// failing: the skills are already installed and useful, and the user may be
// configuring a different client.
func registerMCPWithClaudeCode() error {
	bin, err := os.Executable()
	if err != nil {
		return fmt.Errorf("determining the watchtower binary path: %w", err)
	}
	if _, err := exec.LookPath("claude"); err != nil {
		fmt.Println("\nclaude CLI not found. Register the MCP server yourself with:")
		fmt.Printf("  claude mcp add watchtower -- %s mcp\n", bin)
		return nil
	}
	out, err := exec.Command("claude", "mcp", "add", "watchtower", "--", bin, "mcp").CombinedOutput()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			// Most commonly: already registered. Report, do not fail — the
			// user's existing registration is theirs to keep.
			fmt.Printf("\nMCP registration reported: %s", out)
			fmt.Printf("If it is not registered, run:\n  claude mcp add watchtower -- %s mcp\n", bin)
			return nil
		}
		return fmt.Errorf("registering the MCP server: %w", err)
	}
	fmt.Printf("\nMCP server registered: %s mcp\n", bin)
	return nil
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
go test ./cmd/ -run TestResolveSkillsDir -v > /tmp/t10.log 2>&1; echo "exit=$?"
```

Expected: PASS.

- [ ] **Step 5: Verify the command end-to-end by hand**

```bash
go build -o /tmp/wt . > /tmp/build.log 2>&1; echo "build exit=$?"
mkdir -p /tmp/integ-test
/tmp/wt integrate claude-code --path /tmp/integ-test --skills-only > /tmp/integ1.log 2>&1; echo "exit=$?"
cat /tmp/integ1.log
/tmp/wt integrate status --path /tmp/integ-test > /tmp/integ2.log 2>&1; echo "exit=$?"
cat /tmp/integ2.log
/tmp/wt integrate remove --path /tmp/integ-test > /tmp/integ3.log 2>&1; echo "exit=$?"
cat /tmp/integ3.log
```

Expected: first run reports four `installed`; status reports four `unchanged`; remove reports four `removed`. `--skills-only` is used here so the check never touches the developer's real Claude Code configuration.

- [ ] **Step 6: Commit**

```bash
git add cmd/integrate.go cmd/integrate_test.go
git commit -m "feat(cli): watchtower integrate claude-code | status | remove

One command installs the skill pack and registers the MCP server; status
reports drift; remove undoes exactly what was written. A missing claude CLI
prints the manual command rather than failing."
```

---

## Task 11: Documentation and behavioral contracts

**Files:**
- Create: `docs/inventory/dev-surface.md`
- Modify: `docs/inventory/README.md`
- Modify: `CLAUDE.md` (new feature-notes section)
- Modify: `docs/app-guide.md` (only if it documents CLI surfaces; check first)

**Interfaces:**
- Consumes: everything built in Tasks 1–10.
- Produces: DEV-01..05 as catalogued contracts.

- [ ] **Step 1: Write `docs/inventory/dev-surface.md`**

Follow the shape of `docs/inventory/ideas.md`: a short intro, then one section per contract with the rule, the reason, and where it is enforced.

```markdown
# Developer Surface — Behavioral Contracts

The MCP tools, skill pack, and installer that make Watchtower addressable from
a developer's coding agent. Design: `docs/superpowers/specs/2026-08-09-dev-knowledge-base-design.md`.

## DEV-01 — read-only forever

Every tool on this surface is a read. `cmd/mcp.go` flips the connection to
`PRAGMA query_only=ON` via `database.SetReadOnly()` before serving, and the
tool tests run through the same wiring (`newTestSession`), so a handler that
tried to write would fail in tests, not in production.

## DEV-02 — no AI in the data layer

`get_task_context`, `find_experts`, `list_situations` and `get_situation` are
mechanical SQL. No `digest.Generator`, no prompt, no model call. Interpretation
happens in the consumer's agent, on the consumer's tokens — which is also what
keeps the surface free at Watchtower's expense-side.

## DEV-03 — evidence, not verdicts

`find_experts` never asserts that someone is an expert. Every candidate carries
countable evidence entries with a resolvable ref, and the response ships the
ranking weights that produced the order (`expertWeights` in
`internal/mcp/experts.go`). Pinned by
`TestFindExpertsRanksByEvidenceAndAlwaysCitesIt`. An unmatched git author is
reported in `unmatched_emails`, never silently dropped.

## DEV-04 — the installer never clobbers

`devpack.Install` writes only files that are absent, byte-identical to what we
ship, or that still match the digest we recorded when we last wrote them
(`.watchtower-shipped`). Anything else is reported as `drifted` (user-edited)
or `foreign` (no `x-watchtower-pack` marker) and left untouched. `Remove`
deletes only marked, undrifted files. Pinned by
`TestInstallNeverClobbersAUserEditedSkill` and `TestRemoveDeletesOnlyMarkedFiles`.

## DEV-05 — pull only

Nothing on this surface initiates contact with the developer: no hooks, no
notifications, no context injection, no background writes into an agent
session. The dev asks; the world answers. Adding a push mechanic requires an
explicit, CLI-controlled opt-in and an owner decision — it is not an
implementation detail.
```

- [ ] **Step 2: Add the mapping row to `docs/inventory/README.md`**

Add a row pointing `internal/mcp/` (dev tools), `internal/devpack/`, and `cmd/integrate.go` at `dev-surface.md`, matching the file's existing table format.

- [ ] **Step 3: Add the CLAUDE.md feature section**

Insert a `### Developer Surface — MCP tools + skill pack (2026-08-09)` section in the Feature Notes area, after the Ideas registry section. Keep it to the same density as its neighbours: what the tools are, where the skills live, what `integrate` does, the DEV-01..05 pointer, and the one migration (00052 `transcripts_fts`).

- [ ] **Step 4: Verify the docs build/read cleanly**

```bash
grep -n "dev-surface" docs/inventory/README.md > /tmp/t11.log 2>&1; echo "exit=$?"
grep -n "Developer Surface" CLAUDE.md >> /tmp/t11.log 2>&1; echo "exit=$?"
```

Expected: both grep hits present.

- [ ] **Step 5: Commit**

```bash
git add docs/inventory/dev-surface.md docs/inventory/README.md CLAUDE.md
git commit -m "docs: DEV-01..05 contracts for the developer surface"
```

---

## Task 12: Full verification pass

**Files:** none (verification only).

- [ ] **Step 1: Format, vet, build**

```bash
gofmt -l ./cmd ./internal > /tmp/final-fmt.log 2>&1; echo "unformatted: $(wc -l < /tmp/final-fmt.log)"
go vet ./... > /tmp/final-vet.log 2>&1; echo "vet exit=$?"
go build ./... > /tmp/final-build.log 2>&1; echo "build exit=$?"
```

Expected: zero unformatted files, vet exit 0, build exit 0.

- [ ] **Step 2: Full test suite**

```bash
go test ./... > /tmp/final-test.log 2>&1; echo "test exit=$?"
```

Expected: exit 0. Do not pipe through `tail` — read the log file if it fails.

- [ ] **Step 3: Migration sanity on a fresh database**

```bash
rm -f /tmp/devsurface.db
/tmp/wt --help > /dev/null 2>&1   # ensure the binary from Task 10 still builds
go run . db migrate --db-path /tmp/devsurface.db > /tmp/final-migrate.log 2>&1; echo "exit=$?"
```

If `db migrate` is not the actual subcommand, check `cmd/db.go` for the right one. Expected: exit 0, and `sqlite3 /tmp/devsurface.db ".tables"` (or an equivalent Go check) lists `transcripts_fts`.

- [ ] **Step 4: Local review gate**

Run the repo's own review pipeline before opening the PR — it mirrors CI and catches the house-convention issues this plan cannot encode:

```
Use the local-review skill on the full branch diff against main.
```

- [ ] **Step 5: Open the PR**

```bash
git push -u origin feat/dev-knowledge-base
gh pr create --title "feat: developer knowledge base — MCP tools, skill pack, integrate CLI" --body "$(cat <<'EOF'
## Summary
Makes Watchtower addressable from inside a developer's agent session.

- **Data layer:** `get_task_context` (the dossier a ticket lacks), `find_experts` (who knows / who decides / how to approach, with evidence), `list_situations`/`get_situation` (the secretary dashboard, previously Desktop-only). All mechanical SQL, read-only, no AI.
- **`transcripts_fts`** (migration 00052): meeting transcripts had no keyword search at all.
- **Skill pack:** four skills embedded in the binary teaching a coding agent when and how to use the tools.
- **`watchtower integrate claude-code`:** installs both, reports drift, removes cleanly. Never overwrites a user-edited skill.

Contracts DEV-01..05 in `docs/inventory/dev-surface.md`.
Design: `docs/superpowers/specs/2026-08-09-dev-knowledge-base-design.md`.

## Test plan
- `go test ./...` green.
- Installer verified against a temp directory: install → status → remove.
- Migration verified on a fresh database.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Notes for the implementer

- **Read before you write.** This plan names db functions and struct fields from `internal/db`. They were verified at planning time, but confirm each signature and field name in the actual source before using it — especially `db.JiraIssue`, `db.JiraComment`, `db.Message`, and `db.DashboardSituation`, whose field sets are wide.
- **Namespaced ids everywhere.** `users.id`, `messages.channel_id`, `messages.user_id` are `"<slack_account_id>:<raw id>"`. Pass them through verbatim; never rebuild a bare `U…`/`C…`.
- **Soft errors, not Go errors.** MCP handlers return `errResult(msg), nil, nil`. Returning a Go `error` from a handler is the wrong shape for this codebase.
- **Empty is not an error.** A dossier section with no material is omitted. A search with no hits returns an empty list. Only an unusable *input* (unknown issue key, no arguments at all) is a tool error.
- **Test seeding goes through the real writers where they exist** (`InsertMeetingTranscript`, `UpsertJiraSlackLink`) so triggers and defaults fire the way they do in production. Raw `INSERT`s are fine for tables with no writer, but read the schema for NOT NULL columns first.
