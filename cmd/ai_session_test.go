package cmd

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	toml "github.com/pelletier/go-toml/v2"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/chat"
	"watchtower/internal/codex"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/externalmcp"
	"watchtower/internal/tools"
)

const fakeSessionClaude = `#!/bin/sh
while IFS= read -r line; do
  case "$line" in *'"type":"user"'*)
    printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello from fake"}}}'
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"hello from fake","session_id":"sess-e2e","usage":{"input_tokens":1,"output_tokens":1}}'
  ;; esac
done
`

func resetAISessionFlags(t *testing.T) {
	t.Helper()
	reset := func() {
		aiSessionFlagConversation, aiSessionFlagProjectID = 0, 0
		aiSessionFlagModel, aiSessionFlagResume, aiSessionFlagDBPath = "", "", ""
		aiSessionFlagSurface = "main"
	}
	reset()
	t.Cleanup(reset)
}

func TestAISession_RequiresConversation(t *testing.T) {
	resetAISessionFlags(t)
	aiSessionCmd.SetOut(io.Discard)
	err := aiSessionCmd.RunE(aiSessionCmd, nil)
	assert.ErrorContains(t, err, "--conversation")
}

func TestAISession_EndToEndWithFakeClaude(t *testing.T) {
	claudeAILoginEnv(t)
	fake := filepath.Join(t.TempDir(), "claude")
	require.NoError(t, os.WriteFile(fake, []byte(fakeSessionClaude), 0o755))
	r := startAISession(t, fake, "main")

	ready := r.next(chat.EventSessionReady)
	assert.Equal(t, "claude", ready.Provider)
	assert.NotEmpty(t, ready.Model)

	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "hi"})
	assert.Equal(t, "hello from fake", r.next(chat.EventTextDelta).Text)
	done1 := r.next(chat.EventTurnDone)
	assert.Equal(t, "sess-e2e", done1.SessionID)
	r.close()
}

// The memory block rides memory.surfaces.chat, and only while memory is on.
func TestAISession_PromptOptionsMemoryChatGate(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	cases := []struct {
		enabled, chat, want bool
	}{{true, true, true}, {true, false, false}, {false, true, false}, {false, false, false}}
	for _, c := range cases {
		cfg := &config.Config{ActiveWorkspace: "ws"}
		cfg.Memory.Enabled = c.enabled
		cfg.Memory.Surfaces.Chat = c.chat
		o := sessionPromptOptions(cfg, "target", 4, now, chat.ClaudeAIPrompt{})
		assert.Equal(t, c.want, o.MemoryChat, "enabled=%v chat=%v", c.enabled, c.chat)
		assert.Equal(t, "target", o.Surface)
		assert.Equal(t, int64(4), o.ProjectID)
		assert.True(t, o.ToolsAvailable)
		assert.Equal(t, now, o.Now)
	}
}

// Web search is promised in the prompt only where the backend exposes it:
// the Claude session (SessionDisallowedTools); codex/ollama have no WebSearch.
func TestAISession_PromptOptionsWebSearchOnlyForClaude(t *testing.T) {
	for p, want := range map[string]bool{"": true, "claude": true, "codex": false, "ollama": false} {
		cfg := &config.Config{ActiveWorkspace: "ws"}
		cfg.AI.Provider = p
		assert.Equal(t, want, sessionPromptOptions(cfg, "main", 0, time.Now(), chat.ClaudeAIPrompt{}).WebSearch, "provider %q", p)
	}
}

func TestNewSessionBackend_EveryProviderHasABackend(t *testing.T) {
	database := db.OpenTestDB(t)
	conv := &db.ChatConversation{ID: 1}
	for _, p := range []string{"claude", "codex", "ollama"} {
		cfg := &config.Config{}
		cfg.AI.Provider = p
		b, err := newSessionBackend(sessionWiring{
			cfg: cfg, database: database, dbPath: ":memory:", conv: conv, model: "m", prompt: "p",
			turnFile: filepath.Join(t.TempDir(), "turn"),
		})
		require.NoError(t, err, p)
		require.NotNil(t, b, p)
	}
}

// assertChatServerArgs: the watchtower server a codex chat mounts is a chat
// server — never the workbench one, never the automation surface without
// its run binding.
func assertChatServerArgs(t *testing.T, label string, argv []string) {
	t.Helper()
	var override string
	for _, a := range argv {
		if strings.HasPrefix(a, "mcp_servers=") {
			override = a
		}
	}
	var cfg struct {
		MCPServers map[string]struct {
			Args []string `toml:"args"`
		} `toml:"mcp_servers"`
	}
	require.NoError(t, toml.Unmarshal([]byte(override), &cfg), label)
	args := cfg.MCPServers["watchtower"].Args
	require.Contains(t, args, "--chat", label)
	assert.NotContains(t, args, "--workbench", label)
	for i, a := range args {
		if a == "--surface" && i+1 < len(args) && args[i+1] == "automation" {
			assert.Contains(t, args, "--automation-run", label)
		}
	}
}

// Both codex chat call sites — the session (sessionMCPArgs) and `ai query
// --tools chat` (chatMCPArgs) — mount a chat server only.
func TestCodexChatMountsOnlyAChatServer(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CODEX_HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test-ws", AI: config.AIConfig{Provider: "codex"}}
	dbPath := cfg.DBPath()
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	for _, surface := range []string{"main", "target"} {
		conv := &db.ChatConversation{ID: 7, ContextType: "target", ContextID: "3"}
		c := codexSessionClient(sessionWiring{cfg: cfg, database: database, dbPath: dbPath, model: "m",
			mcpArgs: sessionMCPArgs(surface, conv, filepath.Join(t.TempDir(), "turn"), 2)})
		assertChatServerArgs(t, "session "+surface, c.ArgsForTest("sys", "msg"))
	}

	oldTools, oldModel, oldSurface := aiFlagTools, aiFlagModel, aiFlagSurface
	defer func() { aiFlagTools, aiFlagModel, aiFlagSurface = oldTools, oldModel, oldSurface }()
	aiFlagTools, aiFlagModel = "chat", "m"
	for _, surface := range []string{"main", "target", tools.AutomationEditorSurface} {
		aiFlagSurface = surface
		client, cleanup, err := newQueryClient(cfg, dbPath)
		require.NoError(t, err)
		c, ok := client.(*codex.Client)
		require.True(t, ok, "%T", client)
		assertChatServerArgs(t, "query "+surface, c.ArgsForTest("sys", "msg"))
		cleanup()
	}
}

// The codex chat session (board #594) mounts the enabled Quick Connections
// next to the watchtower server, limited to their allowed tools (QC-02),
// and re-reads them on every launch (QC-04) — a connection enabled after
// the session started is there on the next turn.
func TestCodexSessionClient_MountsConnectionsPerLaunch(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CODEX_HOME", t.TempDir())
	cfg := &config.Config{ActiveWorkspace: "test-ws", AI: config.AIConfig{Provider: "codex"}}
	dbPath := cfg.DBPath()
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	c := codexSessionClient(sessionWiring{cfg: cfg, database: database, dbPath: dbPath, model: "m",
		mcpArgs: []string{"--chat", "--surface", "main"}})
	override := func() string {
		for _, a := range c.ArgsForTest("sys", "msg") {
			if strings.HasPrefix(a, "mcp_servers=") {
				return a
			}
		}
		return ""
	}
	assert.NotContains(t, override(), `"trello"`)

	id, err := database.InsertExternalConnection(db.ExternalConnection{Name: "trello", Kind: "stdio", Command: "npx", Enabled: true})
	require.NoError(t, err)
	require.NoError(t, database.SetExternalConnectionTools(id,
		[]db.ExternalTool{{Name: "list_boards"}, {Name: "create_card"}}, time.Now().UTC().Format(time.RFC3339)))
	got := override()
	assert.Contains(t, got, `"trello"={command="npx"`)
	assert.Contains(t, got, `enabled_tools=["list_boards"]`)
	assert.Contains(t, got, `"--surface","main"`)

	// A connection codex cannot mount (its variable would reconfigure
	// codex) is left out before its tools are touched — it was never
	// listed, and a listing would have failed in cmd tests — and its row
	// says why, turn after turn, never flipping to ok in between.
	bad, err := database.InsertExternalConnection(db.ExternalConnection{Name: "clash", Kind: "stdio", Command: "srv", Enabled: true})
	require.NoError(t, err)
	require.NoError(t, externalmcp.NewSecretStore(cfg.WorkspaceDir(), bad).Save(
		&externalmcp.Secret{Env: map[string]string{"HTTPS_PROXY": "http://proxy.example.com:3128"}}))
	for range 2 {
		assert.NotContains(t, override(), `"clash"`)
		row, err := database.GetExternalConnection(bad)
		require.NoError(t, err)
		assert.Equal(t, "error", row.Status)
		assert.Contains(t, row.Error, "not available in the codex chat: its variable HTTPS_PROXY")
		assert.False(t, row.ToolsListed, "its tools were never listed")
	}
}

// Ollama has no default model; an unset one refuses the session up front
// (mapped to provider_unavailable by the caller) instead of failing every
// turn as a retryable internal error.
func TestNewSessionBackend_OllamaWithoutAModelIsRefused(t *testing.T) {
	cfg := &config.Config{}
	cfg.AI.Provider = "ollama"
	b, err := newSessionBackend(sessionWiring{
		cfg: cfg, database: db.OpenTestDB(t), dbPath: ":memory:", conv: &db.ChatConversation{ID: 1}, prompt: "p",
		turnFile: filepath.Join(t.TempDir(), "turn"),
	})
	require.Error(t, err)
	assert.Nil(t, b)
	assert.Contains(t, err.Error(), "Ollama model")
}

// TestClaudeSessionOptions_QC02PerToolAllowlist: the warm session — the main
// chat — grants external tools one by one exactly like the one-shot client,
// never a whole server, and hides the denied ones.
func TestClaudeSessionOptions_QC02PerToolAllowlist(t *testing.T) {
	ext := []ai.ExternalMCPServer{{Name: "acme", Kind: "http", URL: "https://example.com/mcp",
		AllowTools: []string{"getIssue"}, DenyTools: []string{"createIssue"}}}
	opts := claudeSessionOptions(sessionWiring{cfg: &config.Config{}, dbPath: "/tmp/wt.db",
		conv: &db.ChatConversation{}}, ext)

	assert.Equal(t, "mcp__watchtower,mcp__acme__getIssue,"+ai.WebSearchTool, opts.AllowedTools)
	assert.Equal(t, ai.SessionDisallowedTools+",mcp__acme__createIssue", opts.DisallowedTools)
	assert.Equal(t, ai.SessionBuiltinTools, opts.Tools, "built-in allowlist: ToolSearch + WebSearch only")
	for tok := range strings.SplitSeq(opts.AllowedTools, ",") {
		assert.NotEqual(t, "mcp__acme", tok, "the whole server must never be granted")
	}
}

// The warm claude session fences its Quick Connections in the system prompt
// as external server data (board #556); without one the prompt is unchanged.
func TestClaudeSessionOptions_FencesExternalServersInPrompt(t *testing.T) {
	w := sessionWiring{cfg: &config.Config{}, dbPath: "/tmp/wt.db", conv: &db.ChatConversation{}, prompt: "sys"}
	assert.Equal(t, "sys", claudeSessionOptions(w, nil).SystemPrompt)
	ext := []ai.ExternalMCPServer{{Name: "acme", Kind: "http", URL: "https://example.com/mcp", AllowTools: []string{"getIssue"}}}
	assert.Equal(t, "sys\n\n"+ai.ExternalDataRule(ext), claudeSessionOptions(w, ext).SystemPrompt)
}
