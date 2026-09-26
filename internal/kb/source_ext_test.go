package kb

import (
	"context"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

const confluencePageRef = "confluence:1:101"

// seedConfluence seeds one Confluence space with a two-section page (one
// heading section, one mention), an inline + a footer comment, an attachment
// with no extracted text, and two users.
func seedConfluence(t *testing.T, d *db.DB) {
	t.Helper()
	exec(t, d, `INSERT INTO jira_accounts (id, cloud_id, site_url) VALUES (7, 'c7', 'https://acme.atlassian.net/')`)
	exec(t, d, `INSERT INTO ext_sources (id, provider, jira_account_id, container_key, container_ext_id, container_name)
		VALUES (1, 'confluence', 7, 'ENG', '10', 'Engineering')`)
	exec(t, d, `INSERT INTO ext_documents (source_id, ext_id, kind, title, url, version, status, author_id,
		created_at, modified_at, sections_json, meta_json, synced_at) VALUES
		(1, '101', 'page', 'Release runbook', 'https://acme.atlassian.net/wiki/spaces/ENG/pages/101', 3, 'current', 'u1',
		 '2026-09-01T10:00:00Z', '2026-09-20T10:00:00Z', ?, ?, '2026-09-20T11:00:00Z')`,
		`[{"text":"Intro: деплой через канарейку"},{"heading":"Release plan","anchor":"Release-plan","text":"Release plan\nOwner @[~u1], reviewer @[~ghost]"}]`,
		`{"space":"ENG","status":"current","labels":"release, ops","ancestors":"Handbook / Ops"}`)
	exec(t, d, `INSERT INTO ext_documents (source_id, ext_id, kind, parent_ext_id, title, url, version, status, author_id,
		modified_at, sections_json, media_type, extract_status, synced_at) VALUES
		(1, 'att9', 'attachment', '101', 'diagram.png', 'https://acme.atlassian.net/wiki/att9', 1, 'current', 'u2',
		 '2026-09-19T10:00:00Z', '[]', 'image/png', 'ocr_unavailable', '2026-09-21T11:00:00Z')`)
	exec(t, d, `INSERT INTO ext_comments (source_id, ext_id, page_ext_id, kind, author_id, created_at, version, body_text, anchor_text, resolved) VALUES
		(1, '500', '101', 'inline', 'u2', '2026-09-21T10:00:00Z', 1, 'а откат? спроси @[~u1]', 'канарейку', 1),
		(1, '501', '101', 'footer', 'u2', '2026-09-22T10:00:00Z', 1, 'согласовано', '', 0)`)
	exec(t, d, `INSERT INTO ext_users (provider, ext_user_id, display_name, fetched_at) VALUES
		('confluence', 'u1', 'Alice', '2026-09-20T11:00:00Z'),
		('confluence', 'u2', 'Bob', '2026-09-20T11:00:00Z')`)
}

func chunkBodies(t *testing.T, d *db.DB, docID string) string {
	t.Helper()
	return dumpRows(t, d, `SELECT body, anchor FROM kb_chunks WHERE doc_id = '`+docID+`' ORDER BY idx`)
}

// passCursorBeyondPage syncs the attachment later than the page and runs
// the source, so the stored cursor is strictly past the page's markers.
func passCursorBeyondPage(t *testing.T, d *db.DB) {
	t.Helper()
	exec(t, d, `UPDATE ext_documents SET synced_at = '2026-09-24T00:00:00Z' WHERE ext_id = 'att9'`)
	_, err := Run(context.Background(), d, Options{Sources: []string{"confluence"}, Now: testNow()})
	require.NoError(t, err)
	var cursor string
	require.NoError(t, d.QueryRow(`SELECT cursor FROM kb_sources WHERE source = 'confluence'`).Scan(&cursor))
	require.Equal(t, "2026-09-24T00:00:00Z", cursor)
}

func TestConfluence_BuildPage(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedConfluence(t, d)
	doc, err := extSource{provider: "confluence"}.Build(ctx, d, confluencePageRef)
	require.NoError(t, err)
	require.NotNil(t, doc)
	assert.Equal(t, "confluence", doc.Source)
	assert.Equal(t, "Release runbook", doc.Title)
	assert.Equal(t, "https://acme.atlassian.net/wiki/spaces/ENG/pages/101", doc.Link)
	assert.Equal(t, map[string]string{"source_id": "1", "ext_id": "101", "space": "ENG"}, doc.Anchor)
	assert.Equal(t, "2026-09-20T10:00:00Z", doc.Time.Format("2006-01-02T15:04:05Z"))
	for _, m := range []string{"Engineering", "ENG", "Handbook / Ops", "release, ops", "Alice"} {
		assert.Contains(t, doc.Meta, m)
	}
	assert.NotContains(t, doc.Meta, "archived")

	require.Len(t, doc.Sections, 4)
	assert.Equal(t, "101", doc.Sections[0].Anchor, "a section without a heading anchor points at the page id")
	assert.Equal(t, "https://acme.atlassian.net/wiki/spaces/ENG/pages/101#Release-plan", doc.Sections[1].Anchor)
	assert.Equal(t, "Release plan\nOwner @Alice, reviewer @user", doc.Sections[1].Text, "mention tokens resolve; unknown → @user")
	assert.Equal(t, "Bob on “канарейку”: а откат? спроси @Alice (resolved)", doc.Sections[2].Text)
	assert.Equal(t, "https://acme.atlassian.net/wiki/spaces/ENG/pages/101?focusedCommentId=500", doc.Sections[2].Anchor)
	assert.Equal(t, "Bob: согласовано", doc.Sections[3].Text)
}

func TestConfluence_BuildArchivedAndAttachment(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedConfluence(t, d)
	exec(t, d, `UPDATE ext_documents SET status = 'archived' WHERE ext_id = '101'`)
	src := extSource{provider: "confluence"}
	page, err := src.Build(ctx, d, confluencePageRef)
	require.NoError(t, err)
	assert.Contains(t, page.Meta, "archived")

	att, err := src.Build(ctx, d, "confluence:1:att9")
	require.NoError(t, err)
	require.NotNil(t, att)
	assert.Equal(t, "diagram.png", att.Title)
	assert.Empty(t, att.Sections, "no extracted text: the title-only rule indexes the name")
	for _, m := range []string{"Release runbook", "Engineering", "ENG", "image/png", "ocr_unavailable"} {
		assert.Contains(t, att.Meta, m)
	}
	assert.Equal(t, "https://acme.atlassian.net/wiki/att9", att.Link)

	exec(t, d, `UPDATE ext_documents SET extract_status = 'ok' WHERE ext_id = 'att9'`)
	att, err = src.Build(ctx, d, "confluence:1:att9")
	require.NoError(t, err)
	assert.NotContains(t, strings.Fields(att.Meta), "ok", "extract_status is listed only when not ok")
}

func TestConfluence_BuildMissingOrMalformedIsNil(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedConfluence(t, d)
	src := extSource{provider: "confluence"}
	for _, key := range []string{"confluence:1:nope", "confluence:2:101", "confluence:x:101", "confluence:1", "jira:1:101", "confluence::101"} {
		doc, err := src.Build(ctx, d, key)
		require.NoError(t, err, key)
		assert.Nil(t, doc, key)
	}
}

// End to end through kb.Run: index, rename a user, delete the page.
func TestConfluence_RunRenameDeleteSearch(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedConfluence(t, d)
	_, err := Run(ctx, d, Options{Sources: []string{"confluence"}, Now: testNow()})
	require.NoError(t, err)
	assert.Equal(t, 2, countDocs(t, d, "confluence"))

	var title, link, meta string
	require.NoError(t, d.QueryRow(`SELECT title, link, meta FROM kb_documents WHERE id = ?`, confluencePageRef).Scan(&title, &link, &meta))
	assert.Equal(t, "Release runbook", title)
	assert.Equal(t, "https://acme.atlassian.net/wiki/spaces/ENG/pages/101", link)
	assert.Contains(t, meta, "Engineering")

	chunks := chunkBodies(t, d, confluencePageRef)
	assert.Contains(t, chunks, "согласовано", "comment text is indexed")
	assert.Contains(t, chunks, "@Alice")
	assert.NotContains(t, chunks, "@[~")
	var anchor string
	require.NoError(t, d.QueryRow(`SELECT anchor FROM kb_chunks WHERE doc_id = ? AND idx = 0`, confluencePageRef).Scan(&anchor))
	assert.Equal(t, "101", anchor)

	// A long first section pushes the heading into its own chunk, whose
	// anchor is the heading deep link.
	exec(t, d, `UPDATE ext_documents SET sections_json = ?, synced_at = '2026-09-21T11:00:00Z' WHERE ext_id = '101'`,
		`[{"text":"`+strings.Repeat("канарейка ", 198)+`"},{"heading":"Release plan","anchor":"Release-plan","text":"Release plan\nOwner @[~u1]"}]`)
	_, err = Run(ctx, d, Options{Sources: []string{"confluence"}, Now: testNow()})
	require.NoError(t, err)
	require.NoError(t, d.QueryRow(`SELECT anchor FROM kb_chunks WHERE doc_id = ? AND body LIKE 'Release plan%'`, confluencePageRef).Scan(&anchor))
	assert.True(t, strings.HasSuffix(anchor, "#Release-plan"), anchor)

	// A renamed user re-renders the documents they authored (the page is
	// authored by u1), with no change to the document row itself. First move
	// the cursor past the page's own synced_at, so only the users arm can
	// list it (cursors compare with >=, which would re-list it otherwise).
	passCursorBeyondPage(t, d)
	exec(t, d, `UPDATE ext_users SET display_name = 'Alicia', fetched_at = '2026-09-25T11:00:00Z' WHERE ext_user_id = 'u1'`)
	_, err = Run(ctx, d, Options{Sources: []string{"confluence"}, Now: testNow()})
	require.NoError(t, err)
	chunks = chunkBodies(t, d, confluencePageRef)
	assert.Contains(t, chunks, "@Alicia")
	assert.NotContains(t, chunks, "@Alice")

	res, err := Search(ctx, d, Request{Queries: []string{"согласовано"}, Now: testNow()})
	require.NoError(t, err)
	require.Len(t, res.Hits, 1)
	assert.Equal(t, "confluence", res.Hits[0].Source)
	assert.Equal(t, confluencePageRef, res.Hits[0].Ref)

	exec(t, d, `DELETE FROM ext_documents WHERE ext_id = '101'`)
	_, err = Run(ctx, d, Options{Sources: []string{"confluence"}, Now: testNow()})
	require.NoError(t, err)
	assert.Equal(t, 1, countDocs(t, d, "confluence"), "the reconcile drops the deleted page within one run")
}

// A renamed comment author re-renders the page the comment sits on.
func TestConfluence_CommentAuthorRenameReRenders(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedConfluence(t, d)
	_, err := Run(ctx, d, Options{Sources: []string{"confluence"}, Now: testNow()})
	require.NoError(t, err)
	passCursorBeyondPage(t, d)
	exec(t, d, `UPDATE ext_users SET display_name = 'Robert', fetched_at = '2026-09-25T11:00:00Z' WHERE ext_user_id = 'u2'`)
	_, err = Run(ctx, d, Options{Sources: []string{"confluence"}, Now: testNow()})
	require.NoError(t, err)
	assert.Contains(t, chunkBodies(t, d, confluencePageRef), "Robert: согласовано")
}

func TestConfluence_ChangedSeesChildrenChangedAt(t *testing.T) {
	ctx := context.Background()
	d := db.OpenTestDB(t)
	seedConfluence(t, d)
	exec(t, d, `UPDATE ext_documents SET children_changed_at = '2026-09-23T09:00:00Z' WHERE ext_id = '101'`)
	keys, next, done, err := extSource{provider: "confluence"}.Changed(ctx, d, "2026-09-22T00:00:00Z", testNow())
	require.NoError(t, err)
	assert.True(t, done)
	assert.Equal(t, []string{confluencePageRef}, keys)
	assert.Equal(t, "2026-09-23T09:00:00Z", next)
}
