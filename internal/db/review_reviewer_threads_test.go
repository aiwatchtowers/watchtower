package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// insertReviewerThread plants a reviewer thread of branch with one owner
// message, as the Desktop writes it (migration 00180).
func insertReviewerThread(t *testing.T, d *DB, projectID int64, branch string) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
		VALUES ('Reviewer', 'review_reviewer', ?, 0, 0)`, branch)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at) VALUES (?, 'user', 'what breaks?', 0)`, id)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO review_reviewer_threads (project_id, branch, conversation_id) VALUES (?, ?, ?)`,
		projectID, branch, id)
	require.NoError(t, err)
	return id
}

// The reviewer quotes the folder's code: a deleted workbench takes its
// threads and their conversations along; another workbench's stay.
func TestReviewerThreads_DeletedWithTheirWorkbench(t *testing.T) {
	d := openTestDB(t)
	mine := newTestWorkbench(t, d)
	other, err := d.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	gone := insertReviewerThread(t, d, mine, "feature/a")
	kept := insertReviewerThread(t, d, other, "feature/a")

	require.NoError(t, d.DeleteWorkbench(mine))

	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_conversations WHERE id = ?`, gone).Scan(&n))
	assert.Equal(t, 0, n, "the deleted workbench's reviewer conversation is gone")
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_messages WHERE conversation_id = ?`, gone).Scan(&n))
	assert.Equal(t, 0, n)
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_conversations WHERE id = ?`, kept).Scan(&n))
	assert.Equal(t, 1, n, "another workbench's thread stays")
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM review_reviewer_threads`).Scan(&n))
	assert.Equal(t, 1, n)
}

// One thread per (workbench, branch); an empty branch is refused.
func TestReviewerThreads_KeyAndBranchCheck(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	conv := insertReviewerThread(t, d, pid, "feature/a")
	_, err := d.Exec(`INSERT INTO review_reviewer_threads (project_id, branch, conversation_id) VALUES (?, 'feature/a', ?)`, pid, conv)
	require.Error(t, err, "a second thread for the same branch")
	_, err = d.Exec(`INSERT INTO review_reviewer_threads (project_id, branch, conversation_id) VALUES (?, '', ?)`, pid, conv)
	require.Error(t, err, "an empty branch")
}
