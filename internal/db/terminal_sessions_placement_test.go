package db

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestPlacedSessions_ListsRowsWithAWorktreeBranch(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	plain := newAgentStateRow(t, d, wb, "claude", "uuid-plain")
	placed := newAgentStateRow(t, d, wb, "claude", "uuid-placed")
	_, err := d.Exec(`UPDATE terminal_sessions SET folder_path = '/repo/.claude/worktrees/a',
		worktree_branch = 'wt/a', worktree_base = 'abc' WHERE id = ?`, placed)
	require.NoError(t, err)

	got, err := d.PlacedSessions(wb)
	require.NoError(t, err)
	assert.Equal(t, []PlacedSession{{ID: placed, FolderPath: "/repo/.claude/worktrees/a", Branch: "wt/a"}}, got)

	row, err := d.GetTerminalSession(placed)
	require.NoError(t, err)
	assert.Equal(t, "wt/a", row.WorktreeBranch.String)
	other, err := d.GetTerminalSession(plain)
	require.NoError(t, err)
	assert.False(t, other.WorktreeBranch.Valid)
}

func TestHeldWorktreeBranches_EveryWorkbenchsRowsDistinct(t *testing.T) {
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	other, err := d.CreateWorkbench("other", t.TempDir())
	require.NoError(t, err)
	newAgentStateRow(t, d, wb, "claude", "uuid-plain")
	for _, r := range []struct {
		wb     int64
		uuid   string
		branch string
	}{{wb, "uuid-b", "wt/b"}, {other, "uuid-a", "wt/a"}, {other, "uuid-a2", "wt/a"}} {
		id := newAgentStateRow(t, d, r.wb, "claude", r.uuid)
		_, err := d.Exec(`UPDATE terminal_sessions SET worktree_branch = ? WHERE id = ?`, r.branch, id)
		require.NoError(t, err)
	}
	got, err := d.HeldWorktreeBranches(context.Background())
	require.NoError(t, err)
	assert.Equal(t, []string{"wt/a", "wt/b"}, got)
}
