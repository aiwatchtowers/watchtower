package db

import (
	"database/sql"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Migration 00103: closed workbench work older than the workbench's
// archive_after_days leaves the board, decided on every read by the
// workbench_target_archive view (PROJ-15, board #301): nothing is written, a
// group goes only whole, and reopening restores.

const oneDay = 24 * time.Hour

func isoAgo(age time.Duration) string {
	return time.Now().UTC().Add(-age).Format("2006-01-02T15:04:05Z")
}

// closedLeaf seeds a top-level target of workbench pid with status, closed age ago.
func closedLeaf(t *testing.T, d *DB, pid int64, status string, age time.Duration) int64 {
	t.Helper()
	id := SeedTestWorkbenchTarget(t, d, pid, sql.NullInt64{}, "leaf")
	setStatusRaw(t, d, id, status)
	BackdateTestWorkbenchClose(t, d, id, age)
	return id
}

// viewArchived returns the view's verdict for every target of workbench pid.
func viewArchived(t *testing.T, d *DB, pid int64) map[int64]bool {
	t.Helper()
	rows, err := d.Query(`SELECT target_id, archived FROM workbench_target_archive WHERE project_id = ?`, pid)
	require.NoError(t, err)
	defer rows.Close()
	out := map[int64]bool{}
	for rows.Next() {
		var id int64
		var archived bool
		require.NoError(t, rows.Scan(&id, &archived))
		out[id] = archived
	}
	require.NoError(t, rows.Err())
	return out
}

// boardArchived returns BoardNode.Archived for every node of GetWorkbenchBoard.
func boardArchived(t *testing.T, d *DB, pid int64) map[int64]bool {
	t.Helper()
	board, err := d.GetWorkbenchBoard(pid)
	require.NoError(t, err)
	out := map[int64]bool{}
	var walk func([]BoardNode)
	walk = func(nodes []BoardNode) {
		for _, n := range nodes {
			out[int64(n.Target.ID)] = n.Archived
			walk(n.Children)
		}
	}
	walk(board)
	return out
}

// requireArchived checks the view and the board agree on want for every id.
func requireArchived(t *testing.T, d *DB, pid int64, want map[int64]bool) {
	t.Helper()
	view, board := viewArchived(t, d, pid), boardArchived(t, d, pid)
	for id, w := range want {
		assert.Equal(t, w, view[id], "view: target %d archived", id)
		assert.Equal(t, w, board[id], "board: target %d archived", id)
	}
}

func TestProj15_ClosedLeafArchivedAfterNDays(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	want := map[int64]bool{}
	for _, status := range []string{"done", "dismissed"} {
		want[closedLeaf(t, d, pid, status, 14*oneDay+time.Minute)] = true
		want[closedLeaf(t, d, pid, status, 14*oneDay-time.Minute)] = false
	}
	requireArchived(t, d, pid, want)
}

func TestProj15_OpenStatusesAreNeverArchived(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	want := map[int64]bool{}
	for _, status := range []string{"todo", "in_progress", "in_review", "blocked", "snoozed"} {
		want[closedLeaf(t, d, pid, status, 90*oneDay)] = false
	}
	requireArchived(t, d, pid, want)
}

// One open grandchild keeps its whole chain on the board; the closed
// siblings of open work archive on their own, and the full board still
// carries them under their parent (the group's counter keeps counting).
func TestProj15_UmbrellaArchivedOnlyWhole(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	root := SeedTestWorkbenchTarget(t, d, pid, sql.NullInt64{}, "umbrella")
	closedChild := insertBoardChild(t, d, pid, root, "done")
	openChild := SeedTestWorkbenchTarget(t, d, pid, nullID(root), "group")
	openGrandchild := insertBoardChild(t, d, pid, openChild, "todo")
	closedGrandchild := insertBoardChild(t, d, pid, openChild, "dismissed")
	for _, id := range []int64{root, closedChild, openChild, openGrandchild, closedGrandchild} {
		BackdateTestWorkbenchClose(t, d, id, 30*oneDay)
	}

	requireArchived(t, d, pid, map[int64]bool{
		root: false, openChild: false, openGrandchild: false,
		closedChild: true, closedGrandchild: true,
	})
	board, err := d.GetWorkbenchBoard(pid)
	require.NoError(t, err)
	require.Len(t, board, 1)
	assert.Len(t, board[0].Children, 2, "the full board keeps archived children under their parent")
}

// The parent closed long ago, its last child only recently: the group waits
// for its last piece.
func TestProj15_GroupWaitsForItsLastClose(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	parent := SeedTestWorkbenchTarget(t, d, pid, sql.NullInt64{}, "group")
	child := SeedTestWorkbenchTarget(t, d, pid, nullID(parent), "piece")
	setStatusRaw(t, d, child, "done")
	require.Equal(t, "done", targetStatus(t, d, parent), "rollup closes the parent")

	BackdateTestWorkbenchClose(t, d, parent, 30*oneDay)
	BackdateTestWorkbenchClose(t, d, child, 2*oneDay)
	requireArchived(t, d, pid, map[int64]bool{parent: false, child: false})

	BackdateTestWorkbenchClose(t, d, child, 20*oneDay)
	requireArchived(t, d, pid, map[int64]bool{parent: true, child: true})
}

func TestProj15_HandSetDoneParentWithOpenChildIsNotArchived(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	parent := SeedTestWorkbenchTarget(t, d, pid, sql.NullInt64{}, "group")
	child := SeedTestWorkbenchTarget(t, d, pid, nullID(parent), "piece")
	setStatusRaw(t, d, parent, "done")
	require.Equal(t, "todo", targetStatus(t, d, child))
	BackdateTestWorkbenchClose(t, d, parent, 30*oneDay)
	BackdateTestWorkbenchClose(t, d, child, 30*oneDay)

	requireArchived(t, d, pid, map[int64]bool{parent: false, child: false})
}

// Reopening is the restore: an ordinary status write, recorded once with
// its writer's actor (PROJ-06).
func TestProj15_ReopenRestores(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	leaf := closedLeaf(t, d, pid, "done", 30*oneDay)
	requireArchived(t, d, pid, map[int64]bool{leaf: true})
	before := len(statusHistory(t, d, leaf))

	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		return d.UpdateTargetStatusAsTx(tx, int(leaf), "todo", ActorAgent)
	}))

	requireArchived(t, d, pid, map[int64]bool{leaf: false})
	rows := statusHistory(t, d, leaf)
	require.Len(t, rows, before+1)
	assert.Equal(t, [3]string{"done", "todo", "agent"}, transitions(rows)[before])
}

// Reopen then close again: the new close starts the archive period over, and
// only the newest close counts once it ages past it.
func TestProj15_ReopenAndRecloseStartsThePeriodOver(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	leaf := closedLeaf(t, d, pid, "done", 30*oneDay)
	requireArchived(t, d, pid, map[int64]bool{leaf: true})

	setStatusRaw(t, d, leaf, "todo")
	requireArchived(t, d, pid, map[int64]bool{leaf: false})
	setStatusRaw(t, d, leaf, "done")
	requireArchived(t, d, pid, map[int64]bool{leaf: false})

	// Reopened 20 days ago, closed again 5 days ago: the newest close decides.
	dateChange(t, d, leaf, 1, 20*oneDay)
	dateChange(t, d, leaf, 0, 5*oneDay)
	requireArchived(t, d, pid, map[int64]bool{leaf: false})
	dateChange(t, d, leaf, 0, 14*oneDay+time.Minute)
	requireArchived(t, d, pid, map[int64]bool{leaf: true})
}

// dateChange dates target id's status change nth from the newest (0 = the
// newest) age ago.
func dateChange(t *testing.T, d *DB, id int64, nth int, age time.Duration) {
	t.Helper()
	_, err := d.Exec(`UPDATE target_status_history SET changed_at = ? WHERE id =
		(SELECT id FROM target_status_history WHERE target_id = ? ORDER BY id DESC LIMIT 1 OFFSET ?)`, isoAgo(age), id, nth)
	require.NoError(t, err)
}

// archivedGroup seeds a group whose only child is done, both closed 30 days ago.
func archivedGroup(t *testing.T, d *DB, pid int64) (group, child int64) {
	t.Helper()
	group = SeedTestWorkbenchTarget(t, d, pid, sql.NullInt64{}, "group")
	child = insertBoardChild(t, d, pid, group, "done")
	BackdateTestWorkbenchClose(t, d, group, 30*oneDay)
	BackdateTestWorkbenchClose(t, d, child, 30*oneDay)
	requireArchived(t, d, pid, map[int64]bool{group: true, child: true})
	return group, child
}

func TestProj15_ReparentOpenWorkUnderArchivedGroupRestoresIt(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	group, child := archivedGroup(t, d, pid)
	open := SeedTestWorkbenchTarget(t, d, pid, sql.NullInt64{}, "open work")

	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		return d.MoveWorkbenchTargetTx(tx, pid, open, nullID(group))
	}))

	requireArchived(t, d, pid, map[int64]bool{group: false, open: false, child: true})
}

func TestProj15_OpenSubTargetUnderArchivedGroupRestoresIt(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	group, child := archivedGroup(t, d, pid)

	added := SeedTestWorkbenchTarget(t, d, pid, nullID(group), "follow-up")

	requireArchived(t, d, pid, map[int64]bool{group: false, added: false, child: true})
}

// targetsSnapshot renders every target's status columns and the history
// table, to compare across reads.
func targetsSnapshot(t *testing.T, d *DB) string {
	t.Helper()
	var b strings.Builder
	dumpRows(t, d, &b, `SELECT id, status, updated_at, COALESCE(status_actor, '') FROM targets ORDER BY id`)
	dumpRows(t, d, &b, `SELECT id, target_id, to_status, changed_at, actor FROM target_status_history ORDER BY id`)
	return b.String()
}

func dumpRows(t *testing.T, d *DB, b *strings.Builder, q string) {
	t.Helper()
	rows, err := d.Query(q)
	require.NoError(t, err)
	defer rows.Close()
	cols, err := rows.Columns()
	require.NoError(t, err)
	vals := make([]any, len(cols))
	ptrs := make([]any, len(cols))
	for i := range vals {
		ptrs[i] = &vals[i]
	}
	for rows.Next() {
		require.NoError(t, rows.Scan(ptrs...))
		fmt.Fprintln(b, vals...)
	}
	require.NoError(t, rows.Err())
}

func TestProj15_ArchiveWritesNothing(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	archivedGroup(t, d, pid)
	closedLeaf(t, d, pid, "dismissed", 30*oneDay)
	SeedTestWorkbenchTarget(t, d, pid, sql.NullInt64{}, "open")
	before := targetsSnapshot(t, d)
	var changesBefore int
	require.NoError(t, d.QueryRow(`SELECT total_changes()`).Scan(&changesBefore))

	_, err := d.GetWorkbenchBoard(pid)
	require.NoError(t, err)
	_, err = d.GetTargets(TargetFilter{WorkbenchID: pid, IncludeDone: true})
	require.NoError(t, err)
	viewArchived(t, d, pid)

	var changesAfter int
	require.NoError(t, d.QueryRow(`SELECT total_changes()`).Scan(&changesAfter))
	assert.Equal(t, changesBefore, changesAfter, "board reads write no row")
	assert.Equal(t, before, targetsSnapshot(t, d))
}

func TestProj15_PerWorkbenchSettingAndNever(t *testing.T) {
	d := openTestDB(t)
	short, long := newTestWorkbench(t, d), newTestWorkbench(t, d)
	require.NoError(t, d.SetWorkbenchArchiveDays(short, 3))
	require.NoError(t, d.SetWorkbenchArchiveDays(long, 30))
	onShort := closedLeaf(t, d, short, "done", 10*oneDay)
	onLong := closedLeaf(t, d, long, "done", 10*oneDay)

	requireArchived(t, d, short, map[int64]bool{onShort: true})
	requireArchived(t, d, long, map[int64]bool{onLong: false})

	require.NoError(t, d.SetWorkbenchArchiveDays(short, 0))
	requireArchived(t, d, short, map[int64]bool{onShort: false})
	require.NoError(t, d.SetWorkbenchArchiveDays(long, 7))
	requireArchived(t, d, long, map[int64]bool{onLong: true})

	w, err := d.GetWorkbench(long)
	require.NoError(t, err)
	assert.Equal(t, 7, w.ArchiveAfterDays)
}

func TestProj15_ArchiveDaysOutOfRangeAreRefused(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	for _, days := range []int{-1, 366} {
		err := d.SetWorkbenchArchiveDays(pid, days)
		require.Error(t, err, "days %d", days)
		assert.Contains(t, err.Error(), "CHECK constraint failed")
		_, err = d.Exec(`UPDATE projects SET archive_after_days = ? WHERE id = ?`, days, pid)
		assert.Error(t, err, "raw write of %d", days)
	}
	require.NoError(t, d.SetWorkbenchArchiveDays(pid, 365))
	w, err := d.GetWorkbench(pid)
	require.NoError(t, err)
	assert.Equal(t, 365, w.ArchiveAfterDays)

	assert.ErrorIs(t, d.SetWorkbenchArchiveDays(pid+100, 7), ErrWorkbenchNotFound)
}

// A target with no status history is dated by its updated_at; with history,
// the history wins.
func TestProj15_CloseTimeFallsBackToUpdatedAt(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	leaf := closedLeaf(t, d, pid, "done", 2*oneDay)
	_, err := d.Exec(`UPDATE targets SET updated_at = ? WHERE id = ?`, isoAgo(30*oneDay), leaf)
	require.NoError(t, err)
	requireArchived(t, d, pid, map[int64]bool{leaf: false})

	_, err = d.Exec(`DELETE FROM target_status_history WHERE target_id = ?`, leaf)
	require.NoError(t, err)
	requireArchived(t, d, pid, map[int64]bool{leaf: true})

	_, err = d.Exec(`UPDATE targets SET updated_at = ? WHERE id = ?`, isoAgo(2*oneDay), leaf)
	require.NoError(t, err)
	requireArchived(t, d, pid, map[int64]bool{leaf: false})
}

// A close time that does not parse keeps the target and every ancestor on
// the board: an archived node's whole subtree is always archived.
func TestProj15_UnparseableCloseTimeKeepsTheChain(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	parent, child := archivedGroup(t, d, pid)

	_, err := d.Exec(`DELETE FROM target_status_history WHERE target_id = ?`, child)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE targets SET updated_at = '' WHERE id = ?`, child)
	require.NoError(t, err)

	requireArchived(t, d, pid, map[int64]bool{parent: false, child: false})
}

func archNode(id int, archived bool, children ...BoardNode) BoardNode {
	return BoardNode{Target: Target{ID: id}, Archived: archived, Children: children}
}

func TestWithoutArchived_CountsArchivedChildren(t *testing.T) {
	board := []BoardNode{
		archNode(1, false,
			archNode(2, true, archNode(3, true)),
			archNode(4, false, archNode(5, true), archNode(6, false)),
		),
		archNode(7, true),
	}

	got := WithoutArchived(board)

	require.Len(t, got, 1)
	assert.Equal(t, 1, got[0].Target.ID)
	assert.Equal(t, 1, got[0].ArchivedChildren)
	require.Len(t, got[0].Children, 1)
	kept := got[0].Children[0]
	assert.Equal(t, 4, kept.Target.ID)
	assert.Equal(t, 1, kept.ArchivedChildren)
	require.Len(t, kept.Children, 1)
	assert.Equal(t, 6, kept.Children[0].Target.ID)
	assert.Zero(t, kept.Children[0].ArchivedChildren)

	assert.Len(t, board[0].Children, 2, "the input board is not changed")
	assert.Len(t, board[0].Children[1].Children, 2)
	assert.Zero(t, board[0].ArchivedChildren)
}

func TestWithoutArchived_EmptyAndAllArchived(t *testing.T) {
	assert.Empty(t, WithoutArchived(nil))
	assert.Empty(t, WithoutArchived([]BoardNode{archNode(1, true, archNode(2, true)), archNode(3, true)}))
}

// A workbench list query leaves archived targets out, an explicit status
// included, unless IncludeArchived; outside a workbench nothing changes.
func TestGetTargets_WorkbenchLeavesArchivedOut(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	archived := closedLeaf(t, d, pid, "done", 30*oneDay)
	recent := closedLeaf(t, d, pid, "done", 2*oneDay)
	personal, err := d.CreateTarget(Target{Text: "personal", Status: "done", Priority: "medium", Ownership: "mine", SourceType: "manual"})
	require.NoError(t, err)

	ids := func(f TargetFilter) []int64 {
		got, err := d.GetTargets(f)
		require.NoError(t, err)
		out := []int64{}
		for _, tg := range got {
			out = append(out, int64(tg.ID))
		}
		return out
	}
	assert.ElementsMatch(t, []int64{recent}, ids(TargetFilter{WorkbenchID: pid, IncludeDone: true}))
	assert.ElementsMatch(t, []int64{recent}, ids(TargetFilter{WorkbenchID: pid, Status: "done"}))
	assert.ElementsMatch(t, []int64{archived, recent},
		ids(TargetFilter{WorkbenchID: pid, Status: "done", IncludeArchived: true}))
	assert.ElementsMatch(t, []int64{personal}, ids(TargetFilter{IncludeDone: true}))
}

func TestMigration00103_DefaultsToFourteen(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "board-archive.db"))
	require.NoError(t, err)
	defer d.Close()
	pid := newTestWorkbench(t, d)
	leaf := closedLeaf(t, d, pid, "done", 30*oneDay)

	// DownTo(102), not a bare Down: a later migration can move the tip past 00103.
	require.NoError(t, goose.DownTo(d.DB, "migrations", 102))
	assert.False(t, columnNames(t, d.DB, "projects")["archive_after_days"], "Down kept the column")
	assert.Zero(t, countRows(t, d, `SELECT COUNT(*) FROM sqlite_master WHERE name = 'workbench_target_archive'`))
	assert.Equal(t, 1, countRows(t, d, `SELECT COUNT(*) FROM targets WHERE id = ?`, leaf))

	require.NoError(t, goose.Up(d.DB, "migrations"))
	w, err := d.GetWorkbench(pid)
	require.NoError(t, err)
	assert.Equal(t, 14, w.ArchiveAfterDays, "an existing workbench gets the default")
	requireArchived(t, d, pid, map[int64]bool{leaf: true})
}

// seedLargeBoard plants roots × children × grandchildren targets on
// workbench pid in one transaction: every grandchild done except one in
// each group of the first quarter of the roots, so the board mixes
// archived and open subtrees. Every close is dated 30 days ago.
func seedLargeBoard(t *testing.T, d *DB, pid int64, roots, children, grandchildren int) int {
	t.Helper()
	n := 0
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		insert := func(parent sql.NullInt64, status string) int64 {
			res, err := tx.Exec(`INSERT INTO targets (text, level, custom_label, period_start, period_end,
					source_type, project_id, parent_id, status)
				VALUES ('t', 'custom', 'project', '2026-09-29', '2026-09-29', 'chat', ?, ?, ?)`, pid, parent, status)
			require.NoError(t, err)
			id, err := res.LastInsertId()
			require.NoError(t, err)
			n++
			return id
		}
		for r := range roots {
			root := insert(sql.NullInt64{}, "todo")
			for range children {
				child := insert(nullID(root), "todo")
				for g := range grandchildren {
					status := "done"
					if r < roots/4 && g == 0 {
						status = "todo"
					}
					insert(nullID(child), status)
				}
			}
		}
		return nil
	}))
	at := isoAgo(30 * oneDay)
	_, err := d.Exec(`UPDATE target_status_history SET changed_at = ?`, at)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE targets SET updated_at = ?`, at)
	require.NoError(t, err)
	return n
}

// The view runs on every board read: a 2000-target board must stay cheap.
// Measured ~30 ms locally (the view alone ~12 ms with a second 2000-target
// workbench in the database). The bound is far above that, so a loaded
// machine passes, yet still trips on a read that walks the board
// quadratically; the race detector scales it.
const largeBoardReadBound = 3 * time.Second * raceSlowdown

func TestProj15_LargeBoardReadIsFast(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	require.Equal(t, 2000, seedLargeBoard(t, d, pid, 40, 7, 6))

	start := time.Now()
	board, err := d.GetWorkbenchBoard(pid)
	elapsed := time.Since(start)
	require.NoError(t, err)

	t.Logf("2000-target board read: %s", elapsed)
	assert.Len(t, board, 40)
	// 30 roots × (1 + 7 + 42) archived; the other 10 roots × 7 × 5 closed grandchildren.
	assert.Equal(t, 30*50+10*7*5, CountArchived(board))
	assert.Less(t, elapsed, largeBoardReadBound, "2000-target board read")
}
