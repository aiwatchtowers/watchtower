package db

import (
	"database/sql"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestGetProjectBoard_TreeOrderCountsAndDocuments(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	var ids []int64
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		var err error
		ids, err = d.CreateProjectTargetsTx(tx, pid, []ProjectTargetInput{
			{Title: "todo root"},
			{Title: "done root"},
			{Title: "active root"},
			{Title: "child of active", BatchParent: 3},
		})
		return err
	}))
	require.NoError(t, d.UpdateTargetStatus(int(ids[1]), "done"))
	require.NoError(t, d.UpdateTargetStatus(int(ids[2]), "in_progress"))

	SeedTestProjectTarget(t, d, newTestProject(t, d), sql.NullInt64{}, "another board")
	_, err := d.CreateTarget(Target{Text: "personal", Status: "todo", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)

	active := nullID(ids[2])
	_, err = d.AddProjectComment(ProjectComment{ProjectID: pid, TargetID: active, Author: "owner", Body: "please split"})
	require.NoError(t, err)
	_, err = d.AddProjectComment(ProjectComment{ProjectID: pid, TargetID: active, Author: "agent", Body: "which part?"})
	require.NoError(t, err)
	docID, _, err := d.UpsertProjectDocument(ProjectDocument{ProjectID: pid, TargetID: active, RelPath: "docs/plan.md", Kind: "plan"})
	require.NoError(t, err)

	board, err := d.GetProjectBoard(pid)
	require.NoError(t, err)
	require.Len(t, board, 3, "only this project's roots")
	assert.Equal(t, "active root", board[0].Target.Text, "in_progress first")
	assert.Equal(t, "todo root", board[1].Target.Text)
	assert.Equal(t, "done root", board[2].Target.Text, "done after todo")

	require.Len(t, board[0].Children, 1)
	assert.Equal(t, "child of active", board[0].Children[0].Target.Text)
	assert.Equal(t, 1, board[0].NewForAgent, "the open owner root")
	assert.Equal(t, 1, board[0].UnreadForOwner, "the unread agent comment")
	require.Len(t, board[0].Documents, 1)
	assert.Equal(t, docID, board[0].Documents[0].ID)
	assert.Zero(t, board[1].NewForAgent)

	empty, err := d.GetProjectBoard(pid + 100)
	require.NoError(t, err)
	assert.Empty(t, empty)
}

// #104: siblings sort by priority first (high, medium, low), then by the
// status order, then id; an item without a priority defaults to medium.
func TestGetProjectBoard_SiblingsSortByPriorityThenStatus(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	var ids []int64
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		var err error
		ids, err = d.CreateProjectTargetsTx(tx, pid, []ProjectTargetInput{
			{Title: "low todo", Priority: "low"},
			{Title: "medium todo"},
			{Title: "high todo", Priority: "high"},
			{Title: "medium active", Priority: "medium"},
			{Title: "low child", Priority: "low", BatchParent: 3},
			{Title: "high child", Priority: "high", BatchParent: 3},
		})
		return err
	}))
	require.NoError(t, d.UpdateTargetStatus(int(ids[3]), "in_progress"))

	board, err := d.GetProjectBoard(pid)
	require.NoError(t, err)
	var titles []string
	for _, n := range board {
		titles = append(titles, n.Target.Text)
	}
	assert.Equal(t, []string{"high todo", "medium active", "medium todo", "low todo"}, titles)
	assert.Equal(t, "medium", board[2].Target.Priority, "an item without a priority is medium")
	require.Len(t, board[0].Children, 2)
	assert.Equal(t, "high child", board[0].Children[0].Target.Text)
}

func TestCreateProjectTargets_InvalidPriorityFailsTheBatch(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	err := d.WithTx(func(tx *sql.Tx) error {
		_, err := d.CreateProjectTargetsTx(tx, pid, []ProjectTargetInput{{Title: "x", Priority: "urgent"}})
		return err
	})
	require.ErrorContains(t, err, "invalid priority")
}

func TestUpdateTargetPriorityTx_SetsOnlyPriority(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	id := SeedTestProjectTarget(t, d, pid, sql.NullInt64{}, "feature")
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error { return d.UpdateTargetPriorityTx(tx, int(id), "high") }))
	got, err := d.GetTargetByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, "high", got.Priority)
	assert.Equal(t, "feature", got.Text)
	require.Error(t, d.WithTx(func(tx *sql.Tx) error { return d.UpdateTargetPriorityTx(tx, int(id), "urgent") }))
}
