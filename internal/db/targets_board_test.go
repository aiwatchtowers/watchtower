package db

import (
	"database/sql"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// A parent and its child always live on the same board: the personal board
// (project_id NULL) or one project's board. NULL vs N counts as different.
func TestTargetParent_MustShareTheChildsBoard(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	otherPID := newTestProject(t, d)
	projectParent := insertProjectTargetRow(t, d, pid, "project parent")
	personalParent, err := d.CreateTarget(makeTarget("personal parent", "todo", "medium"))
	require.NoError(t, err)

	withParent := func(text string, parent int64, project sql.NullInt64) Target {
		tg := makeTarget(text, "todo", "medium")
		tg.ParentID = nullID(parent)
		tg.ProjectID = project
		return tg
	}

	_, err = d.CreateTarget(withParent("personal child", projectParent, sql.NullInt64{}))
	assert.ErrorIs(t, err, ErrParentOtherBoard, "personal child under a project parent")
	_, err = d.CreateTarget(withParent("project child", personalParent, nullID(pid)))
	assert.ErrorIs(t, err, ErrParentOtherBoard, "project child under a personal parent")
	_, err = d.CreateTarget(withParent("wrong project", projectParent, nullID(otherPID)))
	assert.ErrorIs(t, err, ErrParentOtherBoard, "child of another project")

	sameProject, err := d.CreateTarget(withParent("same project", projectParent, nullID(pid)))
	require.NoError(t, err)
	_, err = d.CreateTarget(withParent("same personal", personalParent, sql.NullInt64{}))
	require.NoError(t, err)

	// Re-parenting through UpdateTarget obeys the same rule.
	child, err := d.GetTargetByID(int(sameProject))
	require.NoError(t, err)
	child.ParentID = nullID(personalParent)
	assert.ErrorIs(t, d.UpdateTarget(*child), ErrParentOtherBoard)

	// So does moving a parent off its children's board.
	parent, err := d.GetTargetByID(int(projectParent))
	require.NoError(t, err)
	parent.ProjectID = sql.NullInt64{}
	assert.ErrorIs(t, d.UpdateTarget(*parent), ErrParentOtherBoard, "a parent cannot leave its children's board")

	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM targets WHERE parent_id = ? AND project_id = ?`, projectParent, pid).Scan(&n))
	assert.Equal(t, 1, n, "a refused update leaves the tree unchanged")
}
