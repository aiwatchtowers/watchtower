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

// Owner decision 2026-09-30: a dismissed parent is terminal for the rollup —
// neither it nor anything above it moves because of a change below it.
func TestProj05_DismissedAncestorIsNeverReDerived(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	root := insertProjectTargetRow(t, d, pid, "plan")
	mid := insertBoardChild(t, d, pid, root, "todo")
	leaf := insertBoardChild(t, d, pid, mid, "todo")
	insertBoardChild(t, d, pid, root, "todo")
	setStatusRaw(t, d, mid, "dismissed")
	require.Equal(t, "todo", targetStatus(t, d, root), "{dismissed, todo} -> todo")
	_, err := d.Exec(`UPDATE targets SET updated_at = '2000-01-01T00:00:00Z' WHERE id IN (?, ?)`, root, mid)
	require.NoError(t, err)

	setStatusRaw(t, d, leaf, "in_progress")
	assert.Equal(t, "dismissed", targetStatus(t, d, mid), "a dismissed parent is not re-derived")
	assert.Equal(t, "todo", targetStatus(t, d, root), "nothing above a dismissed parent moves")
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM targets
		WHERE id IN (?, ?) AND updated_at = '2000-01-01T00:00:00Z'`, root, mid).Scan(&n))
	assert.Equal(t, 2, n, "neither row is written")

	// Inserting another child under it: still untouched.
	insertBoardChild(t, d, pid, mid, "done")
	assert.Equal(t, "dismissed", targetStatus(t, d, mid))
}

func TestProj05_AllChildrenDismissedDismissesTheParentAndItRollsOn(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	root := insertProjectTargetRow(t, d, pid, "plan")
	parent := insertBoardChild(t, d, pid, root, "todo")
	a := insertBoardChild(t, d, pid, parent, "todo")
	insertBoardChild(t, d, pid, root, "done")
	require.Equal(t, "in_progress", targetStatus(t, d, root))

	setStatusRaw(t, d, a, "dismissed")
	assert.Equal(t, "dismissed", targetStatus(t, d, parent), "abandoned work is dismissed, not done")
	assert.Equal(t, "done", targetStatus(t, d, root), "{dismissed, done} -> done")

	setStatusRaw(t, d, a, "todo")
	assert.Equal(t, "dismissed", targetStatus(t, d, parent),
		"once dismissed, the parent is terminal for the rollup (set it back by hand)")
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

// The Swift test schema carries a copy of the targets triggers so Desktop
// tests exercise the shipped rule; this keeps the copy from drifting. The
// shipped bodies are those of migration 00086, which recreated 00085's
// rollup triggers (in_review, status_actor) and added the PROJ-06 history
// triggers.
func TestProj05_SwiftTestSchemaMirrorsTheTriggers(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("migrations", "00086_target_in_review_status.sql"))
	require.NoError(t, err)
	mig := []byte(strings.SplitN(string(raw), "-- +goose Down", 2)[0])
	swift, err := os.ReadFile(filepath.Join("..", "..", "WatchtowerDesktop", "Tests", "Support", "TestDatabase+Schema.swift"))
	require.NoError(t, err)
	re := regexp.MustCompile(`(?s)CREATE TRIGGER (targets_(?:project_status_rollup|status_history|status_actor_reset)_\w+).*?\n\s*END;`)
	norm := func(s string) string { return strings.Join(strings.Fields(s), " ") }
	want := re.FindAllStringSubmatch(string(mig), -1)
	require.Len(t, want, 6)
	got := map[string]string{}
	for _, m := range re.FindAllStringSubmatch(strings.ReplaceAll(string(swift), "CREATE TRIGGER IF NOT EXISTS ", "CREATE TRIGGER "), -1) {
		got[m[1]] = norm(m[0])
	}
	for _, m := range want {
		assert.Equal(t, norm(m[0]), got[m[1]], "Swift mirror of %s drifted from migration 00086", m[1])
	}
}
