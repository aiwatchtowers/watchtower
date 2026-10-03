package db

import (
	"path/filepath"
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func seedMigrationChatProject(t *testing.T, d *DB) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO chat_projects (name, created_at, updated_at) VALUES ('p', 0, 0)`)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

// TestMigration00096_ChatProjectsPinConfluenceSpaces: the kind CHECK gains
// confluence_space (board #209) and still refuses an unknown kind; deleting
// the project still deletes its sources.
func TestMigration00096_ChatProjectsPinConfluenceSpaces(t *testing.T) {
	d := openTestDB(t)
	p := seedMigrationChatProject(t, d)

	_, err := d.Exec(`INSERT INTO chat_project_sources (project_id, kind, ref) VALUES (?, 'confluence_space', 'ENG')`, p)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO chat_project_sources (project_id, kind, ref) VALUES (?, 'link', 'https://example.com')`, p)
	assert.Error(t, err, "kind CHECK")
	sources, err := d.ChatProjectSources(p)
	require.NoError(t, err)
	assert.Equal(t, []ChatProjectSource{{Kind: "confluence_space", Ref: "ENG"}}, sources)

	_, err = d.Exec(`DELETE FROM chat_projects WHERE id = ?`, p)
	require.NoError(t, err)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_project_sources`).Scan(&n))
	assert.Zero(t, n, "deleting the project deletes its sources")
}

// TestMigration00096_DownDropsOnlyConfluencePins: the Down restores the old
// CHECK, keeping every other pin with its id.
func TestMigration00096_DownDropsOnlyConfluencePins(t *testing.T) {
	t.Parallel()
	d, err := Open(filepath.Join(t.TempDir(), "chat-sources-cycle.db"))
	require.NoError(t, err)
	defer d.Close()
	p := seedMigrationChatProject(t, d)
	_, err = d.Exec(`INSERT INTO chat_project_sources (id, project_id, kind, ref, label) VALUES
		(7, ?, 'jira_project', 'PAY', 'Payments'), (8, ?, 'confluence_space', 'ENG', '')`, p, p)
	require.NoError(t, err)

	// DownTo(95), not a bare Down: a later migration can move the tip past 00096.
	require.NoError(t, goose.DownTo(d.DB, "migrations", 95))
	var id int64
	var kind, label string
	require.NoError(t, d.QueryRow(`SELECT id, kind, label FROM chat_project_sources`).Scan(&id, &kind, &label))
	assert.Equal(t, []any{int64(7), "jira_project", "Payments"}, []any{id, kind, label})
	_, err = d.Exec(`INSERT INTO chat_project_sources (project_id, kind, ref) VALUES (?, 'confluence_space', 'ENG')`, p)
	assert.Error(t, err, "the old CHECK is back")

	require.NoError(t, goose.Up(d.DB, "migrations"))
	_, err = d.Exec(`INSERT INTO chat_project_sources (project_id, kind, ref) VALUES (?, 'confluence_space', 'ENG')`, p)
	assert.NoError(t, err, "re-Up accepts confluence_space again")
}
