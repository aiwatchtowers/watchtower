package db

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestAgentReportTargets(t *testing.T) {
	d := openTestDB(t)
	pid := newTestWorkbench(t, d)
	res, err := d.Exec(`INSERT INTO targets (text, period_start, period_end, project_id) VALUES ('parent', '2026-01-01', '2026-12-31', ?)`, pid)
	require.NoError(t, err)
	parent, _ := res.LastInsertId()
	_, err = d.Exec(`INSERT INTO targets (text, period_start, period_end, project_id, parent_id) VALUES ('child', '2026-01-01', '2026-12-31', ?, ?)`, pid, parent)
	require.NoError(t, err)
	_, err = d.Exec(`UPDATE targets SET status = 'in_progress' WHERE id = ?`, parent+1)
	require.NoError(t, err)
	_, err = d.Exec(`INSERT INTO targets (text, period_start, period_end) VALUES ('personal', '2026-01-01', '2026-12-31')`)
	require.NoError(t, err)

	got, err := d.AgentReportTargets(pid)
	require.NoError(t, err)
	require.Len(t, got, 2)
	assert.Nil(t, got[0].ParentID)
	require.NotNil(t, got[1].ParentID)
	assert.Equal(t, parent, *got[1].ParentID)
	assert.Equal(t, "in_progress", got[1].Status)
	require.Len(t, got[1].History, 2)
	assert.Equal(t, "todo", got[1].History[0].To)
	assert.Equal(t, "in_progress", got[1].History[1].To)
}
