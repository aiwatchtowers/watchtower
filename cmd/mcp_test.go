package cmd

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/spf13/cobra"
	"github.com/spf13/viper"
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
	chat, project, chatProject, agent := mcpFlagChat, mcpFlagWorkbench, mcpFlagChatProject, mcpFlagAgent
	surface, run, runTools, ready := mcpFlagSurface, mcpFlagAutomationRun, mcpFlagAutomationTools, mcpFlagAutomationReadyFile
	t.Cleanup(func() {
		mcpFlagChat, mcpFlagWorkbench, mcpFlagChatProject, mcpFlagAgent = chat, project, chatProject, agent
		mcpFlagSurface, mcpFlagAutomationRun, mcpFlagAutomationTools, mcpFlagAutomationReadyFile = surface, run, runTools, ready
	})
	mcpFlagChat, mcpFlagWorkbench, mcpFlagChatProject, mcpFlagAgent = false, 0, 0, ""
	mcpFlagSurface, mcpFlagAutomationRun, mcpFlagAutomationTools, mcpFlagAutomationReadyFile = "main", 0, nil, ""
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

// DEV-06 / DEV-01: plain `watchtower mcp` (no --chat, no --workbench) is still
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

// Spec 2026-10-12 §6.5: `mcp --workbench N --agent codex` labels an agent
// comment codex-cli when no terminal session names the agent; --agent is
// refused outside workbench mode and for anything but an agent kind.
func TestMCPWorkbenchMode_AgentFlagLabelsComments(t *testing.T) {
	resetMCPFlags(t)
	t.Setenv("WATCHTOWER_TERMINAL_SESSION_ID", "")
	database := openMCPTestDB(t)
	cfg := &config.Config{ActiveWorkspace: "test-ws"}
	folder, err := db.ResolveWorkbenchFolder(t.TempDir(), nil)
	require.NoError(t, err)
	pid, err := database.CreateWorkbench("acme", folder)
	require.NoError(t, err)

	mcpFlagAgent = "codex"
	_, err = mcpModeOptions(cfg, database, "", nil)
	assert.ErrorContains(t, err, "--agent requires --workbench")

	mcpFlagWorkbench = pid
	for _, bad := range []string{"shell", "Codex", "gemini"} {
		mcpFlagAgent = bad
		_, err = mcpModeOptions(cfg, database, "", nil)
		assert.ErrorContains(t, err, "--agent must be claude or codex", bad)
	}

	mcpFlagAgent = "codex"
	opts, err := mcpModeOptions(cfg, database, "", nil)
	require.NoError(t, err)
	_, ls := localToolNames(t, database, opts)
	text, isErr, err := ls.Call(context.Background(), "create_targets", map[string]any{
		"items": []any{map[string]any{"text": "Feature X"}}, "reason": "first board",
	})
	require.NoError(t, err)
	require.False(t, isErr, text)
	board, err := database.GetWorkbenchBoard(pid)
	require.NoError(t, err)
	require.Len(t, board, 1)
	text, isErr, err = ls.Call(context.Background(), "add_comment", map[string]any{
		"target_id": board[0].Target.ID, "body": "Which DB?", "reason": "blocked",
	})
	require.NoError(t, err)
	require.False(t, isErr, text)
	var label string
	require.NoError(t, database.QueryRow(`SELECT agent_label FROM project_comments WHERE project_id = ?`, pid).Scan(&label))
	assert.Equal(t, "codex-cli", label)
}

// Only the automations executor binds a run: a chat-mode server started with
// --context-type automation_run is refused, so a chat can never record rows
// that read as a run's proposals (AGENT-01).
func TestMCPChatMode_RefusesAutomationRunContext(t *testing.T) {
	resetMCPFlags(t)
	ctxType, ctxID, surface := mcpFlagContextType, mcpFlagContextID, mcpFlagSurface
	t.Cleanup(func() { mcpFlagContextType, mcpFlagContextID, mcpFlagSurface = ctxType, ctxID, surface })
	database := openMCPTestDB(t)
	mcpFlagChat, mcpFlagSurface = true, "main"
	mcpFlagContextType = tools.AutomationContextType
	mcpFlagContextID = "7"
	_, err := mcpModeOptions(&config.Config{ActiveWorkspace: "test-ws"}, database, "t1", nil)
	require.ErrorContains(t, err, "reserved for automation runs")

	mcpFlagContextType = "target"
	_, err = mcpModeOptions(&config.Config{ActiveWorkspace: "test-ws"}, database, "t1", nil)
	require.NoError(t, err, "an ordinary chat context still starts")
}

// resetMCPChatBindingFlags restores the chat binding flags a test parses.
func resetMCPChatBindingFlags(t *testing.T) {
	t.Helper()
	surface, conv, turn, ctxType, ctxID := mcpFlagSurface, mcpFlagConversation, mcpFlagTurn, mcpFlagContextType, mcpFlagContextID
	t.Cleanup(func() {
		mcpFlagSurface, mcpFlagConversation, mcpFlagTurn, mcpFlagContextType, mcpFlagContextID = surface, conv, turn, ctxType, ctxID
	})
}

// The "change it in words" chat (spec 2026-10-14 §14.5) starts the chat
// server on automation_editor, bound to one automation, and mounts the
// authoring pair there.
func TestMCP_SurfaceFlagAcceptsAutomationEditor(t *testing.T) {
	resetMCPFlags(t)
	resetMCPChatBindingFlags(t)
	database := openMCPTestDB(t)
	mcpFlagChat, mcpFlagSurface = true, tools.AutomationEditorSurface
	mcpFlagContextType, mcpFlagContextID = "automation", "7"
	opts, err := mcpModeOptions(&config.Config{ActiveWorkspace: "test-ws"}, database, "t1", nil)
	require.NoError(t, err)
	names, _ := localToolNames(t, database, opts)
	assert.True(t, names["draft_automation"])
	assert.True(t, names["save_automation"])
	assert.False(t, names["create_target"], "no other write tool on automation_editor")
}

// Any surface value other than main, target, automation (the P6 agent()
// server, routed to mcpAutomationOptions) and automation_editor is refused
// before a server starts.
func TestMCP_SurfaceFlagRejectsUnknown(t *testing.T) {
	resetMCPFlags(t)
	resetMCPChatBindingFlags(t)
	database := openMCPTestDB(t)
	mcpFlagChat = true
	for _, surface := range []string{"x", "automation_edit"} {
		mcpFlagSurface = surface
		_, err := mcpModeOptions(&config.Config{ActiveWorkspace: "test-ws"}, database, "t1", nil)
		require.ErrorContains(t, err, "--surface must be main, target, automation or automation_editor", surface)
	}
}

// A pre-rename `mcp --project N` is refused before the root's config hook:
// a malformed, missing or stale config neither replaces the Repair line with
// a config error nor gets rewritten on the way to the refusal (ask #312), and
// the refusal is never an exitCodeError.
func TestMCP_PreRenameRefusedBeforeConfigHook(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	const repair = "ask the owner to run Repair install in Watchtower (or 'watchtower workbench resync 7')."
	original := flagConfig
	t.Cleanup(func() { flagConfig = original })

	for name, content := range map[string]string{
		"malformed": "active_workspace: [unclosed\n\tbad",
		"stale":     "active_workspace: test\ndb:\n  schema_format: 0\n",
		"missing":   "",
	} {
		t.Run(name, func(t *testing.T) {
			flagConfig = filepath.Join(t.TempDir(), "config.yaml")
			if content != "" {
				require.NoError(t, os.WriteFile(flagConfig, []byte(content), 0o600))
			}

			stdout, _, err := runRootCmd(t, []*cobra.Command{mcpCmd}, "mcp", "--project", "7")
			require.Error(t, err)
			assert.Empty(t, stdout, "no session is served")
			assert.Contains(t, err.Error(), repair)
			assert.NotContains(t, err.Error(), "config")
			var ec *exitCodeError
			assert.False(t, errors.As(err, &ec), "mcp --project must exit 1, got %v", err)

			got, readErr := os.ReadFile(flagConfig)
			if content == "" {
				assert.ErrorIs(t, readErr, os.ErrNotExist, "no config is created")
				return
			}
			require.NoError(t, readErr)
			assert.Equal(t, content, string(got), "the config file is untouched")
		})
	}
}

// mcp's own PersistentPreRunE replaces the root's (cobra runs only the
// closest one), so a normal `mcp --workbench N` must still get
// ensureSchemaFormat's schema_format bump. No database exists under the temp
// HOME, so the hook skips RunSchemaUpgrade.
func TestMCP_WorkbenchStillRunsRootSchemaFormatHook(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	configPath := writeFeaturesConfig(t, "db:\n  schema_format: 0\n")
	require.NoError(t, mcpCmd.ParseFlags([]string{"--workbench", "7"}))
	t.Cleanup(func() { resetSetFlags(mcpCmd) })

	require.NoError(t, mcpCmd.PersistentPreRunE(mcpCmd, nil))

	v := viper.New()
	v.SetConfigFile(configPath)
	require.NoError(t, v.ReadInConfig())
	assert.Equal(t, db.CurrentSchemaFormat, v.GetInt("db.schema_format"), "rootCmd's ensureSchemaFormat must still run")
}
