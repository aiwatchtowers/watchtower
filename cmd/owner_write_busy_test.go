package cmd

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

func busyTimeoutMS(t *testing.T, database *db.DB) int64 {
	t.Helper()
	var ms int64
	require.NoError(t, database.QueryRow(`PRAGMA busy_timeout`).Scan(&ms))
	return ms
}

// Backlog 2026-09-30 (approving a chat proposal fails with SQLITE_BUSY): the
// writable MCP modes record owner-facing rows, so they wait out a background
// writer for ownerWriteBusyTimeout instead of Open's 5 s; the read-only dev
// mode keeps the default.
func TestMCPModeOptions_WritableModesGetTheOwnerWriteBusyTimeout(t *testing.T) {
	cfg := &config.Config{ActiveWorkspace: "test-ws"}

	resetMCPFlags(t)
	dev := openMCPTestDB(t)
	_, err := mcpModeOptions(cfg, dev, "", nil)
	require.NoError(t, err)
	assert.Equal(t, int64(5000), busyTimeoutMS(t, dev), "dev mode keeps Open's default")

	resetMCPFlags(t)
	mcpFlagChat = true
	chatDB := openMCPTestDB(t)
	_, err = mcpModeOptions(cfg, chatDB, "", nil)
	require.NoError(t, err)
	assert.Equal(t, ownerWriteBusyTimeout.Milliseconds(), busyTimeoutMS(t, chatDB))

	resetMCPFlags(t)
	projectDB := openMCPTestDB(t)
	folder, err := db.ResolveProjectFolder(t.TempDir(), nil)
	require.NoError(t, err)
	mcpFlagProject, err = projectDB.CreateProject("acme", folder)
	require.NoError(t, err)
	_, err = mcpModeOptions(cfg, projectDB, "", nil)
	require.NoError(t, err)
	assert.Equal(t, ownerWriteBusyTimeout.Milliseconds(), busyTimeoutMS(t, projectDB))
}

func TestOpenActionsCmd_UsesTheOwnerWriteBusyTimeout(t *testing.T) {
	writeActionsConfig(t)
	_, database, _, err := openActionsCmd()
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	assert.Equal(t, ownerWriteBusyTimeout.Milliseconds(), busyTimeoutMS(t, database))
}
