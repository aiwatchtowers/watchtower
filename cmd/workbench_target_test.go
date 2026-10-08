package cmd

import (
	"database/sql"
	"encoding/json"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// runTargetAdd runs `workbench target add args...` and resets the add
// command's flags, which runWorkbenchAs's reset does not reach (it is a
// grandchild of workbench).
func runTargetAdd(t *testing.T, args ...string) (stdout string, err error) {
	t.Helper()
	out, _, err := runWorkbenchAs(t, "workbench", append([]string{"target", "add"}, args...)...)
	resetSetFlags(workbenchTargetCmd.Commands()...)
	return out, err
}

func addedTargetID(t *testing.T, out string) int64 {
	t.Helper()
	var got struct {
		TargetID int64 `json:"target_id"`
	}
	require.NoError(t, json.Unmarshal([]byte(out), &got), out)
	require.Positive(t, got.TargetID, out)
	return got.TargetID
}

func workbenchTargetCount(t *testing.T, d *db.DB, pid int64) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM targets WHERE project_id = ?`, pid).Scan(&n))
	return n
}

func TestWorkbenchTargetAdd_RecordedAsTheOwnersWithTheBoardDefaults(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)

	out, err := runTargetAdd(t, "--workbench", strconv.FormatInt(pid, 10),
		"--title", "  Ship the phone board  ", "--intent", "why it matters", "--json")
	require.NoError(t, err)
	id := addedTargetID(t, out)

	tg, err := database.GetTargetByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, pid, tg.WorkbenchID.Int64)
	assert.Equal(t, "Ship the phone board", tg.Text)
	assert.Equal(t, "why it matters", tg.Intent)
	assert.Equal(t, "custom", tg.Level)
	assert.Equal(t, "project", tg.CustomLabel)
	assert.Equal(t, "chat", tg.SourceType)
	assert.Equal(t, "todo", tg.Status)
	assert.Equal(t, "medium", tg.Priority)
	assert.False(t, tg.ParentID.Valid)

	var actor string
	require.NoError(t, database.QueryRow(
		`SELECT actor FROM target_status_history WHERE target_id = ? AND from_status IS NULL`, id).Scan(&actor))
	assert.Equal(t, db.ActorOwner, actor, "the creation is the owner's (PROJ-06)")
}

func TestWorkbenchTargetAdd_RefusesAnEmptyOrTooLongTitle(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	wb := strconv.FormatInt(pid, 10)

	for name, title := range map[string]string{
		"empty":      "",
		"whitespace": "   \t ",
		"201 chars":  strings.Repeat("é", 201),
	} {
		_, err := runTargetAdd(t, "--workbench", wb, "--title", title, "--json")
		assert.Error(t, err, name)
	}
	assert.Equal(t, 0, workbenchTargetCount(t, database, pid), "no refused title wrote a row")

	out, err := runTargetAdd(t, "--workbench", wb, "--title", strings.Repeat("é", 200), "--json")
	require.NoError(t, err, "200 characters is the cap, not past it")
	addedTargetID(t, out)
}

func TestWorkbenchTargetAdd_RefusesAParentFromAnotherWorkbench(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	other, err := database.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	foreign := db.SeedTestWorkbenchTarget(t, database, other, sql.NullInt64{}, "foreign")

	_, err = runTargetAdd(t, "--workbench", strconv.FormatInt(pid, 10), "--title", "x",
		"--parent", strconv.FormatInt(foreign, 10), "--json")
	require.ErrorIs(t, err, db.ErrNotInWorkbench, "PROJ-09: a parent from another workbench")
	assert.Equal(t, 0, workbenchTargetCount(t, database, pid))
}

func TestWorkbenchTargetAdd_RefusesAnUnknownPriorityAndAMissingWorkbench(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)

	_, err = runTargetAdd(t, "--workbench", strconv.FormatInt(pid, 10), "--title", "x", "--priority", "urgent", "--json")
	require.Error(t, err)
	assert.Equal(t, 0, workbenchTargetCount(t, database, pid))

	_, err = runTargetAdd(t, "--workbench", strconv.FormatInt(pid+100, 10), "--title", "x", "--json")
	require.ErrorIs(t, err, db.ErrWorkbenchNotFound)
	_, err = runTargetAdd(t, "--title", "x", "--json")
	require.Error(t, err, "--workbench is required")
}

func TestWorkbenchTargetAdd_UnderAParentRecomputesItsProgress(t *testing.T) {
	database := writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	parent := db.SeedTestWorkbenchTarget(t, database, pid, sql.NullInt64{}, "feature")
	done := db.SeedTestWorkbenchTarget(t, database, pid, sql.NullInt64{Int64: parent, Valid: true}, "task 1")
	require.NoError(t, database.UpdateTargetStatus(int(done), "done"))
	before, err := database.GetTargetByID(int(parent))
	require.NoError(t, err)
	require.InDelta(t, 1.0, before.Progress, 1e-9)

	out, err := runTargetAdd(t, "--workbench", strconv.FormatInt(pid, 10), "--title", "task 2",
		"--parent", strconv.FormatInt(parent, 10), "--priority", "high", "--json")
	require.NoError(t, err)
	id := addedTargetID(t, out)

	child, err := database.GetTargetByID(int(id))
	require.NoError(t, err)
	assert.Equal(t, parent, child.ParentID.Int64)
	assert.Equal(t, "high", child.Priority)
	after, err := database.GetTargetByID(int(parent))
	require.NoError(t, err)
	assert.InDelta(t, 0.5, after.Progress, 1e-9, "one of two children done")
}
