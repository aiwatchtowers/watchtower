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
	chat, project, chatProject := mcpFlagChat, mcpFlagWorkbench, mcpFlagChatProject
	t.Cleanup(func() { mcpFlagChat, mcpFlagWorkbench, mcpFlagChatProject = chat, project, chatProject })
	mcpFlagChat, mcpFlagWorkbench, mcpFlagChatProject = false, 0, 0
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
	folder, err := db.ResolveWorkbenchFolder(t.TempDir(), nil)
	require.NoError(t, err)
	pid, err := database.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	mcpFlagWorkbench = pid

	opts, err := mcpModeOptions(&config.Config{ActiveWorkspace: "test-ws"}, database, "", nil)
	require.NoError(t, err)
	require.Len(t, opts, 1)

	names, ls := localToolNames(t, database, opts)
	for _, n := range []string{"workbench_info", "workbench_board", "create_targets", "get_action", "list_targets"} {
		assert.True(t, names[n], "project mode mounts %s", n)
	}
	for _, n := range []string{"create_target", "create_jira_issue", "connect_jira_board", "create_idea", "attach_document"} {
		assert.False(t, names[n], "project mode must not mount %s", n)
	}

	text, isErr, err := ls.Call(context.Background(), "create_targets", map[string]any{
		"items": []any{map[string]any{"text": "Feature X"}}, "reason": "first board",
	})
	require.NoError(t, err)
	require.False(t, isErr, text)
	assert.Contains(t, text, `"status": "applied"`)
	board, err := database.GetWorkbenchBoard(pid)
	require.NoError(t, err)
	require.Len(t, board, 1)
	assert.Equal(t, "Feature X", board[0].Target.Text)
}

// Board #209: `mcp --chat --chat-project N` binds the chat project, so
// search_knowledge resolves that project's pins; --chat-project without
// --chat is refused.
func TestMCPChatMode_BindsTheChatProject(t *testing.T) {
	resetMCPFlags(t)
	database := openMCPTestDB(t)
	cfg := &config.Config{ActiveWorkspace: "test-ws"}
	res, err := database.Exec(`INSERT INTO chat_projects (name, created_at, updated_at) VALUES ('p', 1, 1)`)
	require.NoError(t, err)
	pid, err := res.LastInsertId()
	require.NoError(t, err)

	mcpFlagChatProject = pid
	_, err = mcpModeOptions(cfg, database, "", nil)
	assert.ErrorContains(t, err, "--chat-project requires --chat")

	mcpFlagChat = true
	mcpFlagChatProject = -1
	_, err = mcpModeOptions(cfg, database, "t1", nil)
	assert.ErrorContains(t, err, "must be a chat project id")

	mcpFlagChatProject = pid
	opts, err := mcpModeOptions(cfg, database, "t1", nil)
	require.NoError(t, err)
	_, ls := localToolNames(t, database, opts)
	text, isErr, err := ls.Call(context.Background(), "search_knowledge", map[string]any{
		"queries": []any{"x"}, "workbench_scope": "only",
	})
	require.NoError(t, err)
	assert.True(t, isErr)
	assert.Contains(t, text, "this chat project has no usable", "the session is bound to the chat project")
}

func TestSessionMCPArgs_PassesTheChatProject(t *testing.T) {
	conv := &db.ChatConversation{ID: 5}
	assert.NotContains(t, sessionMCPArgs("main", conv, "/tmp/turn", 0), "--chat-project")
	args := sessionMCPArgs("main", conv, "/tmp/turn", 9)
	i := slices.Index(args, "--chat-project")
	require.GreaterOrEqual(t, i, 0)
	assert.Equal(t, "9", args[i+1])
}

// A --project-id naming no chat project binds nothing: no --chat-project, no
// ChatProjectID on the in-process binding.
func TestLoadSessionProject_BindsOnlyAnExistingProject(t *testing.T) {
	database := openMCPTestDB(t)
	res, err := database.Exec(`INSERT INTO chat_projects (name, created_at, updated_at) VALUES ('p', 1, 1)`)
	require.NoError(t, err)
	pid, err := res.LastInsertId()
	require.NoError(t, err)

	project, id, err := loadSessionProject(database, pid)
	require.NoError(t, err)
	require.NotNil(t, project)
	assert.Equal(t, pid, id)
	w := sessionWiring{conv: &db.ChatConversation{ID: 5}, chatProjectID: id}
	assert.Equal(t, pid, sessionToolBinding(w).ChatProjectID, "ollama binds the project like the MCP server")

	for _, missing := range []int64{0, 404} {
		project, id, err = loadSessionProject(database, missing)
		require.NoError(t, err)
		assert.Nil(t, project)
		assert.Zero(t, id, "project %d", missing)
	}
}

func TestMCPProjectMode_RefusesMissingProjectAndChat(t *testing.T) {
	resetMCPFlags(t)
	database := openMCPTestDB(t)
	cfg := &config.Config{ActiveWorkspace: "test-ws"}

	mcpFlagWorkbench = 404
	_, err := mcpModeOptions(cfg, database, "", nil)
	assert.ErrorIs(t, err, db.ErrWorkbenchNotFound)

	mcpFlagChat = true
	_, err = mcpModeOptions(cfg, database, "", nil)
	assert.ErrorContains(t, err, "mutually exclusive")
}

// Spec 2026-10-02 §5.2: `mcp --project N` (a folder installed before the
// rename) serves the renamed workbench tools under their old names only;
// `mcp --workbench N` the new names only. Ten workbench tools either way.
func TestMCPProjectMode_LegacyFlagServesTheOldToolNames(t *testing.T) {
	resetMCPFlags(t)
	legacyFlag := mcpCmd.Flags().Lookup(legacyWorkbenchFlag)
	t.Cleanup(func() { legacyFlag.Changed = false })
	cfg := &config.Config{ActiveWorkspace: "test-ws"}

	for _, legacy := range []bool{false, true} {
		database := openMCPTestDB(t)
		folder, err := db.ResolveWorkbenchFolder(t.TempDir(), nil)
		require.NoError(t, err)
		pid, err := database.CreateWorkbench("acme", folder)
		require.NoError(t, err)
		mcpFlagWorkbench, legacyFlag.Changed = pid, legacy

		opts, err := mcpModeOptions(cfg, database, "", nil)
		require.NoError(t, err)
		names, ls := localToolNames(t, database, opts)
		workbenchTools := 0
		for name := range names {
			if name == "send_slack_message" || name == "get_writing_style" {
				continue // main + project surfaces, not workbench tools (#166)
			}
			if tool, ok := buildToolRegistry(cfg, database).Get(name); ok && slices.Contains(tool.Surfaces, "project") {
				workbenchTools++
			}
		}
		assert.Equal(t, 10, workbenchTools, "legacy=%v", legacy)
		assert.True(t, names["send_slack_message"] && names["get_writing_style"], "legacy=%v lists the Slack pair", legacy)
		for newName, oldName := range tools.LegacyWorkbenchToolNames {
			assert.Equal(t, legacy, names[oldName], "legacy=%v lists %s", legacy, oldName)
			assert.Equal(t, !legacy, names[newName], "legacy=%v lists %s", legacy, newName)
		}

		if legacy {
			text, isErr, err := ls.Call(context.Background(), "update_project", map[string]any{"description": "Old setup.", "reason": "setup"})
			require.NoError(t, err)
			require.False(t, isErr, text)
			rows, err := database.ListAgentActions(db.AgentActionFilter{})
			require.NoError(t, err)
			require.Len(t, rows, 1)
			assert.Equal(t, tools.UpdateWorkbenchTool, rows[0].Tool, "the audit row records the canonical name")
		}
	}
}
