package cmd

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
	"watchtower/internal/workbenchcheck"
)

// archiveAge is a close old enough for the default 14-day archive.
const archiveAge = 20 * 24 * time.Hour

// PROJ-15 / PROJ-07: archiving hides a target from the board, never from
// the drift check — a done target on an unmerged branch is still reported by
// `workbench check` and in the brief once it is archived.
func TestProj15_DriftStillSeesArchivedUnmergedWork(t *testing.T) {
	database := writeActionsConfig(t)
	folder := driftRepo(t)
	pid, tid := driftWorkbench(t, database, folder, "open")
	require.NoError(t, database.SetWorkbenchArchiveDays(pid, 3))
	db.CloseTestWorkbenchTarget(t, database, tid, "done", 5*24*time.Hour)
	archived, err := database.IsWorkbenchTargetArchived(tid)
	require.NoError(t, err)
	require.True(t, archived, "precondition: the target is archived")

	stdout, _, err := runWorkbenchCheckCmd(t, strings.NewReader(""), "check", "--project", strconv.FormatInt(pid, 10), "--json", "--no-network")
	require.NoError(t, err)
	var rep workbenchcheck.Report
	require.NoError(t, json.Unmarshal([]byte(stdout), &rep), stdout)
	require.Len(t, rep.Findings, 1)
	assert.Equal(t, workbenchcheck.KindDoneUnmerged, rep.Findings[0].Kind)
	assert.Equal(t, int(tid), rep.Findings[0].TargetID)

	brief := loadWorkbenchBrief(pid, workbenchVocabulary)
	assert.Contains(t, brief, "Board drift")
	assert.Contains(t, brief, "#"+strconv.FormatInt(tid, 10)+` "Feature" [done]`)
	assert.Contains(t, brief, "0 done, 1 archived.")
}

func TestRenderProjectBrief_ArchivedLeaveTheCountsAndAreCounted(t *testing.T) {
	old := briefNode(3, "done", "old feature", briefNode(4, "done", "old task"))
	old.Archived, old.Children[0].Archived = true, true
	board := []db.BoardNode{briefNode(1, "in_progress", "active feature"), briefNode(2, "done", "recent feature"), old}
	comments := []db.WorkbenchComment{{ID: 9, TargetID: sql.NullInt64{Int64: 4, Valid: true}, Author: "owner", Body: "one more thing"}}

	out := renderWorkbenchBrief(board, briefWorkbench(), comments, workbenchcheck.Report{}, nil, nil, time.Now(), workbenchVocabulary)
	assert.Contains(t, out, "Targets: 1 in progress, 0 in review, 0 blocked, 0 todo, 1 done, 2 archived. New comments for you: 1.")
	assert.NotContains(t, out, "old feature")
	assert.Contains(t, out, "old task", "a comment on an archived target keeps its title")

	none := renderWorkbenchBrief(board[:2], briefWorkbench(), nil, workbenchcheck.Report{}, nil, nil, time.Now(), workbenchVocabulary)
	assert.Contains(t, none, "1 done. New comments", "no archived count without archived targets")
}

// archiveCmdBoard is a workbench with an open feature holding an archived
// task, and an archived feature.
func archiveCmdBoard(t *testing.T) (database *db.DB, pid, oldFeature int64) {
	t.Helper()
	database = writeActionsConfig(t)
	pid, err := database.CreateWorkbench("acme", t.TempDir())
	require.NoError(t, err)
	feature := db.SeedTestWorkbenchTarget(t, database, pid, sql.NullInt64{}, "Live feature")
	db.SeedTestWorkbenchTarget(t, database, pid, sql.NullInt64{Int64: feature, Valid: true}, "Open task")
	oldTask := db.SeedTestWorkbenchTarget(t, database, pid, sql.NullInt64{Int64: feature, Valid: true}, "Old task")
	oldFeature = db.SeedTestWorkbenchTarget(t, database, pid, sql.NullInt64{}, "Old feature")
	db.CloseTestWorkbenchTarget(t, database, oldTask, "done", archiveAge)
	db.CloseTestWorkbenchTarget(t, database, oldFeature, "dismissed", archiveAge)
	return database, pid, oldFeature
}

func TestWorkbenchBoardCmd_ArchivedOnlyWithTheFlag(t *testing.T) {
	_, pid, oldFeature := archiveCmdBoard(t)
	id := strconv.FormatInt(pid, 10)

	out, _, err := runWorkbench(t, "board", id)
	require.NoError(t, err)
	assert.Contains(t, out, "Live feature (+1 archived)")
	assert.Contains(t, out, "Open task")
	assert.NotContains(t, out, "Old task")
	assert.NotContains(t, out, "Old feature")

	out, _, err = runWorkbench(t, "board", id, "--archived")
	require.NoError(t, err)
	assert.Contains(t, out, "Old task (archived)")
	assert.Contains(t, out, fmt.Sprintf("#%d [dismissed", oldFeature))

	out, _, err = runWorkbench(t, "board", id, "--json")
	require.NoError(t, err)
	var board []boardNodeJSON
	require.NoError(t, json.Unmarshal([]byte(out), &board))
	require.Len(t, board, 1)
	assert.Equal(t, 1, board[0].ArchivedChildren)

	out, _, err = runWorkbench(t, "board", id, "--json", "--archived")
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal([]byte(out), &board))
	require.Len(t, board, 2)
	assert.True(t, board[1].Archived)
}

func TestWorkbenchShowCmd_PrintsTheArchiveSetting(t *testing.T) {
	database, pid, _ := archiveCmdBoard(t)
	id := strconv.FormatInt(pid, 10)

	out, _, err := runWorkbench(t, "show", id)
	require.NoError(t, err)
	assert.Contains(t, out, "Archive after: 14 days\n")
	out, _, err = runWorkbench(t, "show", id, "--json")
	require.NoError(t, err)
	var view workbenchViewJSON
	require.NoError(t, json.Unmarshal([]byte(out), &view))
	assert.Equal(t, 14, view.ArchiveAfterDays)
	assert.Equal(t, 1, view.Counts["dismissed"], "counts cover the whole board, archived targets included")

	require.NoError(t, database.SetWorkbenchArchiveDays(pid, 0))
	out, _, err = runWorkbench(t, "show", id)
	require.NoError(t, err)
	assert.Contains(t, out, "Archive after: never\n")
}

func TestArchiveAfterText(t *testing.T) {
	assert.Equal(t, "never", archiveAfterText(0))
	assert.Equal(t, "1 day", archiveAfterText(1))
	assert.Equal(t, "90 days", archiveAfterText(90))
}
