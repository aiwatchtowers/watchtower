package db

import (
	"database/sql"
	"path/filepath"
	"regexp"
	"testing"
	"time"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Migration 00105: "Archive Closed Targets Now" (board #415, PROJ-15
// amended). projects.archived_through remembers one moment per workbench;
// the view archives every closed subtree whose newest close time is not
// after it, whatever archive_after_days says. Nothing is written per target.

// archiveNow stamps workbench pid and returns the stamp.
func archiveNow(t *testing.T, d *DB, pid int64) time.Time {
	t.Helper()
	require.NoError(t, d.ArchiveWorkbenchClosedNow(pid))
	w, err := d.GetWorkbench(pid)
	require.NoError(t, err)
	stamp, err := time.Parse(time.RFC3339, w.ArchivedThrough)
	require.NoError(t, err, "archived_through %q", w.ArchivedThrough)
	return stamp
}

func isoAt(at time.Time) string { return at.UTC().Format("2006-01-02T15:04:05Z") }

// dateNewestChange dates target id's newest status change at.
func dateNewestChange(t *testing.T, d *DB, id int64, at time.Time) {
	t.Helper()
	_, err := d.Exec(`UPDATE target_status_history SET changed_at = ? WHERE id =
		(SELECT id FROM target_status_history WHERE target_id = ? ORDER BY id DESC LIMIT 1)`, isoAt(at), id)
	require.NoError(t, err)
}

// closedGroup seeds a group whose only child is done, both closed age ago.
func closedGroup(t *testing.T, d *DB, pid int64, age time.Duration) (group, child int64) {
	t.Helper()
	group = SeedTestWorkbenchTarget(t, d, pid, sql.NullInt64{}, "group")
	child = insertBoardChild(t, d, pid, group, "done")
	BackdateTestWorkbenchClose(t, d, group, age)
	BackdateTestWorkbenchClose(t, d, child, age)
	return group, child
}

func TestProj15_ArchiveNowArchivesEveryClosedSubtree(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	want := map[int64]bool{}
	for _, status := range []string{"done", "dismissed"} {
		want[closedLeaf(t, d, pid, status, 5*time.Minute)] = true
	}
	for _, status := range []string{"todo", "in_progress", "in_review", "blocked", "snoozed"} {
		want[closedLeaf(t, d, pid, status, 5*time.Minute)] = false
	}
	notYet := map[int64]bool{}
	for id := range want {
		notYet[id] = false
	}
	requireArchived(t, d, pid, notYet)

	archiveNow(t, d, pid)

	requireArchived(t, d, pid, want)
	w, err := d.GetWorkbench(pid)
	require.NoError(t, err)
	assert.Equal(t, 14, w.ArchiveAfterDays, "the setting is not touched")
}

// Groups go whole for the stamp too: one open grandchild keeps its chain;
// its closed siblings archive alone; a fully closed group archives whole.
func TestProj15_ArchiveNowGroupsGoWhole(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	root := SeedTestWorkbenchTarget(t, d, pid, sql.NullInt64{}, "umbrella")
	closedChild := insertBoardChild(t, d, pid, root, "done")
	openChild := SeedTestWorkbenchTarget(t, d, pid, nullID(root), "group")
	openGrandchild := insertBoardChild(t, d, pid, openChild, "todo")
	closedGrandchild := insertBoardChild(t, d, pid, openChild, "dismissed")
	for _, id := range []int64{root, closedChild, openChild, openGrandchild, closedGrandchild} {
		BackdateTestWorkbenchClose(t, d, id, time.Hour)
	}
	group, child := closedGroup(t, d, pid, time.Hour)

	archiveNow(t, d, pid)

	requireArchived(t, d, pid, map[int64]bool{
		root: false, openChild: false, openGrandchild: false,
		closedChild: true, closedGrandchild: true,
		group: true, child: true,
	})
	board, err := d.GetWorkbenchBoard(pid)
	require.NoError(t, err)
	require.Len(t, board, 2)
	assert.Len(t, board[0].Children, 2, "the full board keeps archived children under their parent")
}

// Work closed after the click stays until the age rule (or the next click)
// takes it.
func TestProj15_ArchiveNowCloseAfterTheStampStays(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	before := closedLeaf(t, d, pid, "done", time.Hour)
	stamp := archiveNow(t, d, pid)
	after := closedLeaf(t, d, pid, "done", 0)
	dateNewestChange(t, d, after, stamp.Add(time.Second))

	requireArchived(t, d, pid, map[int64]bool{before: true, after: false})

	BackdateTestWorkbenchClose(t, d, after, 14*oneDay+time.Minute)
	requireArchived(t, d, pid, map[int64]bool{before: true, after: true})
}

// A group the stamp archived whose child is reopened and closed again after
// it is back whole.
func TestProj15_ArchiveNowLaterCloseInAGroupKeepsTheGroup(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	group, child := closedGroup(t, d, pid, time.Hour)
	stamp := archiveNow(t, d, pid)
	requireArchived(t, d, pid, map[int64]bool{group: true, child: true})

	setStatusRaw(t, d, child, "todo")
	setStatusRaw(t, d, child, "done")
	require.Equal(t, "done", targetStatus(t, d, group), "rollup closes the group again")
	dateNewestChange(t, d, child, stamp.Add(time.Second))

	requireArchived(t, d, pid, map[int64]bool{group: false, child: false})
}

// Reopening after the click restores, as an ordinary status write recorded
// once with its writer's actor (PROJ-06).
func TestProj15_ArchiveNowReopenRestores(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	leaf := closedLeaf(t, d, pid, "done", time.Hour)
	archiveNow(t, d, pid)
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

// A close in the stamp's own second is archived (<=); one second later is not.
func TestProj15_ArchiveNowSameSecondIsArchived(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	same := closedLeaf(t, d, pid, "done", 0)
	later := closedLeaf(t, d, pid, "done", 0)
	stamp := archiveNow(t, d, pid)
	for id, at := range map[int64]time.Time{same: stamp, later: stamp.Add(time.Second)} {
		dateNewestChange(t, d, id, at)
	}

	requireArchived(t, d, pid, map[int64]bool{same: true, later: false})
}

// Decision 1: "Never" means never by itself; the click still archives.
func TestProj15_ArchiveNowUnderNever(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	require.NoError(t, d.SetWorkbenchArchiveDays(pid, 0))
	recent := closedLeaf(t, d, pid, "done", time.Hour)
	old := closedLeaf(t, d, pid, "dismissed", 90*oneDay)
	open := closedLeaf(t, d, pid, "todo", 90*oneDay)
	requireArchived(t, d, pid, map[int64]bool{recent: false, old: false, open: false})

	archiveNow(t, d, pid)

	requireArchived(t, d, pid, map[int64]bool{recent: true, old: true, open: false})
}

// A close time that does not parse keeps the target and every ancestor on
// the board with the stamp set, as under the age rule.
func TestProj15_ArchiveNowUnparseableCloseTimeKeepsTheChain(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	group, child := closedGroup(t, d, pid, time.Hour)
	_, err := d.Exec(`DELETE FROM target_status_history WHERE target_id = ?`, child)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE targets SET updated_at = 'garbage' WHERE id = ?`, child)
	require.NoError(t, err)

	archiveNow(t, d, pid)

	requireArchived(t, d, pid, map[int64]bool{group: false, child: false})
}

func TestProj15_ArchivedThroughMustParse(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	_, err := d.Exec(`UPDATE projects SET archived_through = 'not a date' WHERE id = ?`, pid)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "CHECK constraint failed")

	require.NoError(t, d.ArchiveWorkbenchClosedNow(pid))
	w, err := d.GetWorkbench(pid)
	require.NoError(t, err)
	assert.Regexp(t, regexp.MustCompile(`^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$`), w.ArchivedThrough,
		"UTC, second precision, the target_status_history.changed_at format")
}

// Undo forgets the moment: what only the stamp archived is back; what the
// age rule archives stays archived.
func TestProj15_UndoArchiveNowRestoresOnlyWhatTheAgeRuleWouldNot(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	recent := closedLeaf(t, d, pid, "done", time.Hour)
	old := closedLeaf(t, d, pid, "done", 30*oneDay)
	archiveNow(t, d, pid)
	requireArchived(t, d, pid, map[int64]bool{recent: true, old: true})

	require.NoError(t, d.ClearWorkbenchArchivedThrough(pid))

	requireArchived(t, d, pid, map[int64]bool{recent: false, old: true})
	w, err := d.GetWorkbench(pid)
	require.NoError(t, err)
	assert.Empty(t, w.ArchivedThrough)
	var isNull bool
	require.NoError(t, d.QueryRow(`SELECT archived_through IS NULL FROM projects WHERE id = ?`, pid).Scan(&isNull))
	assert.True(t, isNull, "undo stores NULL, not an empty string")
}

func TestProj15_ArchiveNowWritesNothingPerTarget(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	closedGroup(t, d, pid, time.Hour)
	closedLeaf(t, d, pid, "dismissed", time.Hour)
	SeedTestWorkbenchTarget(t, d, pid, sql.NullInt64{}, "open")
	before := targetsSnapshot(t, d)

	archiveNow(t, d, pid)
	_, err := d.GetWorkbenchBoard(pid)
	require.NoError(t, err)
	_, err = d.GetTargets(TargetFilter{WorkbenchID: pid, IncludeDone: true})
	require.NoError(t, err)
	viewArchived(t, d, pid)
	require.NoError(t, d.ClearWorkbenchArchivedThrough(pid))

	assert.Equal(t, before, targetsSnapshot(t, d))
}

func TestProj15_ArchiveNowIsPerWorkbench(t *testing.T) {
	d := openTestDB(t)
	stamped, other := newTestWorkbench(t, d), newTestWorkbench(t, d)
	onStamped := closedLeaf(t, d, stamped, "done", time.Hour)
	onOther := closedLeaf(t, d, other, "done", time.Hour)

	archiveNow(t, d, stamped)

	requireArchived(t, d, stamped, map[int64]bool{onStamped: true})
	requireArchived(t, d, other, map[int64]bool{onOther: false})
	w, err := d.GetWorkbench(other)
	require.NoError(t, err)
	assert.Empty(t, w.ArchivedThrough)
}

func TestArchiveNowWriters_UnknownWorkbench(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	assert.ErrorIs(t, d.ArchiveWorkbenchClosedNow(pid+100), ErrWorkbenchNotFound)
	assert.ErrorIs(t, d.ClearWorkbenchArchivedThrough(pid+100), ErrWorkbenchNotFound)
	require.NoError(t, d.ClearWorkbenchArchivedThrough(pid), "clearing an unset stamp is fine")
}

func TestMigration00105_ArchivedThroughStartsNull(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "archive-now.db"))
	require.NoError(t, err)
	defer d.Close()
	pid := newTestWorkbench(t, d)
	recent := closedLeaf(t, d, pid, "done", time.Hour)
	old := closedLeaf(t, d, pid, "done", 30*oneDay)
	require.NoError(t, d.ArchiveWorkbenchClosedNow(pid))

	// DownTo(104), not a bare Down: a later migration can move the tip past 00105.
	require.NoError(t, goose.DownTo(d.DB, "migrations", 104))
	assert.False(t, columnNames(t, d.DB, "projects")["archived_through"], "Down kept the column")
	requireArchived(t, d, pid, map[int64]bool{recent: false, old: true})

	require.NoError(t, goose.Up(d.DB, "migrations"))
	w, err := d.GetWorkbench(pid)
	require.NoError(t, err)
	assert.Empty(t, w.ArchivedThrough, "an existing workbench starts with no stamp")
	requireArchived(t, d, pid, map[int64]bool{recent: false, old: true})
}

// The stamp branch keeps the large-board read cheap: archive_after_days = 0,
// so only the stamp archives.
func TestProj15_LargeBoardReadIsFastWithAStamp(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	require.Equal(t, 2000, seedLargeBoard(t, d, pid, 40, 7, 6))
	require.NoError(t, d.SetWorkbenchArchiveDays(pid, 0))
	require.NoError(t, d.ArchiveWorkbenchClosedNow(pid))

	start := time.Now()
	board, err := d.GetWorkbenchBoard(pid)
	elapsed := time.Since(start)
	require.NoError(t, err)

	t.Logf("2000-target board read with a stamp: %s", elapsed)
	assert.Equal(t, 30*50+10*7*5, CountArchived(board))
	assert.Less(t, elapsed, largeBoardReadBound, "2000-target board read")
}
