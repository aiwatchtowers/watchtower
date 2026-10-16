package db

import (
	"path/filepath"
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestMigration00122_AutomationRunColumns(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "auto-wb.db"))
	require.NoError(t, err)
	defer d.Close()

	for _, table := range []string{"owner_asks", "terminal_sessions"} {
		assert.True(t, columnNames(t, d.DB, table)["automation_run_id"], table)
	}

	wb := newTestWorkbench(t, d)
	autoID := seedAutomationRow(t, d, "digest", "/tmp/acme/digest.md", "h1")
	runID := seedGrantRun(t, d, autoID, "h1")
	sid := newTestSession(t, d, wb)
	_, err = d.Exec(`UPDATE terminal_sessions SET automation_run_id = ? WHERE id = ?`, runID, sid)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO owner_asks (project_id, kind, title, automation_run_id) VALUES (?, 'question', 'Q', ?)`, wb, runID)
	require.NoError(t, err)

	// A row without a run reads NULL.
	other := newTestSession(t, d, wb)
	var v any
	require.NoError(t, d.QueryRow(`SELECT automation_run_id FROM terminal_sessions WHERE id = ?`, other).Scan(&v))
	assert.Nil(t, v)

	_, err = d.Exec(`DELETE FROM automation_runs WHERE id = ?`, runID)
	require.NoError(t, err)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM terminal_sessions WHERE id = ? AND automation_run_id IS NULL`, sid).Scan(&n))
	assert.Equal(t, 1, n, "deleting the run keeps the session and nulls the link")
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM owner_asks WHERE automation_run_id IS NULL`).Scan(&n))
	assert.Equal(t, 1, n, "deleting the run keeps the ask and nulls the link")

	require.NoError(t, goose.DownTo(d.DB, "migrations", 121))
	for _, table := range []string{"owner_asks", "terminal_sessions"} {
		assert.False(t, columnNames(t, d.DB, table)["automation_run_id"], table)
	}
	require.NoError(t, goose.Up(d.DB, "migrations"))
}
