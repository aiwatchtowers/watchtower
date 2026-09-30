package db

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Edge cases of migration 00085's rollup (PROJ-05): moves, project changes,
// multi-row statements, deletes, cycles and the Swift test-schema copy.

func TestProj05_MoveOutOfAParentWithRemainingChildrenReRollsIt(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	root := insertProjectTargetRow(t, d, pid, "plan")
	mid := insertBoardChild(t, d, pid, root, "todo")
	a := insertBoardChild(t, d, pid, mid, "in_progress")
	insertBoardChild(t, d, pid, mid, "blocked")
	require.Equal(t, "in_progress", targetStatus(t, d, mid))

	_, err := d.Exec(`UPDATE targets SET parent_id = ? WHERE id = ?`, root, a)
	require.NoError(t, err)
	assert.Equal(t, "blocked", targetStatus(t, d, mid), "the old parent keeps only a blocked child")
	// root: {mid blocked, a in_progress} -> in_progress.
	assert.Equal(t, "in_progress", targetStatus(t, d, root))
}

func TestProj05_OldAndNewParentShareAnAncestor(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	root := insertProjectTargetRow(t, d, pid, "plan")
	m1 := insertBoardChild(t, d, pid, root, "todo")
	m2 := insertBoardChild(t, d, pid, root, "todo")
	x := insertBoardChild(t, d, pid, m1, "todo")
	insertBoardChild(t, d, pid, m1, "done")
	insertBoardChild(t, d, pid, m2, "done")
	require.Equal(t, "in_progress", targetStatus(t, d, m1))
	require.Equal(t, "done", targetStatus(t, d, m2))
	require.Equal(t, "in_progress", targetStatus(t, d, root))

	// One statement moves x to m2 and closes it: m2 = {done, done} -> done,
	// m1 = {done} -> done, and the root sees both changes.
	_, err := d.Exec(`UPDATE targets SET parent_id = ?, status = 'done' WHERE id = ?`, m2, x)
	require.NoError(t, err)
	assert.Equal(t, "done", targetStatus(t, d, m1))
	assert.Equal(t, "done", targetStatus(t, d, m2))
	assert.Equal(t, "done", targetStatus(t, d, root))
}

func TestProj05_ChildLeavingOrJoiningTheProjectReRollsTheParent(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	parent := insertProjectTargetRow(t, d, pid, "feature")
	insertBoardChild(t, d, pid, parent, "done")
	open := insertBoardChild(t, d, pid, parent, "in_progress")
	require.Equal(t, "in_progress", targetStatus(t, d, parent))

	_, err := d.Exec(`UPDATE targets SET project_id = NULL WHERE id = ?`, open)
	require.NoError(t, err)
	assert.Equal(t, "done", targetStatus(t, d, parent), "a child that left the project no longer counts")

	_, err = d.Exec(`UPDATE targets SET project_id = ? WHERE id = ?`, pid, open)
	require.NoError(t, err)
	assert.Equal(t, "in_progress", targetStatus(t, d, parent), "a child that joined the project counts")
}

func TestProj05_OneStatementClosingSeveralChildren(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	root := insertProjectTargetRow(t, d, pid, "plan")
	mid := insertBoardChild(t, d, pid, root, "todo")
	l1 := insertBoardChild(t, d, pid, mid, "todo")
	l2 := insertBoardChild(t, d, pid, mid, "todo")

	_, err := d.Exec(`UPDATE targets SET status = 'done' WHERE id IN (?, ?)`, l1, l2)
	require.NoError(t, err)
	assert.Equal(t, "done", targetStatus(t, d, mid))
	assert.Equal(t, "done", targetStatus(t, d, root))
}

func TestProj05_ParentOwnChangeStillRollsIntoItsParent(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	root := insertProjectTargetRow(t, d, pid, "plan")
	parent := insertBoardChild(t, d, pid, root, "todo")
	insertBoardChild(t, d, pid, parent, "todo")

	require.NoError(t, d.UpdateTargetStatus(int(parent), "blocked"))
	assert.Equal(t, "blocked", targetStatus(t, d, parent))
	assert.Equal(t, "blocked", targetStatus(t, d, root), "the parent is itself a child of the root")
}

func TestProj05_DeletingTheLastChildLeavesTheParentUntouched(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	parent := insertProjectTargetRow(t, d, pid, "feature")
	only := insertBoardChild(t, d, pid, parent, "in_progress")
	require.Equal(t, "in_progress", targetStatus(t, d, parent))

	require.NoError(t, d.DeleteTarget(int(only)))
	assert.Equal(t, "in_progress", targetStatus(t, d, parent), "no children -> untouched")
}

func TestProj05_DeletingAMiddleParentReRollsTheGrandparent(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	root := insertProjectTargetRow(t, d, pid, "plan")
	mid := insertBoardChild(t, d, pid, root, "todo")
	insertBoardChild(t, d, pid, mid, "in_progress")
	insertBoardChild(t, d, pid, root, "done")
	require.Equal(t, "in_progress", targetStatus(t, d, root))

	// The mid's children are orphaned (ON DELETE SET NULL); the root is left
	// with its done child.
	require.NoError(t, d.DeleteTarget(int(mid)))
	assert.Equal(t, "done", targetStatus(t, d, root))
}

func TestProj05_HundredLevelChainRollsUpToTheRoot(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	root := insertProjectTargetRow(t, d, pid, "root")
	parent := root
	for i := 0; i < 100; i++ {
		parent = insertBoardChild(t, d, pid, parent, "todo")
	}
	setStatusRaw(t, d, parent, "done")
	assert.Equal(t, "done", targetStatus(t, d, root))
}

func TestProj05_ParentIDCycleTerminates(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	a := insertProjectTargetRow(t, d, pid, "a")
	b := insertBoardChild(t, d, pid, a, "todo")
	_, err := d.Exec(`UPDATE targets SET parent_id = ? WHERE id = ?`, b, a)
	require.NoError(t, err)
	setStatusRaw(t, d, b, "done")
	setStatusRaw(t, d, b, "in_progress")
	assert.Contains(t, []string{"todo", "in_progress", "done"}, targetStatus(t, d, a))
}

func TestProj05_PersonalParentOfAProjectChildIsNeverWritten(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	res, err := d.Exec(`INSERT INTO targets (text, period_start, period_end, status)
		VALUES ('personal', '2026-09-29', '2026-09-29', 'todo')`)
	require.NoError(t, err)
	personal, err := res.LastInsertId()
	require.NoError(t, err)
	insertBoardChild(t, d, pid, personal, "done")
	assert.Equal(t, "todo", targetStatus(t, d, personal))
}

// The Swift test schema carries a copy of the three triggers so Desktop
// tests exercise the shipped rule; this keeps the copy from drifting.
func TestProj05_SwiftTestSchemaMirrorsTheTriggers(t *testing.T) {
	mig, err := os.ReadFile(filepath.Join("migrations", "00085_project_status_rollup.sql"))
	require.NoError(t, err)
	swift, err := os.ReadFile(filepath.Join("..", "..", "WatchtowerDesktop", "Tests", "Support", "TestDatabase+Schema.swift"))
	require.NoError(t, err)
	re := regexp.MustCompile(`(?s)CREATE TRIGGER (targets_project_status_rollup_\w+).*?\n\s*END;`)
	norm := func(s string) string { return strings.Join(strings.Fields(s), " ") }
	want := re.FindAllStringSubmatch(string(mig), -1)
	require.Len(t, want, 3)
	got := map[string]string{}
	for _, m := range re.FindAllStringSubmatch(strings.ReplaceAll(string(swift), "CREATE TRIGGER IF NOT EXISTS ", "CREATE TRIGGER "), -1) {
		got[m[1]] = norm(m[0])
	}
	for _, m := range want {
		assert.Equal(t, norm(m[0]), got[m[1]], "Swift mirror of %s drifted from migration 00085", m[1])
	}
}
