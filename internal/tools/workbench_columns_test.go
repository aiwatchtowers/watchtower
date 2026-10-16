package tools

import (
	"database/sql"
	"fmt"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// Board columns (PROJ-19, board #267): the agent moves a card with
// update_target column, a hidden status is never set on the workbench
// surface, and the readers show the column only when columns are defined.

// seedColumns defines Backlog/Ready (todo) and Spec/Code (in_progress) on
// workbench, hiding hidden, and returns the column ids by title.
func seedColumns(t *testing.T, d *db.DB, workbench int64, hidden ...string) map[string]int64 {
	t.Helper()
	if hidden == nil {
		hidden = []string{}
	}
	def, err := d.ReplaceBoardColumns(workbench, db.BoardColumns{Columns: []db.BoardColumn{
		{Status: "todo", Title: "Backlog", Description: "not yet looked at"},
		{Status: "todo", Title: "Ready", Description: "spec agreed, can start"},
		{Status: "in_progress", Title: "Spec", Description: "writing the design"},
		{Status: "in_progress", Title: "Code", Description: "building it"},
	}, Hidden: hidden})
	require.NoError(t, err)
	ids := map[string]int64{}
	for _, c := range def.Columns {
		ids[c.Title] = c.ID
	}
	return ids
}

// targetColumn reads a target's status and stored board column.
func targetColumn(t *testing.T, d *db.DB, id int64) (string, sql.NullInt64) {
	t.Helper()
	var status string
	var col sql.NullInt64
	require.NoError(t, d.QueryRow(`SELECT status, board_column_id FROM targets WHERE id = ?`, id).Scan(&status, &col))
	return status, col
}

func columnRefusal(t *testing.T, reg *Registry, workbench int64, args string) string {
	t.Helper()
	_, err := proposeIn(t, reg, workbench, "update_target", args)
	var verr *ValidationError
	require.ErrorAs(t, err, &verr, args)
	return verr.Msg
}

func TestUpdateTarget_ColumnSetsStatusAndColumn(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	ids := seedColumns(t, fx.d, fx.a)

	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"column":"Code","reason":"building"}`, fx.aTarget))

	status, col := targetColumn(t, fx.d, fx.aTarget)
	assert.Equal(t, "in_progress", status)
	assert.Equal(t, sql.NullInt64{Int64: ids["Code"], Valid: true}, col)
	history, err := fx.d.GetTargetStatusHistory(fx.aTarget, db.MaxStatusHistory)
	require.NoError(t, err)
	require.NotEmpty(t, history)
	last := history[len(history)-1]
	assert.Equal(t, "in_progress", last.ToStatus)
	assert.Equal(t, db.ActorAgent, last.Actor)

	// By id, within the same status: the column moves, no new history row.
	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"column":"%d","reason":"back to spec"}`, fx.aTarget, ids["Spec"]))
	status, col = targetColumn(t, fx.d, fx.aTarget)
	assert.Equal(t, "in_progress", status)
	assert.Equal(t, sql.NullInt64{Int64: ids["Spec"], Valid: true}, col)
	again, err := fx.d.GetTargetStatusHistory(fx.aTarget, db.MaxStatusHistory)
	require.NoError(t, err)
	assert.Len(t, again, len(history))
}

func TestUpdateTarget_ColumnResolvesByTitleCaseInsensitiveAndImplicitLabel(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	ids := seedColumns(t, fx.d, fx.a)

	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"column":"  spec ","reason":"r"}`, fx.aTarget))
	status, col := targetColumn(t, fx.d, fx.aTarget)
	assert.Equal(t, "in_progress", status)
	assert.Equal(t, sql.NullInt64{Int64: ids["Spec"], Valid: true}, col)

	// "done" is the standard label of a status without defined columns.
	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"column":"done","status":"done","reason":"r"}`, fx.aTarget))
	status, col = targetColumn(t, fx.d, fx.aTarget)
	assert.Equal(t, "done", status)
	assert.False(t, col.Valid)
}

func TestUpdateTarget_ColumnStatusConflictRefused(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	seedColumns(t, fx.d, fx.a)

	msg := columnRefusal(t, reg, fx.a, fmt.Sprintf(`{"target_id":%d,"column":"code","status":"done","reason":"r"}`, fx.aTarget))
	assert.Equal(t, `column "Code" is in in_progress, status says done — send one of them`, msg)
	status, col := targetColumn(t, fx.d, fx.aTarget)
	assert.Equal(t, "todo", status)
	assert.False(t, col.Valid)
}

func TestUpdateTarget_ColumnOnParentRefused(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	seedColumns(t, fx.d, fx.a)
	db.SeedTestWorkbenchTarget(t, fx.d, fx.a, sql.NullInt64{Int64: fx.aTarget, Valid: true}, "Task")

	for _, column := range []string{"Code", ""} {
		msg := columnRefusal(t, reg, fx.a, fmt.Sprintf(`{"target_id":%d,"column":%q,"reason":"r"}`, fx.aTarget, column))
		assert.Equal(t, "columns apply to leaf targets", msg)
	}
}

func TestUpdateTarget_HiddenStatusRefused(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	seedColumns(t, fx.d, fx.a, "in_review", "blocked")
	want := map[string]string{
		"in_review": "in_review is turned off on this board — go straight to done once the review passes",
		"blocked":   "blocked is turned off on this board — leave it in_progress; the open ask already shows the owner what waits",
	}
	for status, label := range map[string]string{"in_review": "In Review", "blocked": "Blocked"} {
		msg := columnRefusal(t, reg, fx.a, fmt.Sprintf(`{"target_id":%d,"status":%q,"reason":"r"}`, fx.aTarget, status))
		assert.Equal(t, want[status], msg, "via status")
		msg = columnRefusal(t, reg, fx.a, fmt.Sprintf(`{"target_id":%d,"column":%q,"reason":"r"}`, fx.aTarget, label))
		assert.Equal(t, want[status], msg, "via column")
		assert.Equal(t, want[status], hiddenStatusRefusal(status).Error())
	}
	got, _ := targetColumn(t, fx.d, fx.aTarget)
	assert.Equal(t, "todo", got)

	// Another workbench without the definition still takes in_review.
	mustApply(t, reg, fx.b, "update_target", fmt.Sprintf(`{"target_id":%d,"status":"in_review","reason":"r"}`, fx.bTarget))
}

func TestUpdateTarget_UnknownColumnListsTitles(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	seedColumns(t, fx.d, fx.a, "in_review")

	msg := columnRefusal(t, reg, fx.a, fmt.Sprintf(`{"target_id":%d,"column":"QA","reason":"r"}`, fx.aTarget))
	assert.Equal(t, `no column "QA" on this board; its columns: Backlog, Ready, Spec, Code, Blocked, Done, Dismissed`, msg)
}

func TestUpdateTarget_EmptyColumnClears(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	seedColumns(t, fx.d, fx.a)
	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"column":"Code","reason":"r"}`, fx.aTarget))

	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"column":"","reason":"r"}`, fx.aTarget))
	status, col := targetColumn(t, fx.d, fx.aTarget)
	assert.Equal(t, "in_progress", status)
	assert.False(t, col.Valid)
}

func TestWorkbenchBoard_ColumnFieldOnlyWithDefinition(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	child := db.SeedTestWorkbenchTarget(t, fx.d, fx.a, sql.NullInt64{Int64: fx.aTarget, Valid: true}, "Task")

	assert.NotContains(t, callReadIn(t, reg, fx.a, "workbench_board", `{}`), `"column"`)

	seedColumns(t, fx.d, fx.a)
	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"column":"Code","reason":"r"}`, child))
	got := callReadIn(t, reg, fx.a, "workbench_board", `{}`)
	assert.Contains(t, got, `"column":"Code"`)
	assert.Contains(t, got, `"text":"Alpha feature","status":"in_progress"`, "the parent carries no column")
	assert.NotContains(t, callReadIn(t, reg, fx.b, "workbench_board", `{}`), `"column"`)
}

func TestGetTarget_ColumnField(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	args := fmt.Sprintf(`{"id":%d}`, fx.aTarget)
	assert.NotContains(t, callReadIn(t, reg, fx.a, "get_target", args), `"column"`)

	seedColumns(t, fx.d, fx.a)
	assert.Contains(t, callReadIn(t, reg, fx.a, "get_target", args), `"column":"Backlog"`, "a NULL column is its status's first")
	mustApply(t, reg, fx.a, "update_target", fmt.Sprintf(`{"target_id":%d,"column":"Code","reason":"r"}`, fx.aTarget))
	assert.Contains(t, callReadIn(t, reg, fx.a, "get_target", args), `"column":"Code"`)
}

func TestWorkbenchInfo_ColumnsOnlyWhenDefined(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	got := callReadIn(t, reg, fx.a, "workbench_info", `{}`)
	assert.NotContains(t, got, `"columns"`)
	assert.NotContains(t, got, `"hidden_statuses"`)

	ids := seedColumns(t, fx.d, fx.a, "blocked")
	got = callReadIn(t, reg, fx.a, "workbench_info", `{}`)
	assert.Contains(t, got, `"columns":[{"id":`+strconv.FormatInt(ids["Backlog"], 10)+`,"status":"todo","title":"Backlog","description":"not yet looked at","position":0}`)
	assert.Contains(t, got, `"hidden_statuses":["blocked"]`)

	_, err := fx.d.ReplaceBoardColumns(fx.a, db.BoardColumns{Hidden: []string{"in_review"}})
	require.NoError(t, err)
	got = callReadIn(t, reg, fx.a, "workbench_info", `{}`)
	assert.NotContains(t, got, `"columns"`)
	assert.Contains(t, got, `"hidden_statuses":["in_review"]`)
}

// PROJ-19 anti-goal: with no columns and nothing hidden, every agent-facing
// output is byte-identical to a board that never had a definition.
func TestProj19_NoDefinitionAgentOutputsUnchanged(t *testing.T) {
	fx := newWorkbenchFixture(t)
	reg := workbenchRegistry(t, fx.d)
	db.SeedTestWorkbenchTarget(t, fx.d, fx.a, sql.NullInt64{Int64: fx.aTarget, Valid: true}, "Task")
	reads := []struct{ name, args string }{
		{"workbench_board", `{}`},
		{"get_target", fmt.Sprintf(`{"id":%d}`, fx.aTarget)},
		{"workbench_info", `{}`},
	}
	before := map[string]string{}
	for _, r := range reads {
		before[r.name] = callReadIn(t, reg, fx.a, r.name, r.args)
		for _, key := range []string{`"column"`, `"columns"`, `"hidden_statuses"`} {
			assert.NotContains(t, before[r.name], key, r.name)
		}
	}

	// A definition written and then emptied again leaves nothing behind.
	seedColumns(t, fx.d, fx.a, "in_review")
	_, err := fx.d.ReplaceBoardColumns(fx.a, db.BoardColumns{})
	require.NoError(t, err)
	for _, r := range reads {
		assert.Equal(t, before[r.name], callReadIn(t, reg, fx.a, r.name, r.args), r.name)
	}
}
