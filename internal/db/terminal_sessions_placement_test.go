package db

import (
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
