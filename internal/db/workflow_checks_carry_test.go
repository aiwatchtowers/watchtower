package db

import (
	"path/filepath"
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func carryPending(t *testing.T, d *DB, id int64) bool {
	t.Helper()
	var n int
	require.NoError(t, d.QueryRow(`SELECT methodology_carry_pending FROM projects WHERE id = ?`, id).Scan(&n))
	return n == 1
}

// Board #558, migration 00131: only the workbenches that exist at the
// upgrade are carry-pending; one created afterwards, or on a fresh install,
// never is. The Down drops the columns.
func TestMigration00131_MarksOnlyExistingWorkbenchesCarryPending(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "carry.db"))
	require.NoError(t, err)
	defer d.Close()
	fresh := newTestWorkbench(t, d)
	assert.False(t, carryPending(t, d, fresh), "a fresh install marks nothing")

	require.NoError(t, goose.DownTo(d.DB, "migrations", 130))
	assert.False(t, columnNames(t, d.DB, "projects")["methodology_carry_pending"])
	require.NoError(t, goose.Up(d.DB, "migrations"))

	assert.True(t, carryPending(t, d, fresh), "it existed at the upgrade")
	later := newTestWorkbench(t, d)
	assert.False(t, carryPending(t, d, later), "created after the upgrade")
	pending, err := d.ListWorkbenchesCarryPending()
	require.NoError(t, err)
	require.Len(t, pending, 1)
	assert.Equal(t, fresh, pending[0].ID)
}

// The carry-over writes only while pending and only an unset check, in one
// statement: a value the owner set before the write is never overwritten;
// the mark is cleared either way, so a second run changes nothing.
func TestCarryWorkflowChecks_OnlyPendingOnlyUnsetOnce(t *testing.T) {
	d := openTestDB(t)
	id := newTestWorkbench(t, d)
	ok, err := d.CarryWorkflowChecks(id, "off", "off", "2026-10-17T00:00:00Z")
	require.NoError(t, err)
	assert.False(t, ok, "not pending: nothing written")
	m, err := d.GetWorkbenchMethodology(id)
	require.NoError(t, err)
	assert.Equal(t, WorkbenchMethodology{}, m)

	_, err = d.Exec(`UPDATE projects SET methodology_carry_pending = 1 WHERE id = ?`, id)
	require.NoError(t, err)
	// The owner picks soft after the carry-over read the file, before its write.
	require.NoError(t, d.SetWorkbenchMethodology(id, WorkbenchMethodology{AskGuard: "soft"}))

	ok, err = d.CarryWorkflowChecks(id, "off", "off", "2026-10-17T00:00:00Z")
	require.NoError(t, err)
	assert.True(t, ok)
	m, err = d.GetWorkbenchMethodology(id)
	require.NoError(t, err)
	assert.Equal(t, WorkbenchMethodology{AskGuard: "soft", FinishCheck: "off"}, m, "the owner's soft is kept")
	carried, err := d.GetWorkbenchChecksCarried(id)
	require.NoError(t, err)
	assert.Equal(t, WorkbenchChecksCarried{FinishCheck: "2026-10-17T00:00:00Z"}, carried)
	assert.False(t, carryPending(t, d, id))

	ok, err = d.CarryWorkflowChecks(id, "off", "", "2026-10-18T00:00:00Z")
	require.NoError(t, err)
	assert.False(t, ok, "once")

	// An owner write keeps an unchanged check's carry moment and clears a changed one's.
	require.NoError(t, d.SetWorkbenchMethodology(id, WorkbenchMethodology{AskGuard: "strict", FinishCheck: "off"}))
	carried, err = d.GetWorkbenchChecksCarried(id)
	require.NoError(t, err)
	assert.Equal(t, "2026-10-17T00:00:00Z", carried.FinishCheck)
	require.NoError(t, d.SetWorkbenchMethodology(id, WorkbenchMethodology{AskGuard: "strict"}))
	carried, err = d.GetWorkbenchChecksCarried(id)
	require.NoError(t, err)
	assert.Equal(t, WorkbenchChecksCarried{}, carried)
}
