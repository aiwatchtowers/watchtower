package db

import (
	"database/sql"
	"errors"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Migration 00125: per-workbench board columns inside the status categories
// (PROJ-19, board #267). Triggers keep a target's column inside its
// workbench and its current status; column moves write no status history.

func replaceColumns(t *testing.T, d *DB, wb int64, cols ...BoardColumn) BoardColumns {
	t.Helper()
	out, err := d.ReplaceBoardColumns(wb, BoardColumns{Columns: cols})
	require.NoError(t, err)
	return out
}

func columnID(t *testing.T, b BoardColumns, title string) int64 {
	t.Helper()
	for _, c := range b.Columns {
		if c.Title == title {
			return c.ID
		}
	}
	t.Fatalf("no column %q in %+v", title, b.Columns)
	return 0
}

func targetColumn(t *testing.T, d *DB, id int64) sql.NullInt64 {
	t.Helper()
	var c sql.NullInt64
	require.NoError(t, d.QueryRow(`SELECT board_column_id FROM targets WHERE id = ?`, id).Scan(&c))
	return c
}

func setColumn(t *testing.T, d *DB, id int64, status string, col *int64) {
	t.Helper()
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		return d.SetTargetColumnTx(tx, id, status, col, ActorAgent)
	}))
}

func TestProj19_ColumnMustMatchStatusAndWorkbench(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	other := newTestWorkbench(t, d)
	cols := replaceColumns(t, d, wb,
		BoardColumn{Status: "todo", Title: "Backlog"},
		BoardColumn{Status: "in_progress", Title: "Code"})
	foreign := replaceColumns(t, d, other, BoardColumn{Status: "todo", Title: "Inbox"})
	tid := SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "task")

	_, err := d.Exec(`UPDATE targets SET board_column_id = ? WHERE id = ?`, columnID(t, cols, "Code"), tid)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "board column does not match the target")

	_, err = d.Exec(`UPDATE targets SET board_column_id = ? WHERE id = ?`, columnID(t, foreign, "Inbox"), tid)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "board column does not match the target")

	// An insert carrying a foreign column is refused too.
	_, err = d.Exec(`INSERT INTO targets (text, level, custom_label, period_start, period_end, source_type, project_id, board_column_id)
		VALUES ('x', 'custom', 'project', '2026-10-16', '2026-10-16', 'chat', ?, ?)`, wb, columnID(t, cols, "Code"))
	require.Error(t, err)
	assert.Contains(t, err.Error(), "board column does not match the target")

	backlog := columnID(t, cols, "Backlog")
	_, err = d.Exec(`UPDATE targets SET board_column_id = ? WHERE id = ?`, backlog, tid)
	require.NoError(t, err)
	assert.Equal(t, nullID(backlog), targetColumn(t, d, tid))
}

func TestProj19_StatusChangeClearsForeignColumn(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	cols := replaceColumns(t, d, wb, BoardColumn{Status: "in_progress", Title: "Code"})
	tid := SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "task")
	code := columnID(t, cols, "Code")
	setColumn(t, d, tid, "in_progress", &code)
	before := len(statusHistory(t, d, tid))

	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		return d.UpdateTargetStatusAsTx(tx, int(tid), "done", ActorAgent)
	}))
	assert.Equal(t, "done", targetStatus(t, d, tid))
	assert.False(t, targetColumn(t, d, tid).Valid, "leaving the column's status clears the column")
	h := statusHistory(t, d, tid)
	require.Len(t, h, before+1)
	assert.Equal(t, [3]string{"in_progress", "done", "agent"}, transitions(h)[before])
}

func TestProj19_StatusAndColumnInOneStatement(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	cols := replaceColumns(t, d, wb, BoardColumn{Status: "in_progress", Title: "Code"})
	tid := SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "task")
	code := columnID(t, cols, "Code")
	before := len(statusHistory(t, d, tid))

	setColumn(t, d, tid, "in_progress", &code)

	assert.Equal(t, "in_progress", targetStatus(t, d, tid))
	assert.Equal(t, nullID(code), targetColumn(t, d, tid))
	h := statusHistory(t, d, tid)
	require.Len(t, h, before+1)
	assert.Equal(t, [3]string{"todo", "in_progress", "agent"}, transitions(h)[before])
	assert.False(t, statusActor(t, d, tid).Valid, "the claim never outlives its write")
}

func TestProj19_ColumnMoveWritesNoHistory(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	cols := replaceColumns(t, d, wb,
		BoardColumn{Status: "in_progress", Title: "Code"},
		BoardColumn{Status: "in_progress", Title: "Test"})
	tid := SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "task")
	code, test := columnID(t, cols, "Code"), columnID(t, cols, "Test")
	setColumn(t, d, tid, "in_progress", &code)
	before := len(statusHistory(t, d, tid))

	setColumn(t, d, tid, "in_progress", &test)
	assert.Equal(t, nullID(test), targetColumn(t, d, tid))
	setColumn(t, d, tid, "in_progress", nil)
	assert.False(t, targetColumn(t, d, tid).Valid)

	assert.Len(t, statusHistory(t, d, tid), before)
	assert.False(t, statusActor(t, d, tid).Valid, "an unused claim is dropped")
}

// A move between two columns of the same status writes only the column:
// the leaf's progress stays and no history row is written.
func TestProj19_SameStatusColumnMoveKeepsProgress(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	cols := replaceColumns(t, d, wb,
		BoardColumn{Status: "in_progress", Title: "Spec"},
		BoardColumn{Status: "in_progress", Title: "Code"})
	tid := SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "task")
	spec, code := columnID(t, cols, "Spec"), columnID(t, cols, "Code")
	setColumn(t, d, tid, "in_progress", &spec)
	require.NoError(t, d.SetTargetProgress(int(tid), 0.4))
	before := len(statusHistory(t, d, tid))

	setColumn(t, d, tid, "in_progress", &code)

	assert.Equal(t, nullID(code), targetColumn(t, d, tid))
	got, err := d.GetTargetByID(int(tid))
	require.NoError(t, err)
	assert.InDelta(t, 0.4, got.Progress, 1e-9, "a column move keeps the progress")
	assert.Len(t, statusHistory(t, d, tid), before)

	// A status change still resets it as today.
	setColumn(t, d, tid, "done", nil)
	got, err = d.GetTargetByID(int(tid))
	require.NoError(t, err)
	assert.InDelta(t, 1.0, got.Progress, 1e-9)
}

func TestProj19_DeletedColumnFallsBack(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	cols := replaceColumns(t, d, wb,
		BoardColumn{Status: "in_progress", Title: "Code"},
		BoardColumn{Status: "in_progress", Title: "Test"})
	tid := SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "task")
	code := columnID(t, cols, "Code")
	setColumn(t, d, tid, "in_progress", &code)

	kept := cols.Columns[1]
	replaceColumns(t, d, wb, kept)

	assert.False(t, targetColumn(t, d, tid).Valid)
	assert.Equal(t, "in_progress", targetStatus(t, d, tid))
}

func TestProj19_SnoozeClearsColumn(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	cols := replaceColumns(t, d, wb,
		BoardColumn{Status: "todo", Title: "Backlog"},
		BoardColumn{Status: "todo", Title: "Ready"})
	tid := SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "task")
	ready := columnID(t, cols, "Ready")
	setColumn(t, d, tid, "todo", &ready)

	require.NoError(t, d.UpdateTargetStatus(int(tid), "snoozed"))
	assert.False(t, targetColumn(t, d, tid).Valid)
	require.NoError(t, d.UpdateTargetStatus(int(tid), "todo"))
	assert.False(t, targetColumn(t, d, tid).Valid)
}

func TestReplaceBoardColumns_Validates(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	other := newTestWorkbench(t, d)
	stored := replaceColumns(t, d, wb, BoardColumn{Status: "in_progress", Title: "Code"})
	foreign := replaceColumns(t, d, other, BoardColumn{Status: "todo", Title: "Inbox"})
	code := stored.Columns[0]

	many := func(n int, status func(i int) string) []BoardColumn {
		out := make([]BoardColumn, n)
		for i := range out {
			out[i] = BoardColumn{Status: status(i), Title: "C" + strconv.Itoa(i)}
		}
		return out
	}
	cases := map[string]BoardColumns{
		"seven in one status":  {Columns: many(7, func(int) string { return "todo" })},
		"21 in total":          {Columns: many(21, func(i int) string { return BoardStatusOrder[i%len(BoardStatusOrder)] })},
		"empty title":          {Columns: []BoardColumn{{Status: "todo", Title: "   "}}},
		"41-char title":        {Columns: []BoardColumn{{Status: "todo", Title: strings.Repeat("a", 41)}}},
		"duplicate title":      {Columns: []BoardColumn{{Status: "todo", Title: "Spec"}, {Status: "in_progress", Title: "spec"}}},
		"another status label": {Columns: []BoardColumn{{Status: "todo", Title: "done"}}},
		"501-char description": {Columns: []BoardColumn{{Status: "todo", Title: "A", Description: strings.Repeat("d", 501)}}},
		"digits-only title":    {Columns: []BoardColumn{{Status: "todo", Title: " 12 "}}},
		"unknown status":       {Columns: []BoardColumn{{Status: "snoozed", Title: "Later"}}},
		"hiding todo":          {Hidden: []string{"todo"}},
		"status change":        {Columns: []BoardColumn{{ID: code.ID, Status: "todo", Title: "Code"}}},
		"another workbench id": {Columns: []BoardColumn{code, {ID: foreign.Columns[0].ID, Status: "todo", Title: "Inbox"}}},
		"hidden with columns":  {Columns: []BoardColumn{{Status: "in_review", Title: "QA"}}, Hidden: []string{"in_review"}},
	}
	for name, in := range cases {
		t.Run(name, func(t *testing.T) {
			_, err := d.ReplaceBoardColumns(wb, in)
			var bce *BoardColumnsError
			require.True(t, errors.As(err, &bce), "want *BoardColumnsError, got %v", err)
			assert.NotEmpty(t, bce.Msg)
			got, err := d.GetBoardColumns(wb)
			require.NoError(t, err)
			assert.Equal(t, stored, got, "nothing written")
		})
	}

	_, err := d.ReplaceBoardColumns(wb, BoardColumns{Columns: []BoardColumn{{ID: code.ID, Status: "todo", Title: "Code"}}})
	assert.EqualError(t, err, `column "Code": status cannot change (delete it and add a new one)`)
}

func TestReplaceBoardColumns_KeepsIDsAndOrder(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	cols := replaceColumns(t, d, wb,
		BoardColumn{Status: "in_progress", Title: "Code"},
		BoardColumn{Status: "todo", Title: "Backlog"})
	code, backlog := columnID(t, cols, "Code"), columnID(t, cols, "Backlog")
	tid := SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "task")
	setColumn(t, d, tid, "in_progress", &code)

	out, err := d.ReplaceBoardColumns(wb, BoardColumns{
		Columns: []BoardColumn{
			{Status: "in_progress", Title: "Review prep"},
			{ID: code, Status: "in_progress", Title: "Coding", Description: "write it"},
			{Status: "todo", Title: "Ready"},
			{ID: backlog, Status: "todo", Title: "Backlog"},
		},
		Hidden: []string{"blocked", "in_review", "blocked"},
	})
	require.NoError(t, err)

	type row struct {
		status, title string
		pos           int
	}
	var got []row
	for _, c := range out.Columns {
		got = append(got, row{c.Status, c.Title, c.Position})
	}
	assert.Equal(t, []row{
		{"todo", "Ready", 0}, {"todo", "Backlog", 1},
		{"in_progress", "Review prep", 0}, {"in_progress", "Coding", 1},
	}, got)
	assert.Equal(t, code, columnID(t, out, "Coding"))
	assert.Equal(t, backlog, columnID(t, out, "Backlog"))
	assert.Equal(t, "write it", out.Columns[3].Description)
	assert.Equal(t, []string{"in_review", "blocked"}, out.Hidden)
	assert.Equal(t, nullID(code), targetColumn(t, d, tid), "an updated column keeps its targets")

	again, err := d.GetBoardColumns(wb)
	require.NoError(t, err)
	assert.Equal(t, out, again)

	// Clearing everything leaves an empty definition.
	cleared, err := d.ReplaceBoardColumns(wb, BoardColumns{})
	require.NoError(t, err)
	assert.True(t, cleared.IsEmpty())
	assert.NotNil(t, cleared.Hidden)
}

func TestBoardColumnsResolve(t *testing.T) {
	b := BoardColumns{Columns: []BoardColumn{
		{ID: 7, Status: "todo", Title: "Backlog"},
		{ID: 9, Status: "in_progress", Title: "Spec"},
	}, Hidden: []string{"blocked"}}

	status, col, ok := b.Resolve("9")
	require.True(t, ok)
	assert.Equal(t, "in_progress", status)
	require.NotNil(t, col)
	assert.Equal(t, int64(9), *col)

	status, col, ok = b.Resolve(" sPEC ")
	require.True(t, ok)
	assert.Equal(t, "in_progress", status)
	assert.Equal(t, int64(9), *col)

	status, col, ok = b.Resolve("done")
	require.True(t, ok)
	assert.Equal(t, "done", status)
	assert.Nil(t, col)

	status, col, ok = b.Resolve("IN REVIEW")
	require.True(t, ok)
	assert.Equal(t, "in_review", status)
	assert.Nil(t, col)

	_, _, ok = b.Resolve("To Do") // todo has its own columns
	assert.False(t, ok)
	_, _, ok = b.Resolve("Nowhere")
	assert.False(t, ok)
	_, _, ok = b.Resolve("8")
	assert.False(t, ok)

	assert.True(t, b.IsHidden("blocked"))
	assert.False(t, b.IsHidden("in_review"))
	assert.False(t, b.IsEmpty())
	assert.True(t, BoardColumns{Hidden: []string{}}.IsEmpty())
	assert.False(t, BoardColumns{Hidden: []string{"blocked"}}.IsEmpty())
}

func TestGetWorkbenchBoard_ColumnOnLeavesOnly(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	parent := SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "feature")
	inCode := SeedTestWorkbenchTarget(t, d, wb, nullID(parent), "coding")
	inTodo := SeedTestWorkbenchTarget(t, d, wb, nullID(parent), "waiting")

	columnsOf := func() map[int64]string {
		board, err := d.GetWorkbenchBoard(wb)
		require.NoError(t, err)
		out := map[int64]string{}
		var walk func([]BoardNode)
		walk = func(ns []BoardNode) {
			for _, n := range ns {
				out[int64(n.Target.ID)] = n.Column
				walk(n.Children)
			}
		}
		walk(board)
		return out
	}
	assert.Equal(t, map[int64]string{parent: "", inCode: "", inTodo: ""}, columnsOf(), "no definition")

	cols := replaceColumns(t, d, wb,
		BoardColumn{Status: "todo", Title: "Backlog"},
		BoardColumn{Status: "todo", Title: "Ready"},
		BoardColumn{Status: "in_progress", Title: "Code"})
	code := columnID(t, cols, "Code")
	setColumn(t, d, inCode, "in_progress", &code)
	// The parent (now in_progress by the rollup) carries a stored column that
	// readers ignore.
	_, err := d.Exec(`UPDATE targets SET board_column_id = ? WHERE id = ?`, code, parent)
	require.NoError(t, err)

	assert.Equal(t, map[int64]string{parent: "", inCode: "Code", inTodo: "Backlog"}, columnsOf())
}

func TestMigration00125_DownUp(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "cols.db"))
	require.NoError(t, err)
	defer d.Close()
	assert.True(t, columnNames(t, d.DB, "targets")["board_column_id"])
	assert.True(t, columnNames(t, d.DB, "projects")["board_hidden_statuses"])

	require.NoError(t, goose.DownTo(d.DB, "migrations", 124))
	assert.False(t, columnNames(t, d.DB, "targets")["board_column_id"])
	assert.False(t, columnNames(t, d.DB, "projects")["board_hidden_statuses"])
	require.NoError(t, goose.Up(d.DB, "migrations"))
	assert.True(t, columnNames(t, d.DB, "targets")["board_column_id"])
}

func TestGetWorkbenchBoard_UndecodableHiddenStatusesStillReadsColumns(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	tid := SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "task")
	replaceColumns(t, d, wb, BoardColumn{Status: "todo", Title: "Backlog"})
	_, err := d.Exec(`UPDATE projects SET board_hidden_statuses = 'not json' WHERE id = ?`, wb)
	require.NoError(t, err)

	board, err := d.GetWorkbenchBoard(wb)

	require.NoError(t, err)
	require.Len(t, board, 1)
	assert.Equal(t, tid, int64(board[0].Target.ID))
	assert.Equal(t, "Backlog", board[0].Column)
}
