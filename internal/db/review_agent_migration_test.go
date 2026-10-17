package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestMigration00127_ReviewAgentTables(t *testing.T) {
	d := openTestDB(t)
	pid, sid := seedReviewSession(t, d)
	rid, err := d.CreateReviewRound(ReviewRound{ProjectID: pid, SessionID: nullInt(sid), FolderRoot: "/r", BaseSHA: "b", TreeSHA: "t"})
	require.NoError(t, err)

	ins := func(q string, args ...any) error { _, err := d.Exec(q, args...); return err }
	require.NoError(t, ins(`INSERT INTO review_notes (project_id, session_id, tree_sha, kind, ord, text) VALUES (?, ?, 't', 'note', 0, 'n')`, pid, sid))
	require.NoError(t, ins(`INSERT INTO review_overviews (project_id, tree_sha, base_sha, intent_hash, json) VALUES (?, 't', 'b', 'h', '{}')`, pid))
	require.NoError(t, ins(`INSERT INTO review_reverts (round_id, hunk_id, path, header, patch) VALUES (?, 'h1', 'a.go', '@@', 'x')`, rid))
	require.NoError(t, ins(`INSERT INTO review_lessons (project_id, lens, text) VALUES (?, 'tests', 't')`, pid))

	assert.Error(t, ins(`INSERT INTO review_notes (project_id, tree_sha, kind, ord, text) VALUES (?, 't', 'x', 0, 'n')`, pid))
	assert.Error(t, ins(`INSERT INTO review_notes (project_id, tree_sha, kind, ord, text, core) VALUES (?, 't', 'note', 0, 'n', 2)`, pid))
	assert.Error(t, ins(`INSERT INTO review_lessons (project_id, lens, text, status) VALUES (?, 'l', 't', 'x')`, pid))
	assert.Error(t, ins(`INSERT INTO review_reverts (round_id, hunk_id, path, header, patch) VALUES (?, 'h1', 'a.go', '@@', 'x')`, rid))

	// Deleting the session keeps the note and nulls the link.
	require.NoError(t, ins(`DELETE FROM terminal_sessions WHERE id = ?`, sid))
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM review_notes WHERE session_id IS NULL`).Scan(&n))
	assert.Equal(t, 1, n)

	// Deleting the project removes everything.
	require.NoError(t, ins(`DELETE FROM projects WHERE id = ?`, pid))
	for _, tbl := range []string{"review_notes", "review_overviews", "review_reverts", "review_lessons"} {
		require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM `+tbl).Scan(&n))
		assert.Zero(t, n, tbl)
	}
}
