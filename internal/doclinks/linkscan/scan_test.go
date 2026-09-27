package linkscan

import (
	"context"
	"fmt"
	"sort"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/doclinks"
	"watchtower/internal/kb"
)

const pageURL = "https://acme.atlassian.net/wiki/spaces/ENG/pages/"

// A clock well past every fixture's synced_at (2026-09-20T10:00:0xZ).
var afterFixtures = time.Date(2026, 9, 20, 11, 0, 0, 0, time.UTC)

func exec(t *testing.T, d *db.DB, q string, args ...any) {
	t.Helper()
	_, err := d.Exec(q, args...)
	require.NoError(t, err, q)
}

// seedSite connects one Jira site (acme → c1) and selects one enabled
// Confluence space on it, holding page 1001.
func seedSite(t *testing.T, d *db.DB) {
	t.Helper()
	exec(t, d, `INSERT INTO jira_accounts (id, cloud_id, site_url) VALUES (1, 'c1', 'https://acme.atlassian.net/')`)
	_, err := d.CreateExtSource("confluence", 1, "ENG", "100", "Engineering")
	require.NoError(t, err)
	exec(t, d, `INSERT INTO ext_documents (source_id, ext_id, kind, title, url) VALUES (1, '1001', 'page', 'Payments design', ?)`,
		pageURL+"1001")
}

// seedMentions writes one mention of page 1001 per scanned kind (plus rows
// that must not link: a foreign host, a tiny link, a deleted message).
func seedMentions(t *testing.T, d *db.DB) {
	t.Helper()
	// Slack: a thread reply (Slack's <url|label> markup) and a top-level message.
	exec(t, d, `INSERT INTO messages (channel_id, ts, user_id, text, thread_ts) VALUES
		('1:C1', '1758000000.000100', '1:U1', 'kickoff', '1758000000.000100'),
		('1:C1', '1758000100.000200', '1:U2', 'spec: <`+pageURL+`1001/Payments+design|Payments design>', '1758000000.000100'),
		('1:C2', '1758003600.000300', '1:U1', 'also `+pageURL+`1001', NULL),
		('1:C2', '1758003700.000400', '1:U1', 'foreign https://other.atlassian.net/wiki/spaces/X/pages/5', NULL),
		('1:C2', '1758003800.000500', '1:U1', 'tiny https://acme.atlassian.net/wiki/x/AbCd', NULL),
		('1:C2', '1758003900.000600', '1:U1', 'deleted `+pageURL+`1001', NULL)`)
	exec(t, d, `UPDATE messages SET is_deleted = 1 WHERE ts = '1758003900.000600'`)
	exec(t, d, `INSERT INTO google_accounts (id, email) VALUES (1, 'me@example.com')`)
	exec(t, d, `INSERT INTO gmail_messages (account_id, id, thread_id, subject, body_text, synced_at, updated_at) VALUES
		(1, 'm1', 't1', 'Design review', 'Please read `+pageURL+`1001/Payments', '2026-09-20T10:00:01Z', '2026-09-20T10:00:01Z'),
		(1, 'm2', '', 'Threadless', 'and `+pageURL+`1001', '2026-09-20T10:00:01Z', '2026-09-20T10:00:01Z')`)
	exec(t, d, `INSERT INTO email_accounts (id, provider, email_address) VALUES (1, 'imap', 'me@example.com')`)
	exec(t, d, `INSERT INTO imap_messages (account_id, uid, uidvalidity, subject, body_text, synced_at, updated_at) VALUES
		(1, 42, 7, 'Fwd', 'link `+pageURL+`1001', '2026-09-20T10:00:02Z', '2026-09-20T10:00:02Z')`)
	exec(t, d, `INSERT INTO jira_issues (account_id, key, project_key, summary, description_text, status, status_category, created_at, updated_at, synced_at) VALUES
		(1, 'PROJ-1', 'PROJ', 'Build it', 'Design: `+pageURL+`1001', 'Open', 'new', '2026-09-01', '2026-09-01', '2026-09-20T10:00:03Z'),
		(1, 'PROJ-2', 'PROJ', 'Other', 'nothing here', 'Open', 'new', '2026-09-01', '2026-09-01', '2026-09-20T10:00:03Z')`)
	exec(t, d, `INSERT INTO jira_comments (account_id, issue_key, id, body_text, synced_at) VALUES
		(1, 'PROJ-2', 'c9', 'see `+pageURL+`1001', '2026-09-20T10:00:04Z')`)
}

// wantRefs is every document seedMentions makes mention page c1:1001.
var wantRefs = []string{
	"gmail:1:m:m2",
	"gmail:1:t1",
	"imap:1:7:42",
	"jira:1:PROJ-1",
	"jira:1:PROJ-2",
	"slack:day:1:C2:2025-09-16",
	"slack:thread:1:C1:1758000000.000100",
}

func inboundRefs(t *testing.T, d *db.DB) []string {
	t.Helper()
	links, err := d.DocLinksTo(doclinks.ToConfluencePage, "c1:1001", 100)
	require.NoError(t, err)
	var out []string
	for _, l := range links {
		out = append(out, l.FromRef)
	}
	sort.Strings(out)
	return out
}

func linkCount(t *testing.T, d *db.DB) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM doc_links`).Scan(&n))
	return n
}

func cursors(t *testing.T, d *db.DB) map[string]string {
	t.Helper()
	rows, err := d.Query(`SELECT from_kind, cursor FROM ext_link_state`)
	require.NoError(t, err)
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var k, c string
		require.NoError(t, rows.Scan(&k, &c))
		out[k] = c
	}
	require.NoError(t, rows.Err())
	return out
}

func TestScanSources_LinksEveryKindToItsKnowledgeRef(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSite(t, d)
	seedMentions(t, d)

	st, err := scan(ctx, d, scanOptions{batch: 1000, now: afterFixtures})
	require.NoError(t, err)
	assert.Equal(t, len(wantRefs), st.Linked)
	assert.False(t, st.Incomplete)
	assert.Equal(t, wantRefs, inboundRefs(t, d))
	assert.Equal(t, len(wantRefs), linkCount(t, d), "foreign host, tiny link and deleted message make no link")

	// Every from_ref is the id of the knowledge document search returns.
	_, err = kb.Run(ctx, d, kb.Options{Sources: []string{"slack", "gmail", "imap", "jira"}, Now: afterFixtures})
	require.NoError(t, err)
	for _, ref := range wantRefs {
		var n int
		require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM kb_documents WHERE id = ?`, ref).Scan(&n))
		assert.Equal(t, 1, n, "from_ref %s must be a kb_documents id", ref)
	}
}

// A new inbound link stamps the linked page, so the knowledge index
// re-renders its "Discussed in" meta; re-seeing the same link does not.
func TestScanSources_StampsTheLinkedPage(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSite(t, d)
	seedMentions(t, d)
	_, err := scan(ctx, d, scanOptions{batch: 1000, now: afterFixtures})
	require.NoError(t, err)
	var stamp string
	require.NoError(t, d.QueryRow(`SELECT children_changed_at FROM ext_documents WHERE ext_id = '1001'`).Scan(&stamp))
	assert.NotEmpty(t, stamp)

	// A rescan from empty cursors re-sees only known links: no stamp.
	exec(t, d, `UPDATE ext_documents SET children_changed_at = ''`)
	exec(t, d, `DELETE FROM ext_link_state`)
	st, err := scan(ctx, d, scanOptions{batch: 1000, now: afterFixtures})
	require.NoError(t, err)
	assert.Zero(t, st.Linked)
	require.NoError(t, d.QueryRow(`SELECT children_changed_at FROM ext_documents WHERE ext_id = '1001'`).Scan(&stamp))
	assert.Empty(t, stamp)
}

// Tiny budget: every call runs exactly one batch, the cursor resumes where
// the previous call stopped, and the scan converges on the same links.
func TestScanSources_ResumesAcrossCallsWithATinyBudget(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSite(t, d)
	seedMentions(t, d)

	opt := scanOptions{batch: 2, budget: time.Nanosecond, now: afterFixtures}
	first, err := scan(ctx, d, opt)
	require.NoError(t, err)
	assert.True(t, first.Incomplete)
	assert.Equal(t, 2, first.Scanned, "one batch per call")
	assert.Less(t, linkCount(t, d), len(wantRefs))

	calls := 1
	for ; calls < 50; calls++ {
		st, err := scan(ctx, d, opt)
		require.NoError(t, err)
		if !st.Incomplete {
			break
		}
	}
	require.Less(t, calls, 50, "the scan must converge")
	assert.Equal(t, wantRefs, inboundRefs(t, d))
}

// An idle install re-scans nothing: the second run reads zero rows and
// leaves every cursor where it was.
func TestScanSources_IdleInstallScansNothing(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSite(t, d)
	seedMentions(t, d)
	_, err := scan(ctx, d, scanOptions{batch: 1000, now: afterFixtures})
	require.NoError(t, err)
	before := cursors(t, d)
	require.Len(t, before, 5, "slack, gmail, imap, jira_issue, jira_comment")

	st, err := scan(ctx, d, scanOptions{batch: 1000, budget: time.Second, now: afterFixtures.Add(time.Hour)})
	require.NoError(t, err)
	assert.Zero(t, st.Scanned)
	assert.Equal(t, before, cursors(t, d))
}

// More rows share one synced_at second than a batch holds: the compound
// (synced_at, rowid) cursor walks through them all and then goes idle —
// a ">= synced_at" cursor would re-list the second forever.
func TestScanSources_SharedSecondLargerThanABatch(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSite(t, d)
	exec(t, d, `INSERT INTO google_accounts (id, email) VALUES (1, 'me@example.com')`)
	for i := range 7 {
		exec(t, d, `INSERT INTO gmail_messages (account_id, id, thread_id, body_text, synced_at) VALUES (1, ?, ?, ?, '2026-09-20T10:00:00Z')`,
			fmt.Sprintf("m%d", i), fmt.Sprintf("t%d", i), pageURL+"1001")
	}
	st, err := scan(ctx, d, scanOptions{batch: 2, budget: time.Second, now: afterFixtures})
	require.NoError(t, err)
	assert.Equal(t, 7, st.Scanned)
	assert.Equal(t, 7, st.Linked)

	again, err := scan(ctx, d, scanOptions{batch: 2, budget: time.Second, now: afterFixtures})
	require.NoError(t, err)
	assert.Zero(t, again.Scanned)
}

// A row stamped in the current (still open) second waits for the next
// cycle: another write could still land in that second behind the cursor.
func TestScanSources_OnlyClosedSeconds(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSite(t, d)
	exec(t, d, `INSERT INTO google_accounts (id, email) VALUES (1, 'me@example.com')`)
	now := time.Date(2026, 9, 20, 10, 0, 0, 500_000_000, time.UTC)
	exec(t, d, `INSERT INTO gmail_messages (account_id, id, thread_id, body_text, synced_at) VALUES (1, 'm1', 't1', ?, '2026-09-20T10:00:00Z')`,
		pageURL+"1001")

	st, err := scan(ctx, d, scanOptions{batch: 10, now: now})
	require.NoError(t, err)
	assert.Zero(t, st.Scanned, "10:00:00 is not over at 10:00:00.5")

	st, err = scan(ctx, d, scanOptions{batch: 10, now: now.Add(time.Second)})
	require.NoError(t, err)
	assert.Equal(t, 1, st.Linked)
}

// Messages added after the first scan are picked up by the next; a Slack
// cursor past the end of the table (messages wiped or restored) restarts.
func TestScanSources_SlackCursor(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedSite(t, d)
	exec(t, d, `INSERT INTO messages (channel_id, ts, text) VALUES ('1:C1', '1758000000.000100', ?)`, pageURL+"1001")
	_, err := scan(ctx, d, scanOptions{batch: 10, now: afterFixtures})
	require.NoError(t, err)
	exec(t, d, `INSERT INTO messages (channel_id, ts, text) VALUES ('1:C1', '1758090000.000100', ?)`, pageURL+"1002")
	st, err := scan(ctx, d, scanOptions{batch: 10, now: afterFixtures})
	require.NoError(t, err)
	assert.Equal(t, 1, st.Scanned, "only the new message")
	assert.Equal(t, 1, st.Linked)

	exec(t, d, `UPDATE ext_link_state SET cursor = '999999' WHERE from_kind = 'slack'`)
	st, err = scan(ctx, d, scanOptions{batch: 10, now: afterFixtures})
	require.NoError(t, err)
	assert.Equal(t, 2, st.Scanned, "a cursor past MAX(rowid) restarts from the top")
}

// The skip rule: without an enabled Confluence source, or without a
// connected site, the scan reads nothing and writes no cursor — so an
// install that never selects a space never walks its Slack history, and one
// that does later backfills from the start.
func TestScanSources_SkippedWithoutSourceOrSite(t *testing.T) {
	ctx := context.Background()
	cases := map[string]func(t *testing.T, d *db.DB){
		"no source": func(t *testing.T, d *db.DB) {
			exec(t, d, `INSERT INTO jira_accounts (id, cloud_id, site_url) VALUES (1, 'c1', 'https://acme.atlassian.net/')`)
		},
		"source disabled": func(t *testing.T, d *db.DB) {
			seedSite(t, d)
			exec(t, d, `UPDATE ext_sources SET enabled = 0`)
		},
		"site removed": func(t *testing.T, d *db.DB) {
			seedSite(t, d)
			exec(t, d, `UPDATE jira_accounts SET status = 'removed'`)
		},
	}
	for name, setup := range cases {
		t.Run(name, func(t *testing.T) {
			d := db.OpenTestDB(t)
			setup(t, d)
			exec(t, d, `INSERT INTO messages (channel_id, ts, text) VALUES ('1:C1', '1758000000.000100', ?)`, pageURL+"1001")
			st, err := scan(ctx, d, scanOptions{batch: 10, now: afterFixtures})
			require.NoError(t, err)
			assert.Zero(t, st.Scanned)
			assert.Empty(t, cursors(t, d))
			assert.Zero(t, linkCount(t, d))
		})
	}
}

func TestScanSources_PublicWrapper(t *testing.T) {
	d := db.OpenTestDB(t)
	seedSite(t, d)
	seedMentions(t, d)
	n, err := ScanSources(context.Background(), d, time.Minute)
	require.NoError(t, err)
	assert.Equal(t, len(wantRefs), n)
}

// explainDetails returns the EXPLAIN QUERY PLAN detail lines of query.
func explainDetails(t *testing.T, d *db.DB, query string, args ...any) string {
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
	return fmt.Sprint(lines)
}

// Every per-kind scan query seeks an index and needs no sort: a batch costs
// its 1000 rows, never a walk over the table (~750k Slack messages).
func TestScanSources_QueryPlansSeekIndexes(t *testing.T) {
	d := db.OpenTestDB(t)
	slack := explainDetails(t, d, slackScanQuery, 0, 1000)
	assert.Contains(t, slack, "SEARCH messages USING INTEGER PRIMARY KEY (rowid>?)")
	assert.NotContains(t, slack, "TEMP B-TREE")

	synced := map[string]struct{ query, index string }{
		"gmail":        {gmailScanQuery, "idx_gmail_messages_synced"},
		"imap":         {imapScanQuery, "idx_imap_messages_synced"},
		"jira_issue":   {jiraIssueScanQuery, "idx_jira_issues_synced"},
		"jira_comment": {jiraCommentScanQuery, "idx_jira_comments_synced"},
	}
	for name, c := range synced {
		plan := explainDetails(t, d, c.query, "", "2026-09-20T10:00:00Z", "", 0, 1000)
		assert.Contains(t, plan, "USING INDEX "+c.index+" (synced_at>? AND synced_at<?)", name)
		assert.NotContains(t, plan, "TEMP B-TREE", name)
	}
}

func TestScanSources_CancelledContextStops(t *testing.T) {
	d := db.OpenTestDB(t)
	seedSite(t, d)
	seedMentions(t, d)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := scan(ctx, d, scanOptions{batch: 1000, now: afterFixtures})
	require.ErrorIs(t, err, context.Canceled)
	assert.Zero(t, linkCount(t, d))
}
