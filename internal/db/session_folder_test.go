package db

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestSessionFolder_OwnFolderElseHome(t *testing.T) {
	ctx := context.Background()
	d := openTestDB(t)
	wb := newTestWorkbench(t, d)
	p, err := d.GetWorkbench(wb)
	require.NoError(t, err)
	home := homeFolderID(t, d, wb)
	hubPath := t.TempDir()
	hub := addTestFolder(t, d, wb, hubPath, "hub", 1)

	inHub, err := d.CreateTerminalSession(ctx, NewTerminalSession{WorkbenchID: wb, Kind: "codex", Title: "Hub",
		FolderPath: hubPath, WorkbenchFolderID: hub})
	require.NoError(t, err)
	legacy, err := d.CreateTerminalSession(ctx, NewTerminalSession{WorkbenchID: wb, Kind: "codex", Title: "Old",
		FolderPath: p.FolderPath})
	require.NoError(t, err)
	standalone, err := d.CreateTerminalSession(ctx, NewTerminalSession{Kind: "shell", Title: "Terminal", FolderPath: "/tmp"})
	require.NoError(t, err)

	path, removed, err := d.SessionFolderPath(ctx, inHub)
	require.NoError(t, err)
	assert.Equal(t, hubPath, path)
	assert.False(t, removed)
	id, err := d.SessionFolderID(ctx, inHub)
	require.NoError(t, err)
	assert.Equal(t, hub, id)

	path, removed, err = d.SessionFolderPath(ctx, legacy)
	require.NoError(t, err)
	assert.Equal(t, p.FolderPath, path, "a row with no folder reads as the workbench folder")
	assert.False(t, removed)
	id, err = d.SessionFolderID(ctx, legacy)
	require.NoError(t, err)
	assert.Equal(t, home, id)

	_, err = d.Exec(`UPDATE workbench_folders SET removed_at = '2026-11-18T00:00:00Z' WHERE id = ?`, hub)
	require.NoError(t, err)
	path, removed, err = d.SessionFolderPath(ctx, inHub)
	require.NoError(t, err)
	assert.Equal(t, hubPath, path, "a removed folder keeps its path")
	assert.True(t, removed)

	_, _, err = d.SessionFolderPath(ctx, standalone)
	require.ErrorIs(t, err, ErrTerminalSessionNotFound)
	_, err = d.SessionFolderID(ctx, standalone)
	require.ErrorIs(t, err, ErrTerminalSessionNotFound)
}
