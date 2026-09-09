package cmd

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/externalmcp"
	"watchtower/internal/providers"
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
	assert.Equal(t, "gpt-5.4-mini", light, "override provider must get its own defaults")
	assert.Equal(t, "gpt-5.4", strong, "a claude model must never leak into a codex session")

	// The yaml provider keeps its configured models.
	light, strong = providers.ResolveModelsFor(cfg, "claude")
	assert.Equal(t, "claude-haiku-4-5-20251001", light)
	assert.Equal(t, "claude-opus-4-6", strong)
}
