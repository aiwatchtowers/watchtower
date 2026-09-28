package cmd

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestMCPTurnBinding(t *testing.T) {
	turn, fn, err := mcpTurnBinding(true, "t1", "")
	require.NoError(t, err)
	assert.Equal(t, "t1", turn)
	assert.Nil(t, fn)

	path := filepath.Join(t.TempDir(), "turn.txt")
	require.NoError(t, os.WriteFile(path, []byte("t-from-file\n"), 0o600))
	turn, fn, err = mcpTurnBinding(true, "", path)
	require.NoError(t, err)
	assert.Equal(t, "", turn)
	require.NotNil(t, fn)
	assert.Equal(t, "t-from-file", fn())

	_, _, err = mcpTurnBinding(true, "t1", path)
	assert.ErrorContains(t, err, "mutually exclusive")

	_, _, err = mcpTurnBinding(false, "", path)
	assert.ErrorContains(t, err, "requires --chat")
}
