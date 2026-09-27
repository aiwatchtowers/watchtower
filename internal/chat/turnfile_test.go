package chat

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestTurnFile_WriteThenRead(t *testing.T) {
	path := filepath.Join(t.TempDir(), "turn.txt")
	read := TurnFileReader(path)
	assert.Equal(t, "", read(), "a missing file reads as no turn")

	require.NoError(t, WriteTurnFile(path, "turn-1"))
	assert.Equal(t, "turn-1", read())
	require.NoError(t, WriteTurnFile(path, "turn-2"))
	assert.Equal(t, "turn-2", read(), "the reader sees the newest turn on every call")

	info, err := os.Stat(path)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())
}
