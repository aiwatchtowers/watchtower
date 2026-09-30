package cmd

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/digest"
)

const terminalTestSessionUUID = "3f2a1b4c-0000-4000-8000-0000000000aa"

func stubTerminalTitleGenerator(t *testing.T, gen digest.Generator) {
	t.Helper()
	old := terminalTitleGeneratorFactory
	t.Cleanup(func() { terminalTitleGeneratorFactory = old })
	terminalTitleGeneratorFactory = func(*config.Config) digest.Generator { return gen }
}

// seedTerminalSession inserts a claude session row and, when transcript is
// non-empty, a transcript under a temp claude dir wired into the seam.
func seedTerminalSession(t *testing.T, titleSource, kind, transcript string) int64 {
	t.Helper()
	d, err := db.Open(filepath.Join(os.Getenv("HOME"), ".local", "share", "watchtower", "test-ws", "watchtower.db"))
	require.NoError(t, err)
	defer d.Close()
	var sid any
	if kind == "claude" {
		sid = terminalTestSessionUUID
	}
	res, err := d.Exec(`INSERT INTO terminal_sessions (kind, title, title_source, folder_path, claude_session_id)
		VALUES (?, 'Session', ?, '/tmp/acme', ?)`, kind, titleSource, sid)
	require.NoError(t, err)
	id, err := res.LastInsertId()
	require.NoError(t, err)

	claudeDir := t.TempDir()
	old := terminalClaudeDir
	t.Cleanup(func() { terminalClaudeDir = old })
	terminalClaudeDir = func() string { return claudeDir }
	if transcript != "" {
		sub := filepath.Join(claudeDir, "projects", "-tmp-acme")
		require.NoError(t, os.MkdirAll(sub, 0o700))
		require.NoError(t, os.WriteFile(filepath.Join(sub, terminalTestSessionUUID+".jsonl"), []byte(transcript), 0o600))
	}
	return id
}

func runTerminalTitleCmd(t *testing.T, id int64) (map[string]any, error) {
	t.Helper()
	var buf bytes.Buffer
	terminalTitleCmd.SetOut(&buf)
	t.Cleanup(func() { terminalTitleCmd.SetOut(nil) })
	if err := terminalTitleCmd.RunE(terminalTitleCmd, []string{strconv.FormatInt(id, 10)}); err != nil {
		return nil, err
	}
	var out map[string]any
	require.NoError(t, json.Unmarshal(buf.Bytes(), &out))
	return out, nil
}

const terminalOwnerLine = `{"type":"user","message":{"role":"user","content":"fix the login redirect"}}`

func TestTerminalTitle_NoOwnerMessageMakesNoCall(t *testing.T) {
	defer setupWatchTestEnv(t)()
	gen := &chatTitleMockGen{reply: "x"}
	stubTerminalTitleGenerator(t, gen)
	for name, transcript := range map[string]string{
		"no transcript file": "",
		"no owner message":   `{"type":"mode","mode":"default"}`,
	} {
		id := seedTerminalSession(t, "auto", "claude", transcript)
		out, err := runTerminalTitleCmd(t, id)
		require.NoError(t, err, name)
		assert.Equal(t, "", out["title"], name)
		assert.Equal(t, false, out["written"], name)
	}
	assert.Zero(t, gen.calls)
}

func TestTerminalTitle_OwnerTitleIsNeverTouched(t *testing.T) {
	defer setupWatchTestEnv(t)()
	gen := &chatTitleMockGen{reply: "AI title"}
	stubTerminalTitleGenerator(t, gen)
	id := seedTerminalSession(t, "user", "claude", terminalOwnerLine)

	out, err := runTerminalTitleCmd(t, id)
	require.NoError(t, err)
	assert.Equal(t, "Session", out["title"])
	assert.Equal(t, false, out["written"])
	assert.Zero(t, gen.calls)
}

func TestTerminalTitle_ShellSessionIsLeftAlone(t *testing.T) {
	defer setupWatchTestEnv(t)()
	gen := &chatTitleMockGen{reply: "AI title"}
	stubTerminalTitleGenerator(t, gen)
	id := seedTerminalSession(t, "auto", "shell", "")

	out, err := runTerminalTitleCmd(t, id)
	require.NoError(t, err)
	assert.Equal(t, false, out["written"])
	assert.Zero(t, gen.calls)
}

func TestTerminalTitle_WritesAITitle(t *testing.T) {
	defer setupWatchTestEnv(t)()
	gen := &chatTitleMockGen{reply: "\"Fix login redirect.\"\n"}
	stubTerminalTitleGenerator(t, gen)
	id := seedTerminalSession(t, "auto", "claude", terminalOwnerLine)

	out, err := runTerminalTitleCmd(t, id)
	require.NoError(t, err)
	assert.Equal(t, "Fix login redirect", out["title"])
	assert.Equal(t, true, out["written"])
	assert.Equal(t, "terminal.title", gen.source)
	assert.Equal(t, "fix the login redirect", gen.lastMsg)

	d, err := db.Open(filepath.Join(os.Getenv("HOME"), ".local", "share", "watchtower", "test-ws", "watchtower.db"))
	require.NoError(t, err)
	defer d.Close()
	s, err := d.GetTerminalSession(id)
	require.NoError(t, err)
	assert.Equal(t, "Fix login redirect", s.Title)
	assert.Equal(t, "ai", s.TitleSource)
}

func TestTerminalTitle_UnknownIDFails(t *testing.T) {
	defer setupWatchTestEnv(t)()
	stubTerminalTitleGenerator(t, &chatTitleMockGen{})
	_, err := runTerminalTitleCmd(t, 9999)
	require.Error(t, err)
}

func TestTerminalTitle_UnknownClaudeDirIsAnError(t *testing.T) {
	defer setupWatchTestEnv(t)()
	gen := &chatTitleMockGen{reply: "x"}
	stubTerminalTitleGenerator(t, gen)
	id := seedTerminalSession(t, "auto", "claude", terminalOwnerLine)
	terminalClaudeDir = func() string { return "" }

	_, err := runTerminalTitleCmd(t, id)
	require.Error(t, err)
	assert.Zero(t, gen.calls)
}

// Both sides read transcripts from ~/.claude only (ClaudeTranscript.defaultConfigDir).
func TestTerminalClaudeDir_IgnoresClaudeConfigDir(t *testing.T) {
	t.Setenv("CLAUDE_CONFIG_DIR", "/tmp/acme-claude")
	home, err := os.UserHomeDir()
	require.NoError(t, err)
	assert.Equal(t, filepath.Join(home, ".claude"), defaultTerminalClaudeDir())
}

// TestChat04_TerminalTitleArgvCarriesNoContent pins CHAT-04 for `terminal
// title`: the production generator (terminalTitleGeneratorFactory) puts the
// owner's typed messages on stdin, never on the child's argv. A fake
// claude/codex binary records both; the real CLIs are never invoked.
func TestChat04_TerminalTitleArgvCarriesNoContent(t *testing.T) {
	const marker = "OWNER-SECRET-terminal-title-4b1e"
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
			gen := terminalTitleGeneratorFactory(cfg)
			reply, _, _, err := gen.Generate(digest.WithSource(context.Background(), "terminal.title"), "system", marker, "")
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
