package db

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Sample Atlassian ids (made up): closedID is the closed account, keptID a
// live one whose rows must stay as they are.
const (
	closedID = "acme-closed-1"
	keptID   = "acme-kept-2"
)

// isAtlassianPersonColumnName reports a column name that holds what a person
// is called or how to reach them.
func isAtlassianPersonColumnName(col string) bool {
	switch col {
	case "email", "display_name", "slack_user_id", "author":
		return true
	}
	return strings.HasSuffix(col, "_email") || strings.HasSuffix(col, "_display_name") || strings.HasSuffix(col, "_slack_id")
}

// TestPDR_EraseCoversEveryAtlassianPersonColumn walks the migrated schema:
// every person column of a jira_*/ext_* table is erased
// (atlassianPersonColumns), sits in a table whose row is deleted
// (atlassianPeopleDeletedTables), or is listed in atlassianPeopleKeptColumns
// with a reason. A new column holding an Atlassian person's name or email
// fails here until the erase covers it.
func TestPDR_EraseCoversEveryAtlassianPersonColumn(t *testing.T) {
	d := openTestDB(t)
	covered := map[string]bool{}
	for _, c := range atlassianPersonColumns {
		covered[c.table+"."+c.col] = true
	}
	deleted := map[string]bool{}
	for _, tb := range atlassianPeopleDeletedTables {
		deleted[tb.table] = true
	}
	tables := queryStrings(t, d, `SELECT name FROM sqlite_master WHERE type = 'table' AND (name LIKE 'jira\_%' ESCAPE '\' OR name LIKE 'ext\_%' ESCAPE '\') ORDER BY name`)
	require.NotEmpty(t, tables)
	existing := map[string]bool{}
	for _, table := range tables {
		cols := queryStrings(t, d, `SELECT name FROM pragma_table_info(?)`, table)
		for _, col := range cols {
			key := table + "." + col
			existing[key] = true
			if !isAtlassianPersonColumnName(col) || deleted[table] {
				continue
			}
			_, kept := atlassianPeopleKeptColumns[key]
			assert.True(t, covered[key] || kept, "%s holds an Atlassian person's data: erase it in atlassianPersonColumns or list it in atlassianPeopleKeptColumns with a reason", key)
		}
	}
	for key := range covered {
		assert.True(t, existing[key], "atlassianPersonColumns names %s, which the schema does not have", key)
	}
	for key, reason := range atlassianPeopleKeptColumns {
		assert.True(t, existing[key], "atlassianPeopleKeptColumns names %s, which the schema does not have", key)
		assert.NotEmpty(t, reason)
	}
	for tb := range deleted {
		assert.Contains(t, tables, tb)
	}
}

// seedAtlassianPeople writes one row per person column for both closedID and
// keptID on Jira account acct (and one Confluence space), so every entry of
// atlassianPersonColumns has a value to erase and one to keep.
func seedAtlassianPeople(t *testing.T, d *DB, acct int64) (srcID int64) {
	t.Helper()
	ctx := context.Background()
	exec := func(q string, args ...any) {
		t.Helper()
		_, err := d.ExecContext(ctx, q, args...)
		require.NoError(t, err)
	}
	for i, id := range []string{closedID, keptID} {
		key := fmt.Sprintf("ACME-%d", i+1)
		exec(`INSERT INTO jira_issues (account_id, key, project_key, summary, status, status_category, created_at, updated_at, synced_at,
			assignee_account_id, assignee_email, assignee_display_name, assignee_slack_id,
			reporter_account_id, reporter_email, reporter_display_name, reporter_slack_id, raw_json)
			VALUES (?, ?, 'ACME', 's', 'Open', 'todo', '2026-11-01T00:00:00Z', '2026-11-01T00:00:00Z', '2026-11-02T00:00:00Z',
			?, 'p@example.com', 'Person', '1:U0000001', ?, 'p@example.com', 'Person', '1:U0000001', ?)`,
			acct, key, id, id, `{"fields":{"assignee":{"accountId":"`+id+`","displayName":"Person"}}}`)
		exec(`INSERT INTO jira_linked_issues (account_id, key, assignee_account_id, assignee_display_name) VALUES (?, ?, ?, 'Person')`,
			acct, "OTHER-"+key, id)
		exec(`INSERT INTO jira_comments (account_id, issue_key, id, author, author_account_id, synced_at) VALUES (?, ?, ?, 'Person', ?, '2026-11-01T00:00:00Z')`,
			acct, key, "c"+key, id)
		exec(`INSERT INTO jira_issue_changelog (account_id, issue_key, history_id, field, from_value, from_string, to_value, to_string, author_account_id, author_display_name, changed_at)
			VALUES (?, ?, 'h1', 'assignee', ?, 'Person', ?, 'Person', ?, 'Person', '2026-11-01T00:00:00Z')`, acct, key, id, id, id)
		exec(`INSERT OR IGNORE INTO jira_user_map (jira_account_id, email, slack_user_id, display_name) VALUES (?, 'p@example.com', '1:U0000001', 'Person')`, id)
		exec(`INSERT OR IGNORE INTO ext_users (provider, ext_user_id, display_name, email, fetched_at) VALUES ('confluence', ?, 'Person', 'p@example.com', '2026-11-03T00:00:00Z')`, id)
	}
	exec(`UPDATE jira_accounts SET owner_account_id = ?, owner_email = 'o@example.com', owner_display_name = 'Owner' WHERE id = ?`, closedID, acct)
	var err error
	srcID, err = d.CreateExtSource("confluence", acct, "ENG", "100", "Engineering")
	require.NoError(t, err)
	exec(`INSERT INTO ext_documents (source_id, ext_id, kind, author_id, synced_at) VALUES (?, 'p1', 'page', ?, '2026-11-01T00:00:00Z')`, srcID, closedID)
	exec(`INSERT INTO ext_documents (source_id, ext_id, kind, author_id, sections_json) VALUES (?, 'p2', 'page', ?, ?)`,
		srcID, keptID, `[{"text":"ask @[~`+closedID+`]"}]`)
	exec(`INSERT INTO ext_documents (source_id, ext_id, kind, author_id) VALUES (?, 'p3', 'page', ?)`, srcID, keptID)
	exec(`INSERT INTO ext_comments (source_id, ext_id, page_ext_id, kind, author_id) VALUES (?, 'c1', 'p3', 'footer', ?)`, srcID, closedID)
	return srcID
}

func eraseAtlassian(t *testing.T, d *DB, acct int64, ids []string) {
	t.Helper()
	ctx := context.Background()
	plan, err := d.PlanAtlassianErase(ctx, acct, ids)
	require.NoError(t, err)
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error { return d.EraseAtlassianPeople(ctx, tx, acct, ids, plan) }))
}

func pdrCount(t *testing.T, d *DB, q string, args ...any) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(q, args...).Scan(&n))
	return n
}

func TestPDR_ClosedErasesEveryColumn(t *testing.T) {
	d := openTestDB(t)
	acct := SeedTestJiraAccount(t, d)
	other := SeedTestJiraAccount(t, d)
	srcID := seedAtlassianPeople(t, d, acct)
	seedAtlassianPeople(t, d, other)

	eraseAtlassian(t, d, acct, []string{closedID})

	for _, c := range atlassianPersonColumns {
		where := c.idCol + " = ?"
		if c.where != "" {
			where += " AND " + c.where
		}
		scoped := fmt.Sprintf(`SELECT count(*) FROM %s WHERE %s AND %s AND %s != ''`, c.table, c.scope, where, c.col)
		assert.Zero(t, pdrCount(t, d, scoped, acct, closedID), "%s.%s still names the closed account", c.table, c.col)
		if c.table != "jira_accounts" {
			assert.Equal(t, 1, pdrCount(t, d, scoped, acct, keptID), "%s.%s of a live account must stay", c.table, c.col)
		}
		assert.Equal(t, 1, pdrCount(t, d, scoped, other, closedID), "%s.%s of another Jira account is that account's erase", c.table, c.col)
	}
	assert.Zero(t, pdrCount(t, d, `SELECT count(*) FROM jira_user_map WHERE jira_account_id = ?`, closedID))
	assert.Zero(t, pdrCount(t, d, `SELECT count(*) FROM ext_users WHERE ext_user_id = ?`, closedID))
	assert.Equal(t, 1, pdrCount(t, d, `SELECT count(*) FROM jira_user_map WHERE jira_account_id = ?`, keptID))
	assert.Equal(t, 1, pdrCount(t, d, `SELECT count(*) FROM ext_users WHERE ext_user_id = ?`, keptID))
	assert.Zero(t, pdrCount(t, d, `SELECT count(*) FROM jira_issues WHERE account_id = ? AND instr(raw_json, ?) > 0`, acct, closedID), "issue payloads naming the person are blanked")
	assert.Equal(t, 1, pdrCount(t, d, `SELECT count(*) FROM jira_issues WHERE account_id = ? AND instr(raw_json, ?) > 0`, acct, keptID))
	assert.Equal(t, 1, pdrCount(t, d, `SELECT count(*) FROM jira_issues WHERE account_id = ? AND assignee_account_id = ?`, acct, closedID), "the bare id stays (Former user)")

	marks := queryStrings(t, d, `SELECT source || '|' || key FROM kb_dirty ORDER BY 1`)
	assert.Equal(t, []string{
		fmt.Sprintf("confluence|confluence:%d:p1", srcID),
		fmt.Sprintf("confluence|confluence:%d:p2", srcID),
		fmt.Sprintf("confluence|confluence:%d:p3", srcID),
		fmt.Sprintf("jira|jira:%d:ACME-1", acct),
	}, marks)
}

func TestPDR_EraseIsIdempotent(t *testing.T) {
	d := openTestDB(t)
	acct := SeedTestJiraAccount(t, d)
	seedAtlassianPeople(t, d, acct)
	snapshot := func() []string {
		return queryStrings(t, d, `SELECT key || assignee_email || assignee_display_name || reporter_display_name || raw_json FROM jira_issues
			UNION ALL SELECT author FROM jira_comments UNION ALL SELECT from_string || to_string || author_display_name FROM jira_issue_changelog
			UNION ALL SELECT jira_account_id FROM jira_user_map UNION ALL SELECT ext_user_id FROM ext_users
			UNION ALL SELECT owner_email || owner_display_name FROM jira_accounts ORDER BY 1`)
	}
	eraseAtlassian(t, d, acct, []string{closedID})
	after := snapshot()
	eraseAtlassian(t, d, acct, []string{closedID})
	assert.Equal(t, after, snapshot(), "a repeated erase (the next cycle after a crash) changes nothing more")
}

func TestAtlassianPeople_ListsEveryStoredID(t *testing.T) {
	d := openTestDB(t)
	acct := SeedTestJiraAccount(t, d)
	seedAtlassianPeople(t, d, acct)
	_, err := d.Exec(`INSERT INTO jira_user_map (jira_account_id, resolved_at) VALUES ('acme-map-only', '')`)
	require.NoError(t, err)

	people, err := d.AtlassianPeople(context.Background(), acct)
	require.NoError(t, err)
	ids := make([]string, len(people))
	for i, p := range people {
		ids[i] = p.ID
	}
	assert.Equal(t, []string{closedID, keptID, "acme-map-only"}, ids)
	assert.Equal(t, time.Date(2026, 11, 3, 0, 0, 0, 0, time.UTC), people[0].UpdatedAt, "the newest fetch of a row naming the id")
	assert.True(t, people[2].UpdatedAt.IsZero())
}

func TestSetJiraPDRScopeHint_LeavesStatusAndRealErrors(t *testing.T) {
	d := openTestDB(t)
	acct := SeedTestJiraAccount(t, d)
	require.NoError(t, d.SetJiraPDRScopeHint(acct, true))
	a, err := d.GetJiraAccount(acct)
	require.NoError(t, err)
	assert.Equal(t, "ok", a.Status)
	assert.Equal(t, PDRScopeMissingCode, a.Error)

	require.NoError(t, d.SetJiraPDRScopeHint(acct, false))
	a, _ = d.GetJiraAccount(acct)
	assert.Empty(t, a.Error)

	require.NoError(t, d.SetJiraAccountAuthState(acct, "error", "invalid_client"))
	require.NoError(t, d.SetJiraPDRScopeHint(acct, true))
	require.NoError(t, d.SetJiraPDRScopeHint(acct, false))
	a, _ = d.GetJiraAccount(acct)
	assert.Equal(t, "invalid_client", a.Error, "the hint never overwrites or clears a real error")
}
