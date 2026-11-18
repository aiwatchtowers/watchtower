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
	_, err = d.Exec(`INSERT INTO review_reviewer_threads (project_id, workbench_folder_id, branch, conversation_id)
		VALUES (?, ?, ?, ?)`, projectID, homeFolderID(t, d, projectID), branch, id)
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

// One thread per (workbench, folder, branch); an empty branch is refused.
func TestReviewerThreads_KeyAndBranchCheck(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	home := homeFolderID(t, d, pid)
	conv := insertReviewerThread(t, d, pid, "feature/a")
	insert := `INSERT INTO review_reviewer_threads (project_id, workbench_folder_id, branch, conversation_id) VALUES (?, ?, ?, ?)`
	_, err := d.Exec(insert, pid, home, "feature/a", conv)
	require.ErrorContains(t, err, "UNIQUE", "a second thread for the same branch")
	_, err = d.Exec(insert, pid, home, "", conv)
	require.ErrorContains(t, err, "CHECK", "an empty branch")
	hub := addTestFolder(t, d, pid, "/tmp/code/hub", "hub", 1)
	_, err = d.Exec(insert, pid, hub, "feature/a", conv)
	require.NoError(t, err, "another folder's branch of the same name is its own thread")
}

// Spec 2026-11-18 §4 item 9 (#2003 Review Focus 1): two folders of one
// bench with the same branch name never share a reviewer thread or a PR
// state. A write for hub's main carries hub's folder id and leaves app's
// main alone; a read by (workbench, folder, branch|ref) returns that
// folder's own row.
func TestReviewerThreadsAndPRStatesKeyedPerFolder(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	app := homeFolderID(t, d, pid)
	hub := addTestFolder(t, d, pid, "/tmp/code/hub", "hub", 1)

	// Reviewer threads: the Desktop's insert, one per (workbench, folder, branch).
	appThread := insertReviewerThread(t, d, pid, "main")
	res, err := d.Exec(`INSERT INTO chat_conversations (title, context_type, context_id, created_at, updated_at)
		VALUES ('Reviewer', 'review_reviewer', 'main', 0, 0)`)
	require.NoError(t, err)
	hubThread, err := res.LastInsertId()
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO review_reviewer_threads (project_id, workbench_folder_id, branch, conversation_id)
		VALUES (?, ?, 'main', ?)`, pid, hub, hubThread)
	require.NoError(t, err, "hub's main is not app's main")
	threadOf := func(folder int64) int64 {
		var conv int64
		require.NoError(t, d.QueryRow(`SELECT conversation_id FROM review_reviewer_threads
			WHERE project_id = ? AND workbench_folder_id = ? AND branch = 'main'`, pid, folder).Scan(&conv))
		return conv
	}
	assert.Equal(t, appThread, threadOf(app))
	assert.Equal(t, hubThread, threadOf(hub))

	// PR states: hub's write never overwrites app's row of the same ref.
	require.NoError(t, d.UpsertPRState(PRState{WorkbenchID: pid, FolderID: app, Ref: "branch:main", State: "merged",
		Title: "app", CheckedAt: "2026-11-18T10:00:00Z"}))
	require.NoError(t, d.UpsertPRState(PRState{WorkbenchID: pid, FolderID: hub, Ref: "branch:main", State: "open",
		Title: "hub", CheckedAt: "2026-11-18T10:01:00Z"}))
	require.NoError(t, d.UpsertPRState(PRState{WorkbenchID: pid, FolderID: hub, Ref: "branch:main", State: "closed",
		Title: "hub again", CheckedAt: "2026-11-18T10:02:00Z"}))
	appStates, err := d.PRStates(pid, app)
	require.NoError(t, err)
	hubStates, err := d.PRStates(pid, hub)
	require.NoError(t, err)
	require.Len(t, appStates, 1)
	require.Len(t, hubStates, 1)
	assert.Equal(t, "merged", appStates["branch:main"].State, "app's main is untouched by hub's writes")
	assert.Equal(t, app, appStates["branch:main"].FolderID)
	assert.Equal(t, "closed", hubStates["branch:main"].State, "hub's own row took hub's last write")
	assert.Equal(t, hub, hubStates["branch:main"].FolderID)

	// Another bench's folder is never a key of this one's.
	other, err := d.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	err = d.UpsertPRState(PRState{WorkbenchID: other, FolderID: hub, Ref: "branch:main", State: "open"})
	require.ErrorIs(t, err, ErrNotInWorkbench)
}
