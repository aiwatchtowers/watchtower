package workbenchfolders

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

// mergeKeyAllowlist is every workbench-looking key that is not a Watchtower
// workbench id, with the reason.
var mergeKeyAllowlist = map[string]string{
	"chat_conversations.project_id":   "references chat_projects (chat projects, not workbenches)",
	"chat_attachments.project_id":     "references chat_projects",
	"chat_project_sources.project_id": "references chat_projects",
	"linear_issues.project_id":        "a Linear project id (TEXT)",
}

// workbenchKeyedColumns is every table.column of the live schema keyed by a
// workbench id: a foreign key to projects, or a column named project_id or
// workbench_id.
func workbenchKeyedColumns(t *testing.T, d *db.DB) []string {
	t.Helper()
	rows, err := d.Query(`SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name <> 'projects'`)
	require.NoError(t, err)
	var tables []string
	for rows.Next() {
		var n string
		require.NoError(t, rows.Scan(&n))
		tables = append(tables, n)
	}
	require.NoError(t, rows.Err())
	require.NoError(t, rows.Close())
	keyed := map[string]bool{}
	for _, tbl := range tables {
		cols, err := d.Query(`SELECT name FROM pragma_table_info(?)`, tbl)
		require.NoError(t, err)
		for cols.Next() {
			var c string
			require.NoError(t, cols.Scan(&c))
			if c == "project_id" || c == "workbench_id" {
				keyed[tbl+"."+c] = true
			}
		}
		require.NoError(t, cols.Close())
		fks, err := d.Query(`SELECT "table", "from" FROM pragma_foreign_key_list(?)`, tbl)
		require.NoError(t, err)
		for fks.Next() {
			var parent, from string
			require.NoError(t, fks.Scan(&parent, &from))
			if parent == "projects" {
				keyed[tbl+"."+from] = true
			}
		}
		require.NoError(t, fks.Close())
	}
	out := make([]string, 0, len(keyed))
	for k := range keyed {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func TestMergeCoversEveryWorkbenchKeyedTable(t *testing.T) {
	d := testDB(t)
	covered := map[string]bool{}
	for _, m := range mergeTables {
		covered[m.table+"."+m.column] = true
	}
	var missing []string
	for _, key := range workbenchKeyedColumns(t, d) {
		if !covered[key] && mergeKeyAllowlist[key] == "" {
			missing = append(missing, key)
		}
	}
	assert.Empty(t, missing, "tables keyed by a workbench id that Merge does not move: add them to mergeTables (or to the allowlist with a reason)")
	keys := map[string]bool{}
	for _, k := range workbenchKeyedColumns(t, d) {
		keys[k] = true
	}
	for _, m := range mergeTables {
		assert.True(t, keys[m.table+"."+m.column], "mergeTables names %s.%s, which the schema does not have", m.table, m.column)
	}
}

// insertTarget inserts a workbench target; the triggers derive the parent's
// status as a board write would.
func insertTarget(t *testing.T, d *db.DB, wb int64, text, status string, parent int64, column int64) int64 {
	t.Helper()
	var p, c any
	if parent != 0 {
		p = parent
	}
	if column != 0 {
		c = column
	}
	res, err := d.Exec(`INSERT INTO targets (text, period_start, period_end, status, project_id, parent_id, board_column_id)
		VALUES (?, '2026-11-01', '2026-11-30', ?, ?, ?, ?)`, text, status, wb, p, c)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

func insertColumn(t *testing.T, d *db.DB, wb int64, status, title string, pos int) int64 {
	t.Helper()
	res, err := d.Exec(`INSERT INTO workbench_board_columns (project_id, status, title, position, created_at)
		VALUES (?, ?, ?, ?, '2026-11-01T00:00:00Z')`, wb, status, title, pos)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)
	return id
}

type targetState struct {
	project, parent sql.NullInt64
	status          string
	column, folder  sql.NullInt64
}

func readTarget(t *testing.T, d *db.DB, id int64) targetState {
	t.Helper()
	var s targetState
	require.NoError(t, d.QueryRow(`SELECT project_id, parent_id, status, board_column_id, workbench_folder_id FROM targets WHERE id = ?`, id).
		Scan(&s.project, &s.parent, &s.status, &s.column, &s.folder))
	return s
}

func countRows(t *testing.T, d *db.DB, q string, args ...any) int {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(q, args...).Scan(&n))
	return n
}

func homeOf(t *testing.T, d *db.DB, wb int64) db.WorkbenchFolder {
	t.Helper()
	f, err := d.HomeFolder(context.Background(), wb)
	require.NoError(t, err)
	return *f
}

// PROJ-09 (amended, ask #1548): a merge moves every target of the merged
// bench with its tree intact — parents, children, statuses — into the
// surviving bench, each in that bench's first column of its status
// (PROJ-19), and the PROJ-05 rollup keeps working on the moved tree.
func TestProj09_MergeMovesEveryTargetWithItsTree(t *testing.T) {
	ctx := context.Background()
	d := testDB(t)
	a := bench(t, d, "acme", dir(t, "acme"))
	b := bench(t, d, "tools", dir(t, "tools"))
	aFirst := insertColumn(t, d, a, "in_progress", "Doing", 0)
	bCol := insertColumn(t, d, b, "in_progress", "Building", 0)
	insertTarget(t, d, a, "a's own", "todo", 0, 0)

	// A tree whose rollup holds only with every child counted: moving the
	// rows one by one with the trigger live would re-derive the parent from
	// a part of them.
	parent := insertTarget(t, d, b, "parent", "todo", 0, 0)
	done := insertTarget(t, d, b, "done child", "done", parent, 0)
	open := insertTarget(t, d, b, "open child", "todo", parent, 0)
	grand := insertTarget(t, d, b, "grandchild", "todo", open, 0)
	_, err := d.Exec(`UPDATE targets SET board_column_id = ? WHERE id = ?`, bCol, parent)
	require.NoError(t, err)
	before := map[int64]targetState{}
	for _, id := range []int64{parent, done, open, grand} {
		before[id] = readTarget(t, d, id)
	}
	require.Equal(t, "in_progress", before[parent].status, "the seeded tree rolled up")
	history := countRows(t, d, `SELECT COUNT(*) FROM target_status_history`)

	rep, err := Merge(ctx, d, b, a, nil)
	require.NoError(t, err)
	assert.Equal(t, 4, rep.Targets)

	bHome := before[parent].folder
	for id, was := range before {
		now := readTarget(t, d, id)
		assert.Equal(t, a, now.project.Int64, "target %d moved", id)
		assert.Equal(t, was.parent, now.parent, "target %d keeps its parent", id)
		assert.Equal(t, was.status, now.status, "target %d keeps its status", id)
		assert.False(t, now.column.Valid, "target %d lands in A's first column of its status", id)
		if !bHome.Valid {
			assert.True(t, now.folder.Valid, "target %d is pinned to B's home folder", id)
		}
	}
	assert.Equal(t, history, countRows(t, d, `SELECT COUNT(*) FROM target_status_history`), "no status changed")
	assert.Zero(t, countRows(t, d, `SELECT COUNT(*) FROM workbench_board_columns WHERE id = ?`, bCol), "B's columns are dropped")
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM workbench_board_columns WHERE id = ?`, aFirst))

	// PROJ-05 still rolls the moved tree up: the trigger is back.
	_, err = d.Exec(`UPDATE targets SET status = 'done' WHERE id = ?`, grand)
	require.NoError(t, err)
	assert.Equal(t, "done", readTarget(t, d, open).status)
	assert.Equal(t, "done", readTarget(t, d, parent).status)
}

func TestMergeMovesEveryKeyedRowAndDeletesTheBench(t *testing.T) {
	ctx := context.Background()
	d := testDB(t)
	aDir, bDir := dir(t, "acme"), dir(t, "tools")
	a := bench(t, d, "acme", aDir)
	b := bench(t, d, "tools", bDir)
	bHome := homeOf(t, d, b)
	sess := seedSession(t, d, bHome)
	_, err := d.Exec(`UPDATE terminal_sessions SET finished_at = '2026-11-01T00:00:00.000Z', workbench_folder_id = NULL WHERE id = ?`, sess)
	require.NoError(t, err)
	for _, q := range []string{
		`INSERT INTO project_sources (project_id, kind, ref) VALUES (?, 'link', 'https://example.com/shared')`,
		`INSERT INTO workbench_folder_declines (workbench_id, folder_path) VALUES (?, '/tmp/never')`,
	} {
		_, err = d.Exec(q, b)
		require.NoError(t, err, q)
	}
	_, err = d.Exec(`INSERT INTO project_sources (project_id, kind, ref) VALUES (?, 'link', 'https://example.com/shared')`, a)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO project_sources (project_id, kind, ref) VALUES (?, 'link', 'https://example.com/b-only')`, b)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO permission_requests (terminal_session_id, workbench_id, tool_name, status, created_at)
		VALUES (?, ?, 'Bash', 'pending', '2026-11-01T00:00:00Z')`, sess, b)
	require.NoError(t, err)
	// Same slug on both benches: B's becomes <folder>/<slug>.
	for _, row := range []struct {
		wb   int64
		path string
	}{{a, filepath.Join(aDir, ".watchtower", "automations", "daily.md")}, {b, filepath.Join(bDir, ".watchtower", "automations", "daily.md")}} {
		_, err = d.Exec(`INSERT INTO automations (slug, scope, project_id, path) VALUES ('daily', 'workbench', ?, ?)`, row.wb, row.path)
		require.NoError(t, err)
	}

	_, err = Merge(ctx, d, b, a, nil)
	require.NoError(t, err)

	_, err = d.GetWorkbench(b)
	require.ErrorIs(t, err, db.ErrWorkbenchNotFound, "B leaves the workbench list")
	var proj, folder sql.NullInt64
	require.NoError(t, d.QueryRow(`SELECT project_id, workbench_folder_id FROM terminal_sessions WHERE id = ?`, sess).Scan(&proj, &folder))
	assert.Equal(t, a, proj.Int64)
	assert.Equal(t, bHome.ID, folder.Int64, "a row read as B's home is pinned to that folder")
	assert.Equal(t, 2, countRows(t, d, `SELECT COUNT(*) FROM project_sources WHERE project_id = ?`, a), "sources deduplicated")
	assert.Zero(t, countRows(t, d, `SELECT COUNT(*) FROM workbench_folder_declines`), "B's declines are dropped")
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM permission_requests WHERE workbench_id = ?`, a))
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM automations WHERE project_id = ? AND slug = 'tools/daily'`, a))
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM automations WHERE project_id = ? AND slug = 'daily'`, a))
	f, err := d.WorkbenchFolderByID(ctx, bHome.ID)
	require.NoError(t, err)
	assert.Equal(t, a, f.WorkbenchID)
	assert.Equal(t, 1, f.Position, "after A's folders")
}

func TestMergeRenamesAClashingFolder(t *testing.T) {
	ctx := context.Background()
	d := testDB(t)
	a := bench(t, d, "acme", dir(t, "code", "app"))
	otherApp := dir(t, "other", "app")
	b := bench(t, d, "tools", otherApp)

	rep, err := Merge(ctx, d, b, a, nil)
	require.NoError(t, err)
	require.Len(t, rep.MovedFolders, 1)
	assert.Equal(t, "other-app", rep.MovedFolders[0].Name)

	mine, err := Resolve(ctx, d, a, "app")
	require.NoError(t, err)
	assert.NotEqual(t, otherApp, mine.FolderPath, "app is still A's own folder")
	moved, err := Resolve(ctx, d, a, "other-app")
	require.NoError(t, err)
	assert.Equal(t, otherApp, moved.FolderPath)
	byPath, err := Resolve(ctx, d, a, otherApp)
	require.NoError(t, err)
	assert.Equal(t, moved.ID, byPath.ID)
}

func TestMergeRefusedWhileBHasLiveSessions(t *testing.T) {
	ctx := context.Background()
	d := testDB(t)
	a := bench(t, d, "acme", dir(t, "acme"))
	b := bench(t, d, "tools", dir(t, "tools"))
	seedSession(t, d, homeOf(t, d, b))

	_, err := Merge(ctx, d, b, a, nil)
	r := refusal(t, err, CodeSessionsRunning)
	assert.Equal(t, "sessions_running: 1 session is running in tools. Finish it first.", r.Error())

	host := func(context.Context, int64) (int, error) { return 3, nil }
	_, err = Merge(ctx, d, b, a, host)
	r = refusal(t, err, CodeSessionsRunning)
	assert.Equal(t, "sessions_running: 3 sessions are running in tools. Finish them first.", r.Error())

	_, err = d.GetWorkbench(b)
	require.NoError(t, err, "nothing moved")
}

// Spec §7 "merge": a session of B starting between the dialog and the merge
// is re-checked inside the transaction.
func TestMergeRaceRecheckedInTheTransaction(t *testing.T) {
	ctx := context.Background()
	d := testDB(t)
	a := bench(t, d, "acme", dir(t, "acme"))
	b := bench(t, d, "tools", dir(t, "tools"))
	bHome := homeOf(t, d, b)
	// The host answered "none running"; a start lands right after.
	host := func(context.Context, int64) (int, error) {
		seedSession(t, d, bHome)
		return 0, nil
	}
	_, err := Merge(ctx, d, b, a, host)
	refusal(t, err, CodeSessionsRunning)
	_, err = d.GetWorkbench(b)
	require.NoError(t, err, "nothing moved")
	assert.Equal(t, b, homeOf(t, d, b).WorkbenchID)
}

// Spec §7 "crash mid-move": a failure on any table rolls the whole merge
// back.
func TestMergeIsAllOrNothing(t *testing.T) {
	ctx := context.Background()
	d := testDB(t)
	a := bench(t, d, "acme", dir(t, "acme"))
	b := bench(t, d, "tools", dir(t, "tools"))
	parent := insertTarget(t, d, b, "parent", "todo", 0, 0)
	insertTarget(t, d, b, "child", "done", parent, 0)
	insertColumn(t, d, b, "todo", "Later", 0)
	t.Cleanup(func() { mergeStepHook = nil })
	// The same bench is merged again and again, failing one table later
	// each time: every earlier table had moved when it fails.
	for _, failAt := range mergeTables {
		mergeStepHook = func(table string) error {
			if table == failAt.table {
				return errors.New("injected")
			}
			return nil
		}
		_, err := Merge(ctx, d, b, a, nil)
		require.ErrorContains(t, err, "injected", failAt.table)
		_, err = d.GetWorkbench(b)
		require.NoError(t, err, failAt.table)
		assert.Equal(t, 2, countRows(t, d, `SELECT COUNT(*) FROM targets WHERE project_id = ?`, b), failAt.table)
		assert.Equal(t, "done", readTarget(t, d, parent).status, failAt.table)
		assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM workbench_folders WHERE workbench_id = ?`, b), failAt.table)
		assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM workbench_board_columns WHERE project_id = ?`, b), failAt.table)
		assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger' AND name = ?`, rollupTrigger), failAt.table)
	}
}

func TestMergeReinstallsWorktreesOfMovedSessions(t *testing.T) {
	ctx := context.Background()
	d := testDB(t)
	a := bench(t, d, "acme", dir(t, "acme"))
	bDir := dir(t, "tools")
	b := bench(t, d, "tools", bDir)
	wt := filepath.Join(bDir, ".claude", "worktrees", "fix-login")
	require.NoError(t, os.MkdirAll(wt, 0o755))
	reported := dir(t, "elsewhere", "tools-wt")
	gone := filepath.Join(bDir, ".claude", "worktrees", "gone")

	sess := seedSession(t, d, homeOf(t, d, b))
	_, err := d.Exec(`UPDATE terminal_sessions SET folder_path = ?, finished_at = '2026-11-01T00:00:00.000Z' WHERE id = ?`, wt, sess)
	require.NoError(t, err)
	for _, root := range []string{reported, gone, bDir} {
		_, err = d.Exec(`INSERT INTO terminal_session_worktrees (session_id, root, first_at) VALUES (?, ?, '2026-11-01T00:00:00.000Z')`, sess, root)
		require.NoError(t, err)
	}

	rep, err := Merge(ctx, d, b, a, nil)
	require.NoError(t, err)
	require.NotEmpty(t, rep.Reinstall)
	assert.Equal(t, bDir, rep.Reinstall[0], "the moved folder first")
	assert.ElementsMatch(t, []string{bDir, wt, reported}, rep.Reinstall, "every still-existing worktree, once; a gone one skipped")
}

func TestMergeRefusesItself(t *testing.T) {
	d := testDB(t)
	a := bench(t, d, "acme", dir(t, "acme"))
	_, err := Merge(context.Background(), d, a, a, nil)
	refusal(t, err, CodeAlreadyHere)
}

func TestMergeOfAMissingBench(t *testing.T) {
	d := testDB(t)
	a := bench(t, d, "acme", dir(t, "acme"))
	_, err := Merge(context.Background(), d, a+100, a, nil)
	require.ErrorIs(t, err, db.ErrWorkbenchNotFound)
	_, err = Merge(context.Background(), d, a, a+100, nil)
	require.ErrorIs(t, err, db.ErrWorkbenchNotFound)
	_, err = d.GetWorkbench(a)
	require.NoError(t, err)
}
