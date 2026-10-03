package db

import (
	"path/filepath"
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestMigration00081_CreatesProjectTablesAndTargetsColumn pins the spec §3
// shape: four project tables with their columns, and targets.project_id with
// its index. Read at 00081: 00100 drops project_documents and the anchors.
func TestMigration00081_CreatesProjectTablesAndTargetsColumn(t *testing.T) {
	t.Parallel()
	raw := rawDBAt(t, 81)

	want := map[string][]string{
		"projects":          {"id", "name", "folder_path", "description", "created_at", "updated_at"},
		"project_sources":   {"id", "project_id", "kind", "ref", "label"},
		"project_documents": {"id", "project_id", "target_id", "rel_path", "kind", "title", "created_at", "updated_at"},
		"project_comments": {"id", "project_id", "target_id", "document_id", "parent_id", "author", "agent_label",
			"body", "anchor_quote", "anchor_prefix", "anchor_suffix", "anchor_heading", "status", "created_at", "read_at"},
	}
	for table, cols := range want {
		got := columnNames(t, raw, table)
		for _, c := range cols {
			assert.True(t, got[c], "%s.%s missing", table, c)
		}
	}
	assert.True(t, columnNames(t, raw, "targets")["project_id"], "targets.project_id missing")

	for _, idx := range []string{"idx_targets_project", "idx_project_documents_target", "idx_project_comments_project",
		"idx_project_comments_target", "idx_project_comments_document", "idx_project_comments_parent"} {
		var name string
		require.NoError(t, raw.QueryRow(`SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?`, idx).Scan(&name),
			"index %s missing", idx)
	}
}

// TestMigration00081_ConstraintsHold: the UNIQUE folder, the kind/author/
// status CHECKs, the "a comment hangs off something" CHECK, and the cascade
// from a project to its targets and their comments. Run at 00081: 00100 drops
// project_documents.
func TestMigration00081_ConstraintsHold(t *testing.T) {
	t.Parallel()
	d := rawDBAt(t, 81)
	res, err := d.Exec(`INSERT INTO projects (name, folder_path) VALUES ('acme', '/tmp/acme')`)
	require.NoError(t, err)
	pid, err := res.LastInsertId()
	require.NoError(t, err)

	_, err = d.Exec(`INSERT INTO projects (name, folder_path) VALUES ('again', '/tmp/acme')`)
	assert.Error(t, err, "folder_path is UNIQUE")
	_, err = d.Exec(`INSERT INTO project_sources (project_id, kind, ref) VALUES (?, 'wiki', 'x')`, pid)
	assert.Error(t, err, "project_sources.kind CHECK")
	_, err = d.Exec(`INSERT INTO project_documents (project_id, rel_path, kind) VALUES (?, 'a.md', 'memo')`, pid)
	assert.Error(t, err, "project_documents.kind CHECK")
	_, err = d.Exec(`INSERT INTO project_comments (project_id, author, body) VALUES (?, 'owner', 'orphan')`, pid)
	assert.Error(t, err, "a comment needs a target, a document or a parent")

	res, err = d.Exec(`INSERT INTO targets (text, period_start, period_end, project_id)
		VALUES ('board item', '2026-09-29', '2026-09-29', ?)`, pid)
	require.NoError(t, err)
	tid, err := res.LastInsertId()
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO project_comments (project_id, target_id, author, body) VALUES (?, ?, 'bot', 'x')`, pid, tid)
	assert.Error(t, err, "project_comments.author CHECK")
	_, err = d.Exec(`INSERT INTO project_comments (project_id, target_id, author, body, status)
		VALUES (?, ?, 'agent', 'x', 'closed')`, pid, tid)
	assert.Error(t, err, "project_comments.status CHECK")
	_, err = d.Exec(`INSERT INTO project_comments (project_id, target_id, author, body) VALUES (?, ?, 'agent', 'blocked?')`, pid, tid)
	require.NoError(t, err)

	_, err = d.Exec(`DELETE FROM projects WHERE id = ?`, pid)
	require.NoError(t, err)
	var n int
	require.NoError(t, d.QueryRow(`SELECT (SELECT COUNT(*) FROM targets) + (SELECT COUNT(*) FROM project_comments)`).Scan(&n))
	assert.Zero(t, n, "deleting a project cascades to its targets and their comments")
}

// TestMigration00081_DownDropsProjectsAndTheirTargets: other tests roll back
// through 00081 (goose.DownTo to older versions), so its Down must be real —
// and it must take the project targets with it, or a rollback would turn every
// board item into a personal target.
func TestMigration00081_DownDropsProjectsAndTheirTargets(t *testing.T) {
	t.Parallel()
	d, err := Open(filepath.Join(t.TempDir(), "projects-cycle.db"))
	require.NoError(t, err)
	defer d.Close()

	_, err = d.Exec(`INSERT INTO targets (text, period_start, period_end) VALUES ('personal', '2026-09-29', '2026-09-29')`)
	require.NoError(t, err)
	res, err := d.Exec(`INSERT INTO projects (name, folder_path) VALUES ('acme', '/tmp/acme')`)
	require.NoError(t, err)
	pid, err := res.LastInsertId()
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO targets (text, period_start, period_end, project_id)
		VALUES ('board item', '2026-09-29', '2026-09-29', ?)`, pid)
	require.NoError(t, err)

	// DownTo(80), not a bare Down: a later migration can move the tip past 00081.
	require.NoError(t, goose.DownTo(d.DB, "migrations", 80))
	assert.False(t, columnNames(t, d.DB, "targets")["project_id"], "Down removes targets.project_id")
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM targets`).Scan(&n))
	assert.Equal(t, 1, n, "Down keeps personal targets and drops project targets")
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name LIKE 'project%'`).Scan(&n))
	assert.Zero(t, n, "Down drops every project table")

	require.NoError(t, goose.Up(d.DB, "migrations"))
	assert.True(t, columnNames(t, d.DB, "targets")["project_id"], "re-Up restores the column")
}
