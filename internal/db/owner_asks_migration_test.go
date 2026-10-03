package db

import (
	"path/filepath"
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestMigration00100_DropsDocumentsAndTheirComments: target comments and their
// replies survive the project_comments rebuild; document comments, every reply
// under them, project_documents and the documents' index entries (FTS included)
// are gone; a deleted comment's id is never handed out again.
func TestMigration00100_DropsDocumentsAndTheirComments(t *testing.T) {
	raw := rawDBAt(t, 99)
	_, err := raw.Exec(`INSERT INTO projects (id, name, folder_path) VALUES (1, 'acme', '/tmp/acme')`)
	require.NoError(t, err)
	_, err = raw.Exec(`INSERT INTO targets (id, text, period_start, period_end, project_id)
		VALUES (11, 'board item', '2026-09-29', '2026-09-29', 1)`)
	require.NoError(t, err)
	_, err = raw.Exec(`INSERT INTO project_documents (id, project_id, rel_path, kind) VALUES (21, 1, 'docs/spec.md', 'spec')`)
	require.NoError(t, err)
	for _, c := range []struct {
		id               int64
		target, doc, par any
	}{
		{100, 11, nil, nil},  // target root
		{101, nil, nil, 100}, // its reply
		{102, nil, 21, nil},  // document root
		{103, nil, nil, 102}, // its reply
		{104, nil, nil, 103}, // a reply to the reply
		{110, nil, 21, nil},  // the newest comment, on the document
	} {
		_, err = raw.Exec(`INSERT INTO project_comments (id, project_id, target_id, document_id, parent_id, author, body, anchor_quote)
			VALUES (?, 1, ?, ?, ?, 'owner', 'text', 'quote')`, c.id, c.target, c.doc, c.par)
		require.NoError(t, err)
	}
	for _, doc := range []struct{ id, source, body string }{
		{"project_doc:1", "project_doc", "zanzibarquux rollout"},
		{"slack:1", "slack", "keepword rollout"},
	} {
		_, err = raw.Exec(`INSERT INTO kb_documents (id, source, title) VALUES (?, ?, 'doc')`, doc.id, doc.source)
		require.NoError(t, err)
		_, err = raw.Exec(`INSERT INTO kb_chunks (doc_id, idx, body) VALUES (?, 0, ?)`, doc.id, doc.body)
		require.NoError(t, err)
	}

	require.NoError(t, goose.Up(raw, "migrations"))

	commentIDs := func() []int64 {
		t.Helper()
		rows, err := raw.Query(`SELECT id FROM project_comments ORDER BY id`)
		require.NoError(t, err)
		defer rows.Close()
		var ids []int64
		for rows.Next() {
			var id int64
			require.NoError(t, rows.Scan(&id))
			ids = append(ids, id)
		}
		require.NoError(t, rows.Err())
		return ids
	}
	assert.Equal(t, []int64{100, 101}, commentIDs(), "target comments stay, document threads go")

	cols := columnNames(t, raw, "project_comments")
	for _, c := range []string{"document_id", "anchor_quote", "anchor_prefix", "anchor_suffix", "anchor_heading"} {
		assert.False(t, cols[c], "project_comments.%s is dropped", c)
	}
	for _, c := range []string{"id", "project_id", "target_id", "parent_id", "author", "agent_label", "body", "status", "created_at", "read_at"} {
		assert.True(t, cols[c], "project_comments.%s is kept", c)
	}
	count := func(q string, args ...any) int {
		t.Helper()
		var n int
		require.NoError(t, raw.QueryRow(q, args...).Scan(&n))
		return n
	}
	assert.Zero(t, count(`SELECT COUNT(*) FROM sqlite_master WHERE name IN ('project_documents', 'idx_project_documents_target', 'idx_project_comments_document')`))
	for _, idx := range []string{"idx_project_comments_project", "idx_project_comments_target", "idx_project_comments_parent",
		"idx_owner_asks_project", "idx_owner_asks_session"} {
		assert.Equal(t, 1, count(`SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ?`, idx), idx)
	}

	assert.Zero(t, count(`SELECT COUNT(*) FROM kb_documents WHERE source = 'project_doc'`))
	assert.Zero(t, count(`SELECT COUNT(*) FROM kb_chunks WHERE doc_id = 'project_doc:1'`))
	assert.Zero(t, count(`SELECT COUNT(*) FROM kb_fts WHERE kb_fts MATCH 'zanzibarquux'`), "the FTS rows go with the chunks")
	assert.Equal(t, 1, count(`SELECT COUNT(*) FROM kb_fts WHERE kb_fts MATCH 'keepword'`), "other sources are untouched")

	assert.Equal(t, 1, count(`PRAGMA foreign_keys`), "foreign keys are back on")
	assert.Zero(t, count(`SELECT COUNT(*) FROM pragma_foreign_key_check`))

	_, err = raw.Exec(`INSERT INTO project_comments (project_id, author, body) VALUES (1, 'owner', 'orphan')`)
	assert.Error(t, err, "a comment needs a target or a parent")
	res, err := raw.Exec(`INSERT INTO project_comments (project_id, target_id, author, body) VALUES (1, 11, 'owner', 'next')`)
	require.NoError(t, err)
	next, err := res.LastInsertId()
	require.NoError(t, err)
	assert.Greater(t, next, int64(110), "a deleted document comment's id is never reused")

	_, err = raw.Exec(`DELETE FROM project_comments WHERE id = 100`)
	require.NoError(t, err)
	assert.Zero(t, count(`SELECT COUNT(*) FROM project_comments WHERE id = 101`), "the parent cascade survives the rebuild")
}

// TestMigration00100_DownUpIsClean: the Down brings back the empty
// project_documents and the old project_comments shape (target comments keep
// their rows) and drops owner_asks; Up again applies cleanly.
func TestMigration00100_DownUpIsClean(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "owner-asks-cycle.db"))
	require.NoError(t, err)
	defer d.Close()
	pid := newTestWorkbench(t, d)
	tid := insertWorkbenchTargetRow(t, d, pid, "board item")
	cid, err := d.AddWorkbenchComment(WorkbenchComment{WorkbenchID: pid, TargetID: nullID(tid), Author: "owner", Body: "why?"})
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO owner_asks (project_id, kind, title) VALUES (?, 'question', 'Which?')`, pid)
	require.NoError(t, err)

	// DownTo(99), not a bare Down: a later migration can move the tip past 00100.
	require.NoError(t, goose.DownTo(d.DB, "migrations", 99))
	cols := columnNames(t, d.DB, "project_comments")
	for _, c := range []string{"document_id", "anchor_quote", "anchor_prefix", "anchor_suffix", "anchor_heading"} {
		assert.True(t, cols[c], "project_comments.%s is back", c)
	}
	assert.True(t, columnNames(t, d.DB, "project_documents")["origin"], "project_documents is back with origin")
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name IN ('owner_asks', 'idx_owner_asks_project', 'idx_owner_asks_session')`).Scan(&n))
	assert.Zero(t, n, "owner_asks is dropped")
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM project_comments WHERE id = ?`, cid).Scan(&n))
	assert.Equal(t, 1, n, "a target comment survives the Down")
	_, err = d.Exec(`INSERT INTO project_documents (project_id, rel_path) VALUES (?, 'a.md')`, pid)
	require.NoError(t, err)

	require.NoError(t, goose.Up(d.DB, "migrations"))
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM project_comments WHERE id = ?`, cid).Scan(&n))
	assert.Equal(t, 1, n, "a target comment survives the re-Up")
	_, err = d.Exec(`INSERT INTO owner_asks (project_id, kind, title) VALUES (?, 'question', 'Again?')`, pid)
	assert.NoError(t, err)
}

// TestMigration00100_OwnerAskChecks: the shape CHECKs refuse what no writer
// may store.
func TestMigration00100_OwnerAskChecks(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	for name, q := range map[string]string{
		"a review needs doc_path":       `INSERT INTO owner_asks (project_id, kind, title) VALUES (?, 'review', 'Spec')`,
		"only a review has doc_path":    `INSERT INTO owner_asks (project_id, kind, title, doc_path) VALUES (?, 'check', 'Run', 'a.md')`,
		"answered needs an answer":      `INSERT INTO owner_asks (project_id, kind, title, status) VALUES (?, 'question', 'Q', 'answered')`,
		"delivered needs an answer":     `INSERT INTO owner_asks (project_id, kind, title, status) VALUES (?, 'question', 'Q', 'delivered')`,
		"an open ask carries no answer": `INSERT INTO owner_asks (project_id, kind, title, answer) VALUES (?, 'question', 'Q', '{}')`,
		"withdrawn_reason is an enum":   `INSERT INTO owner_asks (project_id, kind, title, status, withdrawn_reason) VALUES (?, 'question', 'Q', 'withdrawn', 'owner')`,
		"kind is an enum":               `INSERT INTO owner_asks (project_id, kind, title) VALUES (?, 'poll', 'Q')`,
		"status is an enum":             `INSERT INTO owner_asks (project_id, kind, title, status) VALUES (?, 'question', 'Q', 'closed')`,
		"a title is required":           `INSERT INTO owner_asks (project_id, kind, title) VALUES (?, 'question', '')`,
	} {
		_, err := d.Exec(q, pid)
		assert.Error(t, err, name)
	}
	_, err := d.Exec(`INSERT INTO owner_asks (project_id, kind, title, doc_path, status, answer)
		VALUES (?, 'review', 'Spec', 'docs/spec.md', 'answered', '{"verdict":"approved"}')`, pid)
	assert.NoError(t, err, "an answered review is well-formed")
}
