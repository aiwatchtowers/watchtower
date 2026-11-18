package watchmanact

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/db"
)

func TestWriteSidecar_AtomicAndReadable(t *testing.T) {
	ws := t.TempDir()
	path := SidecarPath(ws)
	assert.Equal(t, filepath.Join(ws, "watchman.armed"), path)
	sessions := []db.ArmedSession{
		{SessionID: 7, WorkbenchID: 1, Folder: "/tmp/acme/wt-7"},
		{SessionID: 9, WorkbenchID: 1, Folder: "/tmp/acme/wt-7"}, // one worktree, two sessions
		{SessionID: 11, WorkbenchID: 2, Folder: "/tmp/acme-docs"},
	}
	require.NoError(t, WriteSidecar(path, sessions, true))
	raw, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, "session 7\nworktree /tmp/acme/wt-7\nsession 9\nsession 11\nworktree /tmp/acme-docs\ntargets-armed\n", string(raw))
	got, err := ReadSidecar(path)
	require.NoError(t, err)
	assert.Equal(t, Sidecar{Sessions: []int64{7, 9, 11}, Worktrees: []string{"/tmp/acme/wt-7", "/tmp/acme-docs"}, TargetsArmed: true}, got)

	// A rewrite replaces the whole file; no temp file is left beside it.
	require.NoError(t, WriteSidecar(path, sessions[2:], false))
	got, err = ReadSidecar(path)
	require.NoError(t, err)
	assert.Equal(t, Sidecar{Sessions: []int64{11}, Worktrees: []string{"/tmp/acme-docs"}}, got)
	entries, err := os.ReadDir(ws)
	require.NoError(t, err)
	require.Len(t, entries, 1)
	assert.Equal(t, "watchman.armed", entries[0].Name())

	// Nothing armed: an empty file, read as not armed.
	require.NoError(t, WriteSidecar(path, nil, false))
	got, err = ReadSidecar(path)
	require.NoError(t, err)
	assert.Equal(t, Sidecar{}, got)
}

func TestReadSidecar_MissingIsNotArmed(t *testing.T) {
	got, err := ReadSidecar(filepath.Join(t.TempDir(), "watchman.armed"))
	require.NoError(t, err)
	assert.Equal(t, Sidecar{}, got)
}

func TestReadSidecar_SkipsUnknownLines(t *testing.T) {
	path := filepath.Join(t.TempDir(), "watchman.armed")
	require.NoError(t, os.WriteFile(path, []byte("session x\nsomething else\nsession 3\nworktree /tmp/acme\n"), 0o600))
	got, err := ReadSidecar(path)
	require.NoError(t, err)
	assert.Equal(t, Sidecar{Sessions: []int64{3}, Worktrees: []string{"/tmp/acme"}}, got)
}
