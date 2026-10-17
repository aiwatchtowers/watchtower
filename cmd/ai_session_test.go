package cmd

import (
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/chat"
	"watchtower/internal/config"
	"watchtower/internal/db"
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
