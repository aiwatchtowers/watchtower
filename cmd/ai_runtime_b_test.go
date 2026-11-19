package cmd

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/agentloop"
	"watchtower/internal/ai"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/externalmcp"
	"watchtower/internal/providers/transport"
	"watchtower/internal/tools"
)

// seedQuickConnection writes one enabled stdio connection with a read and a
// write tool and its secret, in cfg's workspace database.
func seedQuickConnection(t *testing.T, cfg *config.Config) string {
	t.Helper()
	dbPath := cfg.DBPath()
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	connID, err := database.InsertExternalConnection(db.ExternalConnection{
		Name: "trello", Kind: "stdio", Command: "npx", Args: []string{"-y", "trello-mcp"}, Enabled: true,
	})
	require.NoError(t, err)
	require.NoError(t, database.SetExternalConnectionTools(connID,
		[]db.ExternalTool{{Name: "list_boards"}, {Name: "create_card"}}, time.Now().UTC().Format(time.RFC3339)))
	require.NoError(t, externalmcp.NewSecretStore(cfg.WorkspaceDir(), connID).Save(&externalmcp.Secret{
		Env: map[string]string{"TRELLO_TOKEN": "abc"},
	}))
	require.NoError(t, database.Close())
	return dbPath
}

// TestAISession_RuntimeBMountsQuickConnections (L8): the ollama chat
// session's runtime-B loop gets the owner's Quick Connections, each limited
// to its QC-02 allowed read tools, loaded per turn like codex.
func TestAISession_RuntimeBMountsQuickConnections(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test-ws", AI: config.AIConfig{Provider: "ollama"}}
	dbPath := seedQuickConnection(t, cfg)
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })

	loop := runtimeBSessionClient(sessionWiring{cfg: cfg, database: database, dbPath: dbPath,
		conv: &db.ChatConversation{ID: 1}, model: "llama", turnFile: filepath.Join(t.TempDir(), "turn")})
	servers := loop.ExternalServersForTest()
	require.Len(t, servers, 1)
	assert.Equal(t, "trello", servers[0].Name)
	assert.Equal(t, map[string]string{"TRELLO_TOKEN": "abc"}, servers[0].Env)
	assert.Equal(t, []string{"list_boards"}, servers[0].AllowTools, "only the read-only tool (QC-02)")
	assert.Equal(t, []string{"create_card"}, servers[0].DenyTools)
}

// TestAIQuery_RuntimeBMountsQuickConnectionsExceptEditor (L8): `ai query
// --tools chat` on ollama mounts the connections on main and target, and
// none on the automation editor (D11), as for claude and codex.
func TestAIQuery_RuntimeBMountsQuickConnectionsExceptEditor(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test-ws", AI: config.AIConfig{Provider: "ollama"}}
	dbPath := seedQuickConnection(t, cfg)

	oldTools, oldModel, oldSurface := aiFlagTools, aiFlagModel, aiFlagSurface
	defer func() { aiFlagTools, aiFlagModel, aiFlagSurface = oldTools, oldModel, oldSurface }()
	aiFlagTools, aiFlagModel = "chat", "llama"
	servers := func(surface string) []ai.ExternalMCPServer {
		aiFlagSurface = surface
		client, cleanup, err := newQueryClient(cfg, dbPath, transport.Options{})
		require.NoError(t, err)
		defer cleanup()
		loop, ok := client.(*agentloop.Client)
		require.True(t, ok, "ollama + --tools chat builds the runtime-B loop, got %T", client)
		return loop.ExternalServersForTest()
	}

	assert.Empty(t, servers(tools.AutomationEditorSurface), "no external server on automation_editor")
	main := servers("main")
	require.Len(t, main, 1)
	assert.Equal(t, []string{"list_boards"}, main[0].AllowTools)
	assert.Len(t, servers("target"), 1)
}

// TestAIQuery_RuntimeBRefusesTuning (spec 2026-11-03 D52): the tuning tools
// need a provider that runs an MCP child, so the runtime-B loop refuses the
// tuning surface before it opens the database; main still builds the loop.
func TestAIQuery_RuntimeBRefusesTuning(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test-ws", AI: config.AIConfig{Provider: "ollama"}}
	dbPath := seedQuickConnection(t, cfg)

	oldTools, oldModel, oldSurface := aiFlagTools, aiFlagModel, aiFlagSurface
	defer func() { aiFlagTools, aiFlagModel, aiFlagSurface = oldTools, oldModel, oldSurface }()
	aiFlagTools, aiFlagModel, aiFlagSurface = "chat", "llama", tools.SurfaceTuning
	client, _, err := newQueryClient(cfg, dbPath, transport.Options{})
	require.ErrorContains(t, err, "tuning tools need Claude or Codex")
	assert.Nil(t, client)

	aiFlagSurface = "main"
	client, cleanup, err := newQueryClient(cfg, dbPath, transport.Options{})
	require.NoError(t, err)
	defer cleanup()
	loop, ok := client.(*agentloop.Client)
	require.True(t, ok, "got %T", client)
	assert.Len(t, loop.ExternalServersForTest(), 1)
}
