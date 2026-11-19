package db

import (
	"database/sql"
	"errors"
	"path/filepath"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// The owner's target status writers behind the tower's targets.* commands
// (target_owner_writes.go): PROJ-05's rollup reported, PROJ-06's owner
// actor, PROJ-19's one-statement move. Go twins of the Swift
// WorkbenchBoardColumnWritesTests and WorkbenchBoardViewModelTests guards,
// beside them (docs/inventory/workbench.md).

func ownerStatus(t *testing.T, d *DB, id int64, status string) []int64 {
	t.Helper()
	var rolled []int64
	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		var err error
		rolled, err = SetTargetStatusOwnerTx(tx, id, status)
		return err
	}))
	return rolled
}

func ownerColumn(d *DB, id int64, status string, col *int64) ([]int64, error) {
	var rolled []int64
	err := d.WithTx(func(tx *sql.Tx) error {
		var err error
		rolled, err = SetTargetColumnOwnerTx(tx, id, status, col)
		return err
	})
	return rolled, err
}

// TestProj05_OwnerStatusCommandReturnsTheRolledUpAncestors: a leaf closed
// by the owner closes its parent and grandparent through the rollup; the
// writer returns both, sorted, and the history records the leaf as the
// owner's and the parents as the system's.
func TestProj05_OwnerStatusCommandReturnsTheRolledUpAncestors(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	root := SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "root")
	mid := SeedTestWorkbenchTarget(t, d, wb, nullID(root), "mid")
	leaf := SeedTestWorkbenchTarget(t, d, wb, nullID(mid), "leaf")

	rolled := ownerStatus(t, d, leaf, "done")

	assert.Equal(t, []int64{root, mid}, rolled)
	assert.Equal(t, "done", targetStatus(t, d, mid))
	assert.Equal(t, "done", targetStatus(t, d, root))
	last := func(id int64) historyRow { h := statusHistory(t, d, id); return h[len(h)-1] }
	assert.Equal(t, ActorOwner, last(leaf).actor)
	assert.Equal(t, ActorSystem, last(mid).actor)
	assert.Equal(t, ActorSystem, last(root).actor)

	// A write that moves no parent returns none.
	assert.Empty(t, ownerStatus(t, d, leaf, "done"))
}

// TestProj05_DismissedAncestorStopsTheRollupAndIsNotReturned: a dismissed
// parent is never re-derived, so it is not returned, and nothing above it
// moves.
func TestProj05_DismissedAncestorStopsTheRollupAndIsNotReturned(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	root := SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "root")
	mid := SeedTestWorkbenchTarget(t, d, wb, nullID(root), "mid")
	leaf := SeedTestWorkbenchTarget(t, d, wb, nullID(mid), "leaf")
	setStatusRaw(t, d, mid, "dismissed")
	rootBefore := targetStatus(t, d, root)

	rolled := ownerStatus(t, d, leaf, "in_progress")

	assert.Empty(t, rolled)
	assert.Equal(t, "dismissed", targetStatus(t, d, mid))
	assert.Equal(t, rootBefore, targetStatus(t, d, root))
}

// TestProj06_OwnerStatusCommandRecordsActorOwner: one history row per
// status change, actor owner, and no claim left behind; a write that does
// not change the status adds none.
func TestProj06_OwnerStatusCommandRecordsActorOwner(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	id := SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "task")
	before := len(statusHistory(t, d, id))

	ownerStatus(t, d, id, "in_review")
	ownerStatus(t, d, id, "in_review")

	h := statusHistory(t, d, id)
	require.Len(t, h, before+1)
	assert.Equal(t, "in_review", h[len(h)-1].to)
	assert.Equal(t, ActorOwner, h[len(h)-1].actor)
	assert.False(t, statusActor(t, d, id).Valid, "the claim never outlives its write")
}

// TestProj06_SnoozeRecordsActorOwner: the owner's snooze is recorded as the
// owner's, with its date and the leaf's progress.
func TestProj06_SnoozeRecordsActorOwner(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	id := SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "task")

	require.NoError(t, d.WithTx(func(tx *sql.Tx) error {
		_, err := SnoozeTargetOwnerTx(tx, id, "2026-11-20")
		return err
	}))

	h := statusHistory(t, d, id)
	assert.Equal(t, "snoozed", h[len(h)-1].to)
	assert.Equal(t, ActorOwner, h[len(h)-1].actor)
	var until string
	require.NoError(t, d.QueryRow(`SELECT snooze_until FROM targets WHERE id = ?`, id).Scan(&until))
	assert.Equal(t, "2026-11-20", until)
	assert.False(t, statusActor(t, d, id).Valid)
}

// The four PROJ-19 guards of the Swift WorkbenchBoardColumnWritesTests,
// over the Go owner writer, with the same names and assertions.

func TestProj19_MoveToColumnWritesStatusAndColumnOnce(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	code := columnID(t, replaceColumns(t, d, wb, BoardColumn{Status: "in_progress", Title: "Code"}), "Code")
	target := SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "task")
	before := len(statusHistory(t, d, target))

	rolled, err := ownerColumn(d, target, "in_progress", &code)

	require.NoError(t, err)
	assert.Empty(t, rolled)
	assert.Equal(t, "in_progress", targetStatus(t, d, target))
	assert.Equal(t, nullID(code), targetColumn(t, d, target))
	h := statusHistory(t, d, target)
	require.Len(t, h, before+1, "one status change, one history row")
	assert.Equal(t, "in_progress", h[len(h)-1].to)
	assert.Equal(t, ActorOwner, h[len(h)-1].actor, "PROJ-06: the owner's move")
}

func TestProj19_MoveBetweenColumnsOfOneStatusWritesNoHistory(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	cols := replaceColumns(t, d, wb,
		BoardColumn{Status: "in_progress", Title: "Spec"},
		BoardColumn{Status: "in_progress", Title: "Code"})
	spec, code := columnID(t, cols, "Spec"), columnID(t, cols, "Code")
	target := SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "task")
	setStatusRaw(t, d, target, "in_progress")
	_, err := ownerColumn(d, target, "in_progress", &spec)
	require.NoError(t, err)
	before := len(statusHistory(t, d, target))

	_, err = ownerColumn(d, target, "in_progress", &code)
	require.NoError(t, err)
	assert.Equal(t, nullID(code), targetColumn(t, d, target))
	_, err = ownerColumn(d, target, "in_progress", nil)
	require.NoError(t, err)
	assert.False(t, targetColumn(t, d, target).Valid, "nil = the status's first column")

	assert.Len(t, statusHistory(t, d, target), before, "PROJ-06: a column move is not a status change")
}

// A move between two columns of one status is not a status write: the
// progress the agent set, the status and its claim stay as they were.
func TestProj19_MoveWithinOneStatusKeepsProgress(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	cols := replaceColumns(t, d, wb,
		BoardColumn{Status: "in_progress", Title: "Spec"},
		BoardColumn{Status: "in_progress", Title: "Code"})
	spec, code := columnID(t, cols, "Spec"), columnID(t, cols, "Code")
	target := SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "task")
	setStatusRaw(t, d, target, "in_progress")
	_, err := d.Exec(`UPDATE targets SET progress = 0.7, board_column_id = ?, updated_at = '2026-10-01T00:00:00Z' WHERE id = ?`,
		spec, target)
	require.NoError(t, err)

	_, err = ownerColumn(d, target, "in_progress", &code)
	require.NoError(t, err)

	var status, updatedAt string
	var progress float64
	var actor sql.NullString
	var col sql.NullInt64
	require.NoError(t, d.QueryRow(`SELECT status, progress, status_actor, board_column_id, updated_at FROM targets WHERE id = ?`,
		target).Scan(&status, &progress, &actor, &col, &updatedAt))
	assert.Equal(t, nullID(code), col)
	assert.Equal(t, "in_progress", status)
	assert.InDelta(t, 0.7, progress, 1e-9, "a column move keeps the progress")
	assert.False(t, actor.Valid, "no status claim left behind")
	assert.NotEqual(t, "2026-10-01T00:00:00Z", updatedAt, "the board's poll sees the move")

	_, err = ownerColumn(d, target, "done", nil)
	require.NoError(t, err)
	require.NoError(t, d.QueryRow(`SELECT progress FROM targets WHERE id = ?`, target).Scan(&progress))
	assert.InDelta(t, 1.0, progress, 1e-9, "a status change still sets the status's progress")
}

func TestProj19_MismatchedColumnIsRefusedByTheTrigger(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	other := newTestWorkbench(t, d)
	code := columnID(t, replaceColumns(t, d, wb, BoardColumn{Status: "in_progress", Title: "Code"}), "Code")
	foreign := columnID(t, replaceColumns(t, d, other, BoardColumn{Status: "todo", Title: "Ready"}), "Ready")
	target := SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "task")

	for _, col := range []int64{code, foreign} {
		_, err := ownerColumn(d, target, "todo", &col)
		require.Error(t, err)
		assert.ErrorIs(t, err, ErrColumnMismatch)
		assert.Contains(t, err.Error(), "board column does not match the target")
	}
	assert.Equal(t, "todo", targetStatus(t, d, target))
	assert.False(t, targetColumn(t, d, target).Valid)
}

// TestOwnerTargetWriters_MissingTargetIsNotFound: Swift's requireUpdated
// (TargetNotFoundError) for each writer.
func TestOwnerTargetWriters_MissingTargetIsNotFound(t *testing.T) {
	d := openTestDB(t)
	for name, w := range map[string]func(*sql.Tx) error{
		"status": func(tx *sql.Tx) error { _, err := SetTargetStatusOwnerTx(tx, 999, "done"); return err },
		"column": func(tx *sql.Tx) error { _, err := SetTargetColumnOwnerTx(tx, 999, "done", nil); return err },
		"snooze": func(tx *sql.Tx) error { _, err := SnoozeTargetOwnerTx(tx, 999, "2026-11-20"); return err },
	} {
		assert.ErrorIs(t, d.WithTx(w), ErrRowNotFound, name)
	}
}

// TestTargetsSetStatus_TwoConnectionsRace: two handles on one file (two
// processes, as far as SQLite is concerned) set different statuses on one
// target at once. Both succeed; the row holds exactly one of the two, with
// that status's own follow-ups (progress, INBOX-02's target_due cascade)
// and never a mix.
func TestTargetsSetStatus_TwoConnectionsRace(t *testing.T) {
	path := filepath.Join(t.TempDir(), "watchtower.db")
	d, err := Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	other, err := Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { _ = other.Close() })

	wb := newTestWorkbench(t, d)
	target := SeedTestWorkbenchTarget(t, d, wb, sql.NullInt64{}, "task")
	_, err = d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, sender_user_id, trigger_type, target_id, status)
		VALUES ('', '', '', 'target_due', ?, 'pending')`, target)
	require.NoError(t, err)

	statuses := []string{"done", "in_progress"}
	errs := make([]error, 2)
	var wg sync.WaitGroup
	for i, h := range []*DB{d, other} {
		wg.Go(func() {
			errs[i] = h.WithTx(func(tx *sql.Tx) error {
				_, err := SetTargetStatusOwnerTx(tx, target, statuses[i])
				return err
			})
		})
	}
	wg.Wait()
	require.NoError(t, errors.Join(errs...))

	var status, itemStatus string
	var progress float64
	require.NoError(t, d.QueryRow(`SELECT status, progress FROM targets WHERE id = ?`, target).Scan(&status, &progress))
	require.NoError(t, d.QueryRow(`SELECT status FROM inbox_items WHERE target_id = ?`, target).Scan(&itemStatus))
	switch status {
	case "done":
		assert.InDelta(t, 1.0, progress, 1e-9)
	case "in_progress":
		assert.InDelta(t, statusToProgress("in_progress"), progress, 1e-9)
	default:
		t.Fatalf("status %q, want one of %v", status, statuses)
	}
	// Whichever committed last holds the row; the done write's cascade ran
	// in its own transaction either way, so the item is resolved exactly
	// when done committed (always, here) — never half of one write.
	assert.Equal(t, "resolved", itemStatus)
	h := statusHistory(t, d, target)
	for _, r := range h[1:] {
		assert.Equal(t, ActorOwner, r.actor)
	}
	assert.Equal(t, status, h[len(h)-1].to)
}
