package cmd

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	internalmcp "watchtower/internal/mcp"
	"watchtower/internal/tools"
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

// resetMCPFlags restores the mcp command's package-level flags after a test.
func resetMCPFlags(t *testing.T) {
	t.Helper()
	chat, project := mcpFlagChat, mcpFlagProject
	t.Cleanup(func() { mcpFlagChat, mcpFlagProject = chat, project })
	mcpFlagChat, mcpFlagProject = false, 0
}

func openMCPTestDB(t *testing.T) *db.DB {
	t.Helper()
	database, err := db.Open(":memory:")
	require.NoError(t, err)
	database.SetMaxOpenConns(1) // one connection, so query_only covers every query
	t.Cleanup(func() { _ = database.Close() })
	return database
}

func localToolNames(t *testing.T, database *db.DB, opts []internalmcp.ServerOption) (map[string]bool, *internalmcp.LocalSession) {
	t.Helper()
	ls, err := internalmcp.NewServer(database, opts...).ConnectLocal(context.Background())
	require.NoError(t, err)
	t.Cleanup(func() { _ = ls.Close() })
	infos, err := ls.Tools(context.Background())
	require.NoError(t, err)
	names := map[string]bool{}
	for _, info := range infos {
		names[info.Name] = true
	}
	return names, ls
}

// DEV-06 / DEV-01: plain `watchtower mcp` (no --chat, no --project) is still
// the read-only developer surface — query_only on, no write tool, no project
// tool, no get_action.
func TestDev06_PlainMCPStaysReadOnly(t *testing.T) {
	resetMCPFlags(t)
	database := openMCPTestDB(t)
	cfg := &config.Config{ActiveWorkspace: "test-ws"}

	opts, err := mcpModeOptions(cfg, database, "", nil)
	require.NoError(t, err)
	assert.Empty(t, opts, "dev mode passes no registry")
	_, err = database.Exec(`INSERT INTO projects (name, folder_path) VALUES ('x', '/tmp/x')`)
	require.Error(t, err, "the dev connection must refuse writes (query_only)")

	names, _ := localToolNames(t, database, opts)
	for _, tool := range buildToolRegistry(cfg, openMCPTestDB(t)).All() {
		if tool.Access == tools.AccessWrite || slices.Contains(tool.Surfaces, "project") {
			assert.False(t, names[tool.Name], "dev mode must not mount %s", tool.Name)
		}
	}
	assert.False(t, names["get_action"])
	assert.True(t, names["list_targets"], "the read tools stay")
}

func TestMCPProjectMode_BindsTheProjectAndAppliesDirectly(t *testing.T) {
	resetMCPFlags(t)
	database := openMCPTestDB(t)
	folder, err := db.ResolveProjectFolder(t.TempDir())
	require.NoError(t, err)
	pid, err := database.CreateProject("acme", folder)
	require.NoError(t, err)
	mcpFlagProject = pid

	opts, err := mcpModeOptions(&config.Config{ActiveWorkspace: "test-ws"}, database, "", nil)
	require.NoError(t, err)
	require.Len(t, opts, 1)

	names, ls := localToolNames(t, database, opts)
	for _, n := range []string{"project_info", "project_board", "create_targets", "attach_document", "get_action", "list_targets"} {
		assert.True(t, names[n], "project mode mounts %s", n)
	}
	for _, n := range []string{"create_target", "create_jira_issue", "connect_jira_board", "create_idea"} {
		assert.False(t, names[n], "project mode must not mount %s", n)
	}

	text, isErr, err := ls.Call(context.Background(), "create_targets", map[string]any{
		"items": []any{map[string]any{"text": "Feature X"}}, "reason": "first board",
	})
	require.NoError(t, err)
	require.False(t, isErr, text)
	assert.Contains(t, text, `"status": "applied"`)
	board, err := database.GetProjectBoard(pid)
	require.NoError(t, err)
	require.Len(t, board, 1)
	assert.Equal(t, "Feature X", board[0].Target.Text)
}

func TestMCPProjectMode_RefusesMissingProjectAndChat(t *testing.T) {
	resetMCPFlags(t)
	database := openMCPTestDB(t)
	cfg := &config.Config{ActiveWorkspace: "test-ws"}

	mcpFlagProject = 404
	_, err := mcpModeOptions(cfg, database, "", nil)
	assert.ErrorIs(t, err, db.ErrProjectNotFound)

	mcpFlagChat = true
	_, err = mcpModeOptions(cfg, database, "", nil)
	assert.ErrorContains(t, err, "mutually exclusive")
}
