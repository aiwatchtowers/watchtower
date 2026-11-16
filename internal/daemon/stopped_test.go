package daemon

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestStoppedMarker_WriteReadRemove: the marker is one 0600 JSON line
// {"at": RFC 3339, "by": "cli"}, read back as written; removing it twice is
// no error, and an absent marker reads as none.
func TestStoppedMarker_WriteReadRemove(t *testing.T) {
	ws := t.TempDir()
	_, ok, err := ReadStoppedMarker(ws)
	require.NoError(t, err)
	assert.False(t, ok)

	at := time.Date(2026, 11, 16, 9, 30, 15, 0, time.UTC)
	require.NoError(t, WriteStoppedMarker(ws, at, "cli"))
	path := filepath.Join(ws, StoppedMarkerName)
	info, err := os.Stat(path)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())
	b, err := os.ReadFile(path)
	require.NoError(t, err)
	assert.Equal(t, `{"at":"2026-11-16T09:30:15Z","by":"cli"}`+"\n", string(b))

	m, ok, err := ReadStoppedMarker(ws)
	require.NoError(t, err)
	require.True(t, ok)
	assert.True(t, m.At.Equal(at))
	assert.Equal(t, "cli", m.By)

	require.NoError(t, RemoveStoppedMarker(ws))
	require.NoError(t, RemoveStoppedMarker(ws))
	_, ok, err = ReadStoppedMarker(ws)
	require.NoError(t, err)
	assert.False(t, ok)
}
