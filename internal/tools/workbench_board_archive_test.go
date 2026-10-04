package tools

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// archiveAge is a close old enough for the default 14-day archive.
const archiveAge = 20 * 24 * time.Hour

func boardNode(id int, status string, children ...db.BoardNode) db.BoardNode {
	return db.BoardNode{Target: db.Target{ID: id, Text: fmt.Sprintf("T%d", id), Intent: "why", Status: status,
		Priority: "medium", Progress: 0.5}, Children: children}
}

func archivedNode(id int, status string, children ...db.BoardNode) db.BoardNode {
	n := boardNode(id, status, children...)
	n.Archived = true
	return n
}

// mixedBoard: an open feature with a closed, an archived and an open task;
// a hand-closed group over open work; a closed group with nothing open.
func mixedBoard() []db.BoardNode {
	return []db.BoardNode{
		boardNode(1, "in_progress", boardNode(2, "done"), archivedNode(3, "done"), boardNode(4, "todo")),
		boardNode(5, "done", boardNode(6, "todo")),
		boardNode(7, "dismissed", boardNode(8, "done")),
	}
}

func viewIDs(views []boardNodeView) []int {
	ids := []int{}
	for _, v := range views {
		ids = append(ids, v.ID)
	}
	return ids
}

// Owner decision A: open work and the closed targets above it are listed in
// full; every other closed target is counted, archived ones apart.
func TestBuildBoardView_DefaultListsOpenWorkAndCountsTheRest(t *testing.T) {
	v := buildBoardView(9, mixedBoard(), workbenchBoardArgs{})

	assert.Equal(t, []int{1, 5}, viewIDs(v.Targets))
	assert.Equal(t, 3, v.Closed, "#2 and the whole #7 group")
	assert.Equal(t, 1, v.Archived)
	feature := v.Targets[0]
	assert.Equal(t, []int{4}, viewIDs(feature.Children))
	assert.Equal(t, 1, feature.ClosedChildren)
	assert.Equal(t, 1, feature.ArchivedChildren)
	group := v.Targets[1]
	assert.Equal(t, "why", group.Intent, "a closed target above open work keeps its full form")
	require.NotNil(t, group.Progress)
	assert.Equal(t, []int{6}, viewIDs(group.Children))
}

func TestBuildBoardView_IncludeClosedListsThemBriefly(t *testing.T) {
	v := buildBoardView(9, mixedBoard(), workbenchBoardArgs{IncludeClosed: true})

	assert.Equal(t, []int{1, 5, 7}, viewIDs(v.Targets))
	assert.Zero(t, v.Closed)
	assert.Equal(t, 1, v.Archived)
	assert.Equal(t, []int{2, 4}, viewIDs(v.Targets[0].Children), "archived #3 stays out")
	assert.Equal(t, 1, v.Targets[0].ArchivedChildren)
	assert.Zero(t, v.Targets[0].ClosedChildren)

	raw, err := json.Marshal(v.Targets[2])
	require.NoError(t, err)
	assert.JSONEq(t, `{"id":7,"text":"T7","status":"dismissed","children":[{"id":8,"text":"T8","status":"done"}]}`, string(raw),
		"a closed target with nothing open: title, status and since only")
}

func TestBuildBoardView_IncludeArchivedListsEverything(t *testing.T) {
	v := buildBoardView(9, mixedBoard(), workbenchBoardArgs{IncludeArchived: true})

	assert.Equal(t, []int{1, 5, 7}, viewIDs(v.Targets))
	assert.Equal(t, []int{2, 3, 4}, viewIDs(v.Targets[0].Children))
	assert.True(t, v.Targets[0].Children[1].Archived)
	assert.Zero(t, v.Targets[0].ArchivedChildren)
	assert.Zero(t, v.Closed)
	assert.Equal(t, 1, v.Archived)
}

func TestBuildBoardView_EmptyBoard(t *testing.T) {
	raw, err := json.Marshal(buildBoardView(9, nil, workbenchBoardArgs{}))
	require.NoError(t, err)
	assert.JSONEq(t, `{"workbench_id":9,"targets":[],"archived":0}`, string(raw))
}

// archiveFixture is workbench a of the fixture plus an archived feature with
// an archived task, and an archived task under the open "Alpha feature".
type archiveFixture struct {
	workbenchFixture
	reg                         *Registry
	oldFeature, oldTask, aChild int64
}

func newArchiveFixture(t *testing.T) archiveFixture {
	t.Helper()
	fx := archiveFixture{workbenchFixture: newWorkbenchFixture(t)}
	fx.reg = workbenchRegistry(t, fx.d)
	fx.oldFeature = db.SeedTestWorkbenchTarget(t, fx.d, fx.a, sql.NullInt64{}, "Old feature")
	fx.oldTask = db.SeedTestWorkbenchTarget(t, fx.d, fx.a, sql.NullInt64{Int64: fx.oldFeature, Valid: true}, "Old task")
	fx.aChild = db.SeedTestWorkbenchTarget(t, fx.d, fx.a, sql.NullInt64{Int64: fx.aTarget, Valid: true}, "Old alpha task")
	db.SeedTestWorkbenchTarget(t, fx.d, fx.a, sql.NullInt64{Int64: fx.aTarget, Valid: true}, "Open alpha task")
	for _, id := range []int64{fx.oldTask, fx.oldFeature, fx.aChild} {
		db.CloseTestWorkbenchTarget(t, fx.d, id, "done", archiveAge)
	}
	return fx
}

func TestWorkbenchBoard_ArchivedSubtreesOnlyOnRequest(t *testing.T) {
	fx := newArchiveFixture(t)

	got := callReadIn(t, fx.reg, fx.a, "workbench_board", `{}`)
	assert.NotContains(t, got, "Old feature")
	assert.NotContains(t, got, "Old task")
	assert.NotContains(t, got, "Old alpha task")
	assert.Contains(t, got, "Open alpha task")
	assert.Contains(t, got, `"archived_children":1`)
	assert.Contains(t, got, `"archived":3`)

	all := callReadIn(t, fx.reg, fx.a, "workbench_board", `{"include_archived":true}`)
	for _, title := range []string{"Old feature", "Old task", "Old alpha task"} {
		assert.Contains(t, all, title)
	}
	assert.Contains(t, all, `"archived":true`)

	_, err := fx.reg.CallRead(t.Context(), "workbench_board", json.RawMessage(`{"include_everything":true}`), directBinding(fx.a))
	var ve *ValidationError
	assert.ErrorAs(t, err, &ve, "an unknown argument is refused")
}

func TestWorkbenchInfo_CountsTheWholeBoardAndTheArchived(t *testing.T) {
	fx := newArchiveFixture(t)

	got := callReadIn(t, fx.reg, fx.a, "workbench_info", `{}`)
	assert.Contains(t, got, `"targets_by_status":{"done":3,"in_progress":1,"todo":1}`)
	assert.Contains(t, got, `"archived":3`)
}

func TestListTargets_ArchivedOnlyWithIncludeArchived(t *testing.T) {
	fx := newArchiveFixture(t)

	done := callReadIn(t, fx.reg, fx.a, "list_targets", `{"status":"done"}`)
	assert.NotContains(t, done, "Old feature", "an explicit status still leaves archived targets out")
	withArchived := callReadIn(t, fx.reg, fx.a, "list_targets", `{"status":"done","include_archived":true}`)
	for _, title := range []string{"Old feature", "Old task", "Old alpha task"} {
		assert.Contains(t, withArchived, title)
	}

	plain := callReadString(t, fx.reg, "list_targets", `{"status":"done","include_archived":true}`)
	assert.NotContains(t, plain, "Old feature", "outside a workbench session nothing changes (PROJ-01)")
}

func TestListTargets_IncludeArchivedWithoutStatusListsArchivedTargets(t *testing.T) {
	fx := newArchiveFixture(t)

	def := callReadIn(t, fx.reg, fx.a, "list_targets", `{}`)
	assert.Contains(t, def, "Open alpha task")
	for _, title := range []string{"Old feature", "Old task", "Old alpha task"} {
		assert.NotContains(t, def, title, "the default still hides archived targets")
	}
	all := callReadIn(t, fx.reg, fx.a, "list_targets", `{"include_archived":true}`)
	for _, title := range []string{"Open alpha task", "Old feature", "Old task", "Old alpha task"} {
		assert.Contains(t, all, title)
	}

	plain := callReadString(t, fx.reg, "list_targets", `{"include_archived":true}`)
	assert.NotContains(t, plain, "Old feature", "outside a workbench session nothing changes (PROJ-01)")
}

func TestGetTarget_FindsAnArchivedTargetAndSaysSo(t *testing.T) {
	fx := newArchiveFixture(t)

	got := callReadIn(t, fx.reg, fx.a, "get_target", fmt.Sprintf(`{"id":%d}`, fx.oldTask))
	assert.Contains(t, got, `"archived":true`)
	assert.Contains(t, got, "Old task")
	open := callReadIn(t, fx.reg, fx.a, "get_target", fmt.Sprintf(`{"id":%d}`, fx.aTarget))
	assert.Contains(t, open, `"archived":false`)
}

// Restoring is reopening (owner decision D): update_target on an archived
// target brings it and its archived parent back.
func TestUpdateTarget_ReopeningRestoresAnArchivedTarget(t *testing.T) {
	fx := newArchiveFixture(t)

	mustApply(t, fx.reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"status":"todo","reason":"more to do"}`, fx.oldTask))

	got := callReadIn(t, fx.reg, fx.a, "workbench_board", `{}`)
	assert.Contains(t, got, "Old feature")
	assert.Contains(t, got, "Old task")
	assert.Contains(t, got, `"archived":1`, "only the alpha task is still archived")
}

func TestCreateTargets_UnderAnArchivedParentBringsItBack(t *testing.T) {
	fx := newArchiveFixture(t)

	mustApply(t, fx.reg, fx.a, "create_targets", fmt.Sprintf(
		`{"items":[{"text":"Follow-up","parent_id":%d}],"reason":"a regression"}`, fx.oldFeature))

	got := callReadIn(t, fx.reg, fx.a, "workbench_board", `{}`)
	assert.Contains(t, got, "Old feature")
	assert.Contains(t, got, "Follow-up")
	assert.NotContains(t, got, "Old task", "its old task stays archived on its own")
}

// The answer stays small on a long board whose closed work is too recent to
// be archived (owner decision A): 300 targets, 280 of them closed.
func TestWorkbenchBoard_LongMostlyClosedBoardStaysSmall(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	_, err := fx.d.Exec(`DELETE FROM targets WHERE project_id = ?`, fx.a)
	require.NoError(t, err)
	intent := strings.Repeat("A sentence or two on why this target exists and what done means. ", 4)
	var items []db.WorkbenchTargetInput
	for f := range 20 {
		items = append(items, db.WorkbenchTargetInput{Title: fmt.Sprintf("Feature %d", f), Intent: intent})
		parent := len(items)
		for k := range 14 {
			items = append(items, db.WorkbenchTargetInput{Title: fmt.Sprintf("Task %d.%d", f, k), Intent: intent, BatchParent: parent})
		}
	}
	var ids []int64
	require.NoError(t, fx.d.WithTx(func(tx *sql.Tx) error {
		ids, err = fx.d.CreateWorkbenchTargetsTx(tx, fx.a, items)
		return err
	}))
	// Features 0–9 close whole (the rollup closes each feature); 10–19 keep
	// their last task open.
	for i, id := range ids {
		f, k := i/15, i%15
		if k > 0 && (f < 10 || k < 14) {
			require.NoError(t, fx.d.UpdateTargetStatus(int(id), "done"))
		}
	}

	got := callReadIn(t, reg, fx.a, "workbench_board", `{}`)
	assert.Less(t, len(got), 40000)
	var v workbenchBoardView
	require.NoError(t, json.Unmarshal([]byte(got), &v))
	assert.Len(t, v.Targets, 10)
	assert.Equal(t, 280, v.Closed)
	assert.Zero(t, v.Archived)
}
