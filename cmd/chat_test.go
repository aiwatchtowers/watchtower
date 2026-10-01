package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

type chatTitleMockGen struct {
	reply   string
	calls   int
	source  string
	lastMsg string
	system  string
}

func (m *chatTitleMockGen) Generate(ctx context.Context, system, user, _ string) (string, *digest.Usage, string, error) {
	m.calls++
	m.system = system
	m.source, _ = digest.SourceFromContext(ctx)
	m.lastMsg = user
	return m.reply, &digest.Usage{}, "", nil
}

func stubChatTitleGenerator(t *testing.T, gen digest.Generator) {
	t.Helper()
	old := chatTitleGeneratorFactory
	t.Cleanup(func() { chatTitleGeneratorFactory = old })
	chatTitleGeneratorFactory = func(*config.Config) digest.Generator { return gen }
}

// seedTitleConversation opens the test workspace DB (setupWatchTestEnv) and
// inserts a conversation with the given title source and messages.
func seedTitleConversation(t *testing.T, titleSource string, msgs ...[2]string) int64 {
	t.Helper()
	d, err := db.Open(filepath.Join(os.Getenv("HOME"), ".local", "share", "watchtower", "test-ws", "watchtower.db"))
	require.NoError(t, err)
	defer d.Close()
	res, err := d.Exec(`INSERT INTO chat_conversations (title, title_source, created_at, updated_at) VALUES ('Mine', ?, 1, 1)`, titleSource)
	require.NoError(t, err)
	conv, err := res.LastInsertId()
	require.NoError(t, err)
	for _, m := range msgs {
		_, err := d.Exec(`INSERT INTO chat_messages (conversation_id, role, text, created_at) VALUES (?, ?, ?, 1)`, conv, m[0], m[1])
		require.NoError(t, err)
	}
	return conv
}

func runChatTitleCmd(t *testing.T, id int64) (map[string]any, error) {
	t.Helper()
	var buf bytes.Buffer
	chatTitleCmd.SetOut(&buf)
	t.Cleanup(func() { chatTitleCmd.SetOut(nil) })
	err := chatTitleCmd.RunE(chatTitleCmd, []string{strconv.FormatInt(id, 10)})
	if err != nil {
		return nil, err
	}
	var out map[string]any
	require.NoError(t, json.Unmarshal(buf.Bytes(), &out))
	return out, nil
}

func TestChatTitle_WritesAITitle(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	gen := &chatTitleMockGen{reply: "\"Payments rollout risks.\"\n"}
	stubChatTitleGenerator(t, gen)
	conv := seedTitleConversation(t, "prefix",
		[2]string{"user", "What could go wrong with the payments rollout?"},
		[2]string{"assistant", "Three risks: refunds, FX, and support load."})

	out, err := runChatTitleCmd(t, conv)
	require.NoError(t, err)
	assert.Equal(t, "Payments rollout risks", out["title"], "quotes and the trailing period are stripped")
	assert.Equal(t, true, out["written"])
	assert.Equal(t, "chat.title", gen.source, "tier routing hears the source tag")
	assert.Contains(t, gen.lastMsg, "Owner: What could go wrong with the payments rollout?")
	assert.Contains(t, gen.lastMsg, "Assistant: Three risks")

	d, err := db.Open(filepath.Join(os.Getenv("HOME"), ".local", "share", "watchtower", "test-ws", "watchtower.db"))
	require.NoError(t, err)
	defer d.Close()
	c, err := d.GetChatConversation(conv)
	require.NoError(t, err)
	assert.Equal(t, "Payments rollout risks", c.Title)
	assert.Equal(t, "ai", c.TitleSource)
}

func TestChatTitle_OwnerTitleIsNeverTouched(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	gen := &chatTitleMockGen{reply: "AI title"}
	stubChatTitleGenerator(t, gen)
	conv := seedTitleConversation(t, "user", [2]string{"user", "hi"})

	out, err := runChatTitleCmd(t, conv)
	require.NoError(t, err)
	assert.Equal(t, "Mine", out["title"])
	assert.Equal(t, false, out["written"])
	assert.Zero(t, gen.calls, "no AI call for an owner-named conversation")
}

func TestChatTitle_DegenerateInputs(t *testing.T) {
	cleanup := setupWatchTestEnv(t)
	defer cleanup()
	stubChatTitleGenerator(t, &chatTitleMockGen{reply: "  \n\n"})

	empty := seedTitleConversation(t, "prefix")
	_, err := runChatTitleCmd(t, empty)
	assert.ErrorContains(t, err, "no owner message")

	_, err = runChatTitleCmd(t, 999999)
	assert.ErrorContains(t, err, "not found")

	blank := seedTitleConversation(t, "prefix", [2]string{"user", "hi"})
	_, err = runChatTitleCmd(t, blank)
	assert.ErrorContains(t, err, "empty title")

	err = chatTitleCmd.RunE(chatTitleCmd, []string{"abc"})
	assert.ErrorContains(t, err, "invalid conversation id")
}

func TestCleanChatTitle(t *testing.T) {
	cases := map[string]string{
		"Payments rollout":           "Payments rollout",
		"# Title: Q3 plan.\n\nextra": "Q3 plan",
		"«Релиз платежей»":           "Релиз платежей",
		"**Vendor contract review**": "Vendor contract review",
		"":                           "",
		strings.Repeat("Долгое название ", 10): strings.TrimSpace(string([]rune(strings.Repeat("Долгое название ", 10))[:59])) + "…",
	}
	for in, want := range cases {
		assert.Equal(t, want, cleanChatTitle(in), in)
	}
}

func TestChatTitleIsLightTier(t *testing.T) {
	assert.Equal(t, digest.TierLight, digest.TierForSource("chat.title"))
}

// TestChat04_ChatTitleArgvCarriesNoContent pins CHAT-04 for `chat title`: the
// production generator the command uses (chatTitleGeneratorFactory) must put
// the owner's first exchange on stdin, never on the child's argv — even when
// it is far below digest.StdinThreshold. A fake claude/codex binary records
// its argv and stdin; the real CLIs are never invoked.
func TestChat04_ChatTitleArgvCarriesNoContent(t *testing.T) {
	const marker = "OWNER-SECRET-chat-title-7f3a"
	cases := []struct {
		provider string
		reply    string
	}{
		{"claude", `{"type":"result","result":"A title","is_error":false}`},
		{"codex", `{"type":"item.completed","item":{"type":"agent_message","text":"A title"}}`},
	}
	for _, tc := range cases {
		t.Run(tc.provider, func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			dir := t.TempDir()
			argvFile := filepath.Join(dir, "argv")
			stdinFile := filepath.Join(dir, "stdin")
			script := filepath.Join(dir, "fake-"+tc.provider)
			body := "#!/bin/sh\nprintf '%s\\n' \"$@\" > '" + argvFile + "'\ncat > '" + stdinFile + "'\necho '" + tc.reply + "'\n"
			require.NoError(t, os.WriteFile(script, []byte(body), 0o755))

			cfg := &config.Config{ClaudePath: script, CodexPath: script}
			cfg.AI.Provider = tc.provider
			cfg.AI.ConfiguredProvider = tc.provider
			gen := chatTitleGeneratorFactory(cfg)
			user := "=== FIRST EXCHANGE ===\nOwner: " + marker + "\n\nAssistant: ok"
			reply, _, _, err := gen.Generate(digest.WithSource(context.Background(), "chat.title"), "system", user, "")
			require.NoError(t, err)
			assert.Equal(t, "A title", reply)

			argv, err := os.ReadFile(argvFile)
			require.NoError(t, err)
			stdin, err := os.ReadFile(stdinFile)
			require.NoError(t, err)
			assert.NotContains(t, string(argv), marker, "owner text must never reach argv")
			assert.Contains(t, string(stdin), marker, "owner text must travel on stdin")
		})
	}
}
