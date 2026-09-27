package db

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func seedDocLink(t *testing.T, d *DB, fromKind, fromRef, toKind, toRef, detectedAt string) {
	t.Helper()
	_, err := d.Exec(`INSERT INTO doc_links (from_kind, from_ref, to_kind, to_ref, detected_at) VALUES (?, ?, ?, ?, ?)`,
		fromKind, fromRef, toKind, toRef, detectedAt)
	require.NoError(t, err)
}

func TestDocLinksToAndFrom(t *testing.T) {
	d := openTestDB(t)
	seedDocLink(t, d, "confluence", "confluence:1:p1", "jira_issue", "PROJ-1", "2026-09-01T10:00:00Z")
	seedDocLink(t, d, "confluence", "confluence:1:p2", "jira_issue", "PROJ-1", "2026-09-02T10:00:00Z")
	seedDocLink(t, d, "confluence", "confluence:1:p1", "jira_issue", "PROJ-2", "2026-09-01T10:00:00Z")
	seedDocLink(t, d, "slack", "slack:thread:1:C1:1.0", "confluence_page", "c1:42", "2026-09-01T10:00:00Z")

	to, err := d.DocLinksTo("jira_issue", "PROJ-1", 10)
	require.NoError(t, err)
	require.Len(t, to, 2)
	assert.Equal(t, "confluence:1:p2", to[0].FromRef, "newest first")
	assert.Equal(t, DocLink{FromKind: "confluence", FromRef: "confluence:1:p1", ToKind: "jira_issue", ToRef: "PROJ-1", DetectedAt: "2026-09-01T10:00:00Z"}, to[1])

	capped, err := d.DocLinksTo("jira_issue", "PROJ-1", 1)
	require.NoError(t, err)
	assert.Len(t, capped, 1)

	none, err := d.DocLinksTo("jira_issue", "NOPE-1", 10)
	require.NoError(t, err)
	assert.Empty(t, none)

	from, err := d.DocLinksFrom("confluence", "confluence:1:p1")
	require.NoError(t, err)
	require.Len(t, from, 2)
	assert.Equal(t, "PROJ-1", from[0].ToRef)
	assert.Equal(t, "PROJ-2", from[1].ToRef)
}

// explainDetails returns the EXPLAIN QUERY PLAN detail lines of query.
func explainDetails(t *testing.T, d *DB, query string, args ...any) string {
	t.Helper()
	rows, err := d.Query("EXPLAIN QUERY PLAN "+query, args...)
	require.NoError(t, err)
	defer rows.Close()
	var lines []string
	for rows.Next() {
		var id, parent, notused int
		var detail string
		require.NoError(t, rows.Scan(&id, &parent, &notused, &detail))
		lines = append(lines, detail)
	}
	require.NoError(t, rows.Err())
	return strings.Join(lines, "\n")
}

// The two doc_links readers are hot (get_task_context, every Confluence page
// render): each must seek its index, never scan the table.
func TestDocLinks_QueryPlansUseIndexes(t *testing.T) {
	d := openTestDB(t)
	to := explainDetails(t, d, docLinksToQuery, "jira_issue", "PROJ-1", 5)
	assert.Contains(t, to, "USING INDEX idx_doc_links_to (to_kind=? AND to_ref=?)")
	assert.NotContains(t, to, "SCAN doc_links")

	from := explainDetails(t, d, docLinksFromQuery, "confluence", "confluence:1:p1")
	assert.Contains(t, from, "USING INDEX sqlite_autoindex_doc_links_1 (from_kind=? AND from_ref=?)")
	assert.NotContains(t, from, "SCAN doc_links")
}

func TestExtDocumentBrief(t *testing.T) {
	d := openTestDB(t)
	acct, err := d.CreateJiraAccount(JiraAccount{CloudID: "c1", SiteURL: "https://acme.atlassian.net", Enabled: true, Status: "ok"})
	require.NoError(t, err)
	src, err := d.CreateExtSource("confluence", acct, "ENG", "100", "Engineering")
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO ext_documents (source_id, ext_id, kind, title, url, sections_json)
		VALUES (?, '1001', 'page', 'Payments design', 'https://acme.atlassian.net/wiki/spaces/ENG/pages/1001',
		        '[{"heading":"Intro","anchor":"Intro","text":"Covers PROJ-1."},{"heading":"","anchor":"","text":"Second part."}]')`, src)
	require.NoError(t, err)

	b, err := d.ExtDocumentBrief(src, "1001")
	require.NoError(t, err)
	require.NotNil(t, b)
	assert.Equal(t, "Payments design", b.Title)
	assert.Equal(t, "https://acme.atlassian.net/wiki/spaces/ENG/pages/1001", b.URL)
	assert.Equal(t, "ENG", b.Space)
	assert.Equal(t, "Covers PROJ-1.\nSecond part.", b.Text)

	missing, err := d.ExtDocumentBrief(src, "gone")
	require.NoError(t, err)
	assert.Nil(t, missing)
}

// Unselecting a space drops the links its documents made; another source's
// links (whose ref shares the digit prefix) and inbound links stay.
func TestDeleteExtSource_DropsItsOutboundLinks(t *testing.T) {
	d := openTestDB(t)
	acct, err := d.CreateJiraAccount(JiraAccount{CloudID: "c1", SiteURL: "https://acme.atlassian.net", Enabled: true, Status: "ok"})
	require.NoError(t, err)
	src, err := d.CreateExtSource("confluence", acct, "ENG", "100", "Engineering")
	require.NoError(t, err)
	require.Equal(t, int64(1), src)
	seedDocLink(t, d, "confluence", "confluence:1:p1", "jira_issue", "PROJ-1", "2026-09-01T10:00:00Z")
	seedDocLink(t, d, "confluence", "confluence:10:p1", "jira_issue", "PROJ-1", "2026-09-01T10:00:00Z")
	seedDocLink(t, d, "slack", "slack:thread:1:C1:1.0", "confluence_page", "c1:42", "2026-09-01T10:00:00Z")

	require.NoError(t, d.DeleteExtSource(src))

	var refs []string
	rows, err := d.Query(`SELECT from_ref FROM doc_links ORDER BY from_ref`)
	require.NoError(t, err)
	defer rows.Close()
	for rows.Next() {
		var r string
		require.NoError(t, rows.Scan(&r))
		refs = append(refs, r)
	}
	require.NoError(t, rows.Err())
	assert.Equal(t, []string{"confluence:10:p1", "slack:thread:1:C1:1.0"}, refs)
}
