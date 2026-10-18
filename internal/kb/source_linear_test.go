package kb

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// seedLinear seeds one Linear issue (account 1) with two comments.
func seedLinear(t *testing.T, d *db.DB) {
	t.Helper()
	exec(t, d, `INSERT INTO linear_accounts (id, org_id, url_key, org_name) VALUES (1, 'org1', 'acme', 'Acme')`)
	exec(t, d, `INSERT INTO linear_issues (account_id, id, key, team_key, title, description_text, state_name, status_category,
		priority, assignee_display_name, labels, url, created_at, updated_at, synced_at)
		VALUES (1, 'u1', 'ENG-42', 'ENG', 'Importer rewrite', 'Переписать импортёр партнёров', 'In Progress', 'in_progress',
		2, 'Anna', '["backend"]', 'https://linear.app/acme/issue/ENG-42', '2026-04-01T09:00:00.000Z', '2026-04-20T09:00:00.000Z', '2026-04-20T11:00:01Z')`)
	exec(t, d, `INSERT INTO linear_comments (account_id, id, issue_id, issue_key, author_display_name, body_text, created_at, updated_at, synced_at)
		VALUES (1, 'lc2', 'u1', 'ENG-42', 'Bob', 'second', '2026-04-21T10:00:00.000Z', '2026-04-21T10:00:00.000Z', '2026-04-21T11:00:00Z'),
		       (1, 'lc1', 'u1', 'ENG-42', 'Anna', 'first', '2026-04-20T10:00:00.000Z', '2026-04-20T10:00:00.000Z', '2026-04-21T11:00:00Z')`)
}

func TestLinear_Build(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedLinear(t, d)
	doc, err := linearSource{}.Build(ctx, d, "linear:1:ENG-42")
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "linear", doc.Source)
	assert.Equal(t, "ENG-42 Importer rewrite", doc.Title)
	assert.Equal(t, map[string]string{"account_id": "1", "key": "ENG-42"}, doc.Anchor)
	assert.Equal(t, "https://linear.app/acme/issue/ENG-42", doc.Link)
	assert.Equal(t, "ENG In Progress High Anna backend", doc.Meta)
	require.Len(t, doc.Sections, 4)
	assert.Equal(t, "Importer rewrite\nStatus: In Progress · Assignee: Anna", doc.Sections[0].Text)
	assert.Equal(t, "Anna: first", doc.Sections[2].Text, "comments oldest first")
	assert.Equal(t, "lc2", doc.Sections[3].Anchor)
	assert.Equal(t, "2026-04-21T10:00:00Z", doc.Time.UTC().Format("2006-01-02T15:04:05Z"), "the newest comment dates the doc")

	for _, key := range []string{"linear:1:ENG-404", "linear:1", "linear::ENG-42", "jira:1:ENG-42"} {
		doc, err := linearSource{}.Build(ctx, d, key)
		require.NoError(t, err, key)
		assert.Nil(t, doc, key)
	}
}

// A team move re-keys the document: the new key is reported changed, the old
// key builds to nil, and Keys lists only the current one.
func TestLinear_TeamMoveRekeysTheDocument(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedLinear(t, d)
	exec(t, d, `UPDATE linear_issues SET key = 'OPS-3', team_key = 'OPS', previous_keys = '["ENG-42"]', synced_at = '2026-04-22T00:00:00Z' WHERE id = 'u1'`)

	keys, next, done, err := linearSource{}.Changed(ctx, d, "2026-04-21T12:00:00Z", testNow())
	require.NoError(t, err)
	assert.True(t, done)
	assert.Equal(t, []string{"linear:1:OPS-3"}, keys)
	assert.Equal(t, "2026-04-22T00:00:00Z", next)

	old, err := linearSource{}.Build(ctx, d, "linear:1:ENG-42")
	require.NoError(t, err)
	assert.Nil(t, old)
	all, err := linearSource{}.Keys(ctx, d)
	require.NoError(t, err)
	assert.Equal(t, []string{"linear:1:OPS-3"}, all)
}

// A new comment marks its issue's document changed.
func TestLinear_CommentChangeMarksTheIssue(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedLinear(t, d)
	exec(t, d, `UPDATE linear_comments SET synced_at = '2026-05-01T00:00:00Z' WHERE id = 'lc1'`)
	keys, _, _, err := linearSource{}.Changed(ctx, d, "2026-04-30T00:00:00Z", testNow())
	require.NoError(t, err)
	assert.Equal(t, []string{"linear:1:ENG-42"}, keys)
}
