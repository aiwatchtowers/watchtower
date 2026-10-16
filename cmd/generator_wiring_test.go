package cmd

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/externalmcp"
	"watchtower/internal/providers"
	"watchtower/internal/tools"
)

func TestCliGeneratorProviderSwitch(t *testing.T) {
	tests := []struct {
		provider string
		wantType string
	}{
		{"claude", "*digest.ClaudeGenerator"},
		{"codex", "*codex.CodexGenerator"},
		{"ollama", "*ollama.Generator"},
		{"", "*digest.ClaudeGenerator"},
		{"unknown", "*digest.ClaudeGenerator"},
	}
	for _, tt := range tests {
		t.Run("gen/"+tt.provider, func(t *testing.T) {
			cfg := &config.Config{AI: config.AIConfig{Provider: tt.provider}}
			if got := fmt.Sprintf("%T", cliGenerator(cfg)); got != tt.wantType {
				t.Errorf("cliGenerator(%q) = %s, want %s", tt.provider, got, tt.wantType)
			}
		})
	}
}

func TestNewAIClientProviderSwitch(t *testing.T) {
	tests := []struct {
		provider string
		wantType string
	}{
		{"claude", "*ai.Client"},
		{"codex", "*codex.Client"},
		{"ollama", "*ollama.Client"},
		{"", "*ai.Client"},
	}
	for _, tt := range tests {
		t.Run("client/"+tt.provider, func(t *testing.T) {
			cfg := &config.Config{AI: config.AIConfig{Provider: tt.provider}}
			if got := fmt.Sprintf("%T", newAIClient(cfg, "")); got != tt.wantType {
				t.Errorf("newAIClient(%q) = %s, want %s", tt.provider, got, tt.wantType)
			}
		})
	}
}

// Runtime B: the ollama provider on a tool-bearing chat surface (--tools chat)
// is wired to the in-process agent loop; without it, the plain ollama client.
func TestNewQueryClientOllamaToolWiring(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "t.db")
	cfg := &config.Config{AI: config.AIConfig{Provider: "ollama"}}

	oldTools := aiFlagTools
	oldModel := aiFlagModel
	aiFlagModel = "llama"
	defer func() { aiFlagTools = oldTools; aiFlagModel = oldModel }()

	aiFlagTools = "chat"
	client, cleanup, err := newQueryClient(cfg, dbPath)
	require.NoError(t, err)
	defer cleanup()
	assert.Equal(t, "*agentloop.Client", fmt.Sprintf("%T", client), "ollama + --tools chat gets the runtime-B loop")

	aiFlagTools = ""
	plain, cleanup2, err := newQueryClient(cfg, dbPath)
	require.NoError(t, err)
	defer cleanup2()
	assert.Equal(t, "*ollama.Client", fmt.Sprintf("%T", plain), "ollama without tools stays the plain client")
}

// TestNewQueryClientWiresEnabledExternalConnections seeds one enabled
// external_connections row plus its secret file, runs the claude chat-mode
// wiring, and asserts the built ai.Client carries exactly that one
// ExternalMCPServer with decoded args + env.
func TestNewQueryClientWiresEnabledExternalConnections(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test-ws", AI: config.AIConfig{Provider: "claude"}}
	dbPath := cfg.DBPath()

	database, err := db.Open(dbPath)
	require.NoError(t, err)
	connID, err := database.InsertExternalConnection(db.ExternalConnection{
		Name:    "trello",
		Kind:    "stdio",
		Command: "npx",
		Args:    []string{"-y", "trello-mcp"},
		Enabled: true,
	})
	require.NoError(t, err)
	require.NoError(t, database.SetExternalConnectionTools(connID,
		[]db.ExternalTool{{Name: "list_boards"}, {Name: "create_card"}}, time.Now().UTC().Format(time.RFC3339)))
	require.NoError(t, externalmcp.NewSecretStore(cfg.WorkspaceDir(), connID).Save(&externalmcp.Secret{
		Env: map[string]string{"TRELLO_TOKEN": "abc"},
	}))
	require.NoError(t, database.Close())

	oldTools, oldModel := aiFlagTools, aiFlagModel
	aiFlagTools = "chat"
	aiFlagModel = ""
	defer func() { aiFlagTools = oldTools; aiFlagModel = oldModel }()

	client, cleanup, err := newQueryClient(cfg, dbPath)
	require.NoError(t, err)
	defer cleanup()

	c, ok := client.(*ai.Client)
	require.True(t, ok, "claude provider must build *ai.Client, got %T", client)

	servers := c.ExternalServersForTest()
	require.Len(t, servers, 1)
	assert.Equal(t, "trello", servers[0].Name)
	assert.Equal(t, "stdio", servers[0].Kind)
	assert.Equal(t, "npx", servers[0].Command)
	assert.Equal(t, []string{"-y", "trello-mcp"}, servers[0].Args)
	assert.Equal(t, map[string]string{"TRELLO_TOKEN": "abc"}, servers[0].Env)
	assert.Equal(t, []string{"list_boards"}, servers[0].AllowTools, "only the read-only tool is allowed (QC-02)")
	assert.Equal(t, []string{"create_card"}, servers[0].DenyTools)
}

// The automation editor chat (spec 2026-10-14 §14.5, D11) carries only
// draft_automation, save_automation and read tools: an automation_editor
// query mounts no Quick Connections server, while a main query still does.
func TestNewQueryClientSkipsExternalConnectionsOnAutomationEditor(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test-ws", AI: config.AIConfig{Provider: "claude"}}
	dbPath := cfg.DBPath()
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	connID, err := database.InsertExternalConnection(db.ExternalConnection{
		Name: "trello", Kind: "stdio", Command: "npx", Enabled: true,
	})
	require.NoError(t, err)
	require.NoError(t, database.SetExternalConnectionTools(connID,
		[]db.ExternalTool{{Name: "list_boards"}, {Name: "create_card"}}, time.Now().UTC().Format(time.RFC3339)))
	require.NoError(t, database.Close())

	oldTools, oldModel, oldSurface := aiFlagTools, aiFlagModel, aiFlagSurface
	defer func() { aiFlagTools, aiFlagModel, aiFlagSurface = oldTools, oldModel, oldSurface }()
	aiFlagTools, aiFlagModel = "chat", ""
	servers := func(surface string) []ai.ExternalMCPServer {
		aiFlagSurface = surface
		client, cleanup, err := newQueryClient(cfg, dbPath)
		require.NoError(t, err)
		defer cleanup()
		c, ok := client.(*ai.Client)
		require.True(t, ok, "claude provider must build *ai.Client, got %T", client)
		return c.ExternalServersForTest()
	}

	assert.Empty(t, servers(tools.AutomationEditorSurface), "no external server on automation_editor")
	assert.Len(t, servers("main"), 1, "main still mounts the owner's connections")
	assert.Len(t, servers("target"), 1, "target still mounts the owner's connections")
}

// TestNewQueryClientExternalConnectionsMissingTableDegradesGracefully makes
// sure a chat-mode client still builds cleanly (zero external servers, no
// error) when the DB has no external_connections rows at all — the common
// case for every install today.
func TestNewQueryClientExternalConnectionsMissingTableDegradesGracefully(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test-ws", AI: config.AIConfig{Provider: "claude"}}
	dbPath := cfg.DBPath()

	// Force the DB (and its migrated schema) to exist without seeding any
	// external_connections row.
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	require.NoError(t, database.Close())

	oldTools, oldModel := aiFlagTools, aiFlagModel
	aiFlagTools = "chat"
	aiFlagModel = ""
	defer func() { aiFlagTools = oldTools; aiFlagModel = oldModel }()

	client, cleanup, err := newQueryClient(cfg, dbPath)
	require.NoError(t, err)
	defer cleanup()

	c, ok := client.(*ai.Client)
	require.True(t, ok, "claude provider must build *ai.Client, got %T", client)
	assert.Empty(t, c.ExternalServersForTest())
}

// TestProviderOverrideDoesNotInheritConfiguredModels goes through the REAL
// override path: config.Load (which snapshots ConfiguredProvider) followed by
// applyProviderOverride mutating cfg.AI.Provider — the exact sequence every
// per-command --provider override (including Desktop chat's `ai query
// --provider codex` with Auto model) runs. The overridden provider must
// resolve to ITS registry defaults, not the yaml provider's configured
// models. This test fails when ResolveModelsFor compares against the mutated
// cfg.AI.Provider instead of the Load-time snapshot.
func TestProviderOverrideDoesNotInheritConfiguredModels(t *testing.T) {
	dir := t.TempDir()
	configPath := filepath.Join(dir, "config.yaml")
	configYAML := `active_workspace: test-ws
workspaces:
  test-ws:
    slack_token: "xoxp-test-token"
ai:
  provider: claude
  models:
    strong: claude-opus-4-6
    light: claude-haiku-4-5-20251001
`
	require.NoError(t, os.WriteFile(configPath, []byte(configYAML), 0o600))

	cfg, err := config.Load(configPath)
	require.NoError(t, err)

	oldFlag := flagProvider
	flagProvider = "codex"
	defer func() { flagProvider = oldFlag }()
	applyProviderOverride(cfg)
	require.Equal(t, "codex", cfg.AI.Provider)

	light, strong := providers.ResolveModelsFor(cfg, cfg.AI.Provider)
	assert.Equal(t, "gpt-6-luna", light, "override provider must get its own defaults")
	assert.Equal(t, "gpt-6-astra", strong, "a claude model must never leak into a codex session")

	// The yaml provider keeps its configured models (pinned full ids resolve
	// to their family alias).
	light, strong = providers.ResolveModelsFor(cfg, "claude")
	assert.Equal(t, "haiku", light)
	assert.Equal(t, "opus", strong)
}

// `ai query --no-tools` (the ⌘/ help chat) mounts no MCP server on claude or
// codex even though the CLI always knows a database path (the config's when
// the Desktop sends none); ollama's plain client has no tools at all.
func TestNewQueryClientNoToolsMountsNoMCP(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "owner.db")
	oldTools, oldModel, oldNoTools := aiFlagTools, aiFlagModel, aiFlagNoTools
	aiFlagTools, aiFlagModel, aiFlagNoTools = "", "m", true
	defer func() { aiFlagTools, aiFlagModel, aiFlagNoTools = oldTools, oldModel, oldNoTools }()

	type argser interface {
		ArgsForTest(systemPrompt, userMessage string) []string
	}
	for _, provider := range []string{"claude", "codex"} {
		t.Run(provider, func(t *testing.T) {
			cfg := &config.Config{AI: config.AIConfig{Provider: provider}}
			client, cleanup, err := newQueryClient(cfg, dbPath)
			require.NoError(t, err)
			defer cleanup()
			c, ok := client.(argser)
			require.True(t, ok, "%T", client)
			args := c.ArgsForTest("sys", "how do I add a source?")
			require.NotEmpty(t, args)
			assert.NotContains(t, args, "--mcp-config")
			assert.NotContains(t, args, "--allowedTools")
			for _, a := range args {
				assert.NotContains(t, a, dbPath)
				if a != "mcp_servers={}" { // codex: the owner's own servers cleared
					assert.NotContains(t, a, "mcp_servers")
				}
			}
		})
	}

	cfg := &config.Config{AI: config.AIConfig{Provider: "ollama"}}
	client, cleanup, err := newQueryClient(cfg, dbPath)
	require.NoError(t, err)
	defer cleanup()
	assert.Equal(t, "*ollama.Client", fmt.Sprintf("%T", client))
}
