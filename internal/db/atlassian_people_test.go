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
	otherSrc := seedAtlassianPeople(t, d, other)
	_, err := d.Exec(`UPDATE jira_issues SET custom_fields_json = '{"cf_reviewer":"Person","cf_team":"Platform"}' WHERE account_id = ?`, acct)
	require.NoError(t, err)

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

	assert.Equal(t, []string{`{"cf_reviewer":"","cf_team":"Platform"}`, `{"cf_reviewer":"Person","cf_team":"Platform"}`},
		queryStrings(t, d, `SELECT custom_fields_json FROM jira_issues WHERE account_id = ? ORDER BY key`, acct),
		"a user-picker name is removed from the issues naming the closed account only")

	// The shared ext_users row is gone, so every source's pages that render
	// the name are re-rendered, not only this account's.
	marks := queryStrings(t, d, `SELECT source || '|' || key FROM kb_dirty ORDER BY 1`)
	assert.Equal(t, []string{
		fmt.Sprintf("confluence|confluence:%d:p1", srcID),
		fmt.Sprintf("confluence|confluence:%d:p2", srcID),
		fmt.Sprintf("confluence|confluence:%d:p3", srcID),
		fmt.Sprintf("confluence|confluence:%d:p1", otherSrc),
		fmt.Sprintf("confluence|confluence:%d:p2", otherSrc),
		fmt.Sprintf("confluence|confluence:%d:p3", otherSrc),
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
	assert.Equal(t, time.Date(2026, 11, 1, 0, 0, 0, 0, time.UTC), people[0].UpdatedAt,
		"the oldest fetch of a row naming the id: a fresher copy must not hide a stale one")
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

func TestRefreshAtlassianProfiles_UpdatesTheCaches(t *testing.T) {
	d := openTestDB(t)
	acct := SeedTestJiraAccount(t, d)
	seedAtlassianPeople(t, d, acct)
	at := time.Date(2026, 11, 18, 10, 0, 0, 0, time.UTC)

	require.NoError(t, d.RefreshAtlassianProfiles(context.Background(), []AtlassianProfile{
		{ID: keptID, DisplayName: "New Name"},
		{ID: "acme-unknown", DisplayName: "Nobody"},
	}, at))

	var name, email, slack string
	require.NoError(t, d.QueryRow(`SELECT display_name, email, slack_user_id FROM jira_user_map WHERE jira_account_id = ?`, keptID).Scan(&name, &email, &slack))
	assert.Equal(t, []string{"New Name", "p@example.com", "1:U0000001"}, []string{name, email, slack}, "a hidden email keeps the stored one; the Slack mapping stays")
	var fetched string
	require.NoError(t, d.QueryRow(`SELECT display_name, fetched_at FROM ext_users WHERE ext_user_id = ?`, keptID).Scan(&name, &fetched))
	assert.Equal(t, []string{"New Name", "2026-11-18T10:00:00Z"}, []string{name, fetched})
	assert.Zero(t, pdrCount(t, d, `SELECT count(*) FROM jira_user_map WHERE jira_account_id = 'acme-unknown'`), "no row is created")
}

// pickerJSON is a custom_fields_json value with one multi-user picker
// naming closedID between two live people, and a single-user picker naming
// the closed account alone.
const pickerJSON = `{"qa":"Closed Person","reviewers":"Ann, Closed Person, Bo","team":"Core",` +
	`"_people":{"qa":[{"id":"` + closedID + `","name":"Closed Person"}],` +
	`"reviewers":[{"id":"` + keptID + `","name":"Ann"},{"id":"` + closedID + `","name":"Closed Person"},{"id":"acme-kept-3","name":"Bo"}]}}`

// TestPDR_PickerOnlyPersonReportedAndErased: a person Watchtower knows only
// from a user-picker custom field (no column, no payload, no cache row
// names them) is reported, and a "closed" answer erases their name from the
// field — their single entry of a multi-user field included — keeping the
// bare id; the live people beside them stay.
func TestPDR_PickerOnlyPersonReportedAndErased(t *testing.T) {
	d := openTestDB(t)
	acct := SeedTestJiraAccount(t, d)
	other := SeedTestJiraAccount(t, d)
	for _, a := range []int64{acct, other} {
		_, err := d.Exec(`INSERT INTO jira_issues (account_id, key, project_key, summary, status, status_category, created_at, updated_at, synced_at, raw_json, custom_fields_json)
			VALUES (?, 'ACME-9', 'ACME', 's', 'Open', 'todo', '2026-11-01T00:00:00Z', '2026-11-01T00:00:00Z', '2026-11-04T00:00:00Z', '{"fields":{}}', ?)`, a, pickerJSON)
		require.NoError(t, err)
	}
	_, err := d.Exec(`INSERT INTO jira_issues (account_id, key, project_key, summary, status, status_category, created_at, updated_at, synced_at, custom_fields_json)
		VALUES (?, 'ACME-10', 'ACME', 's', 'Open', 'todo', '2026-11-01T00:00:00Z', '2026-11-01T00:00:00Z', '2026-11-04T00:00:00Z', 'not json')`, acct)
	require.NoError(t, err)

	people, err := d.AtlassianPeople(context.Background(), acct)
	require.NoError(t, err)
	got := map[string]time.Time{}
	for _, p := range people {
		got[p.ID] = p.UpdatedAt
	}
	assert.Equal(t, map[string]time.Time{
		closedID:      time.Date(2026, 11, 4, 0, 0, 0, 0, time.UTC),
		keptID:        time.Date(2026, 11, 4, 0, 0, 0, 0, time.UTC),
		"acme-kept-3": time.Date(2026, 11, 4, 0, 0, 0, 0, time.UTC),
	}, got, "a picker's people are reported, dated by the issue's sync")

	eraseAtlassian(t, d, acct, []string{closedID})

	var custom string
	require.NoError(t, d.QueryRow(`SELECT custom_fields_json FROM jira_issues WHERE account_id = ? AND key = 'ACME-9'`, acct).Scan(&custom))
	assert.JSONEq(t, `{"qa":"","reviewers":"Ann, Bo","team":"Core",
		"_people":{"qa":[{"id":"`+closedID+`","name":""}],
		"reviewers":[{"id":"`+keptID+`","name":"Ann"},{"id":"`+closedID+`","name":""},{"id":"acme-kept-3","name":"Bo"}]}}`, custom)
	assert.NotContains(t, custom, "Closed Person")
	require.NoError(t, d.QueryRow(`SELECT custom_fields_json FROM jira_issues WHERE account_id = ? AND key = 'ACME-9'`, other).Scan(&custom))
	assert.Equal(t, pickerJSON, custom, "another Jira account's rows are that account's erase")
	require.NoError(t, d.QueryRow(`SELECT custom_fields_json FROM jira_issues WHERE account_id = ? AND key = 'ACME-10'`, acct).Scan(&custom))
	assert.Equal(t, "not json", custom)

	people, err = d.AtlassianPeople(context.Background(), acct)
	require.NoError(t, err)
	assert.Len(t, people, 3, "the bare id stays stored and reported (Former user)")

	plan, err := d.PlanAtlassianErase(context.Background(), acct, []string{closedID})
	require.NoError(t, err)
	assert.Empty(t, plan.CustomFields, "a repeat erase has nothing left to rewrite")
}

// TestPDR_EraseBatchesManyIssues: more issues than one erase statement
// names (eraseChunk) are all erased — payloads, picker names and re-render
// marks — and an issue a sync rewrote after the plan read it is left to the
// next report instead of being overwritten with the stale edit.
func TestPDR_EraseBatchesManyIssues(t *testing.T) {
	d := openTestDB(t)
	acct := SeedTestJiraAccount(t, d)
	n := eraseChunk + 50
	for i := range n {
		_, err := d.Exec(`INSERT INTO jira_issues (account_id, key, project_key, summary, status, status_category, created_at, updated_at, synced_at, raw_json, custom_fields_json)
			VALUES (?, ?, 'ACME', 's', 'Open', 'todo', '2026-11-01T00:00:00Z', '2026-11-01T00:00:00Z', '2026-11-04T00:00:00Z', ?, ?)`,
			acct, fmt.Sprintf("ACME-%d", i+1), `{"fields":{"creator":{"accountId":"`+closedID+`"}}}`, pickerJSON)
		require.NoError(t, err)
	}
	ctx := context.Background()
	plan, err := d.PlanAtlassianErase(ctx, acct, []string{closedID})
	require.NoError(t, err)
	require.Len(t, plan.RawJSONKeys, n)
	require.Len(t, plan.CustomFields, n)
	_, err = d.Exec(`UPDATE jira_issues SET custom_fields_json = ? WHERE account_id = ? AND key = 'ACME-1'`, pickerJSON+" ", acct)
	require.NoError(t, err)

	require.NoError(t, d.WithTx(func(tx *sql.Tx) error { return d.EraseAtlassianPeople(ctx, tx, acct, []string{closedID}, plan) }))

	assert.Zero(t, pdrCount(t, d, `SELECT count(*) FROM jira_issues WHERE account_id = ? AND raw_json != ''`, acct))
	assert.Equal(t, 1, pdrCount(t, d, `SELECT count(*) FROM jira_issues WHERE account_id = ? AND instr(custom_fields_json, 'Closed Person') > 0`, acct),
		"only the issue rewritten since the plan keeps the name, for the next report")
	assert.Equal(t, 1, pdrCount(t, d, `SELECT count(*) FROM jira_issues WHERE account_id = ? AND key = 'ACME-1' AND custom_fields_json = ?`, acct, pickerJSON+" "))
	assert.Equal(t, n, pdrCount(t, d, `SELECT count(*) FROM kb_dirty WHERE source = 'jira'`))
}

func TestEraseCustomFieldPeople_LegacyRows(t *testing.T) {
	names := map[string]bool{"Closed Person": true}
	closed := map[string]bool{closedID: true}
	got, changed := eraseCustomFieldPeople(`{"qa":"Closed Person","team":"Core"}`, closed, names)
	assert.True(t, changed)
	assert.JSONEq(t, `{"qa":"","team":"Core"}`, got, "a row without ids still loses a whole-value name")
	got, changed = eraseCustomFieldPeople(`{"qa":"Closed Person"}`, closed, nil)
	assert.False(t, changed, "without a payload match, a row without ids is left alone (as before)")
	assert.Equal(t, `{"qa":"Closed Person"}`, got)
	got, changed = eraseCustomFieldPeople(`["Closed Person"]`, closed, names)
	assert.True(t, changed)
	assert.Equal(t, `[""]`, got, "a value that is not an object loses the quoted name")
}
