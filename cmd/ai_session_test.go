package cmd

import (
	"bufio"
	"encoding/json"
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
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	resetAISessionFlags(t)

	fake := filepath.Join(t.TempDir(), "claude")
	require.NoError(t, os.WriteFile(fake, []byte(fakeSessionClaude), 0o755))
	f, err := os.OpenFile(flagConfig, os.O_APPEND|os.O_WRONLY, 0)
	require.NoError(t, err)
	_, err = f.WriteString("claude_path: " + fake + "\n")
	require.NoError(t, err)
	require.NoError(t, f.Close())

	dbPath := filepath.Join(os.Getenv("HOME"), ".local", "share", "watchtower", "test-ws", "watchtower.db")
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	res, err := database.Exec(`INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 1, 1)`)
	require.NoError(t, err)
	convID, err := res.LastInsertId()
	require.NoError(t, err)
	require.NoError(t, database.Close())

	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	aiSessionCmd.SetIn(inR)
	aiSessionCmd.SetOut(outW)
	t.Cleanup(func() { aiSessionCmd.SetIn(nil); aiSessionCmd.SetOut(nil) })
	aiSessionFlagConversation = convID

	done := make(chan error, 1)
	go func() {
		err := aiSessionCmd.RunE(aiSessionCmd, nil)
		_ = outW.Close()
		done <- err
	}()

	events := make(chan chat.Event, 64)
	go func() {
		sc := bufio.NewScanner(outR)
		for sc.Scan() {
			var e chat.Event
			if json.Unmarshal(sc.Bytes(), &e) == nil {
				events <- e
			}
		}
		close(events)
	}()
	next := func(want string) chat.Event {
		t.Helper()
		deadline := time.After(20 * time.Second)
		for {
			select {
			case e, ok := <-events:
				require.True(t, ok, "stream ended before %s", want)
				if e.Type == want {
					return e
				}
			case <-deadline:
				t.Fatalf("no %s event", want)
			}
		}
	}

	ready := next(chat.EventSessionReady)
	assert.Equal(t, "claude", ready.Provider)
	assert.NotEmpty(t, ready.Model)

	cmdLine, err := json.Marshal(chat.Command{Type: chat.CommandTurn, TurnID: "t1", Text: "hi"})
	require.NoError(t, err)
	_, err = inW.Write(append(cmdLine, '\n'))
	require.NoError(t, err)
	assert.Equal(t, "hello from fake", next(chat.EventTextDelta).Text)
	done1 := next(chat.EventTurnDone)
	assert.Equal(t, "sess-e2e", done1.SessionID)

	_, err = inW.Write([]byte(`{"type":"close"}` + "\n"))
	require.NoError(t, err)
	select {
	case err := <-done:
		assert.NoError(t, err)
	case <-time.After(15 * time.Second):
		t.Fatal("ai session did not exit after close")
	}
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
		o := sessionPromptOptions(cfg, "target", 4, now)
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
		assert.Equal(t, want, sessionPromptOptions(cfg, "main", 0, time.Now()).WebSearch, "provider %q", p)
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
	for _, tok := range strings.Split(opts.AllowedTools, ",") {
		assert.NotEqual(t, "mcp__acme", tok, "the whole server must never be granted")
	}
}
