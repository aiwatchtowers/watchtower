package cmd

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
)

// readFolderFixture is a config whose claude is a stub that answers with its
// cwd and the flags it was given, a database, and one workbench bound to a
// folder.
type readFolderFixture struct {
	config string
	dbPath string
	folder string // resolved, as the workbench stores it
}

func newReadFolderFixture(t *testing.T) readFolderFixture {
	t.Helper()
	dir := t.TempDir()
	// The stub prints one v1 stream-json text event:
	// "<cwd>|<--disallowedTools>|<--setting-sources>|<--tools>".
	stub := filepath.Join(dir, "claude")
	require.NoError(t, os.WriteFile(stub, []byte(`#!/bin/sh
dis=""; src="unset"; tools="unset"
while [ $# -gt 0 ]; do
  case "$1" in
    --disallowedTools) dis="$2"; shift ;;
    --setting-sources) src="$2"; shift ;;
    --tools) tools="$2"; shift ;;
  esac
  shift
done
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s|%s|%s|%s"}]}}\n' "$(pwd -P)" "$dis" "$src" "$tools"
printf '{"type":"result","subtype":"success","result":"","session_id":"s1"}\n'
`), 0o755))

	config := filepath.Join(dir, "config.yaml")
	require.NoError(t, os.WriteFile(config, []byte(fmt.Sprintf(`active_workspace: test-ws
workspaces:
  test-ws:
    slack_token: "xoxp-test-token"
claude_path: %q
ai:
  provider: claude
`, stub)), 0o600))

	dbPath := filepath.Join(dir, "wt.db")
	database, err := db.Open(dbPath)
	require.NoError(t, err)
	folder, err := filepath.EvalSymlinks(t.TempDir())
	require.NoError(t, err)
	_, err = database.CreateWorkbench("acme", folder)
	require.NoError(t, err)
	require.NoError(t, database.Close())
	return readFolderFixture{config: config, dbPath: dbPath, folder: folder}
}

func (f readFolderFixture) run(t *testing.T, extra ...string) (code int, stdout []string, stderr string) {
	t.Helper()
	args := append([]string{"ai", "query", "--config", f.config, "--db-path", f.dbPath}, extra...)
	args = append(args, "--", "what does this do?")
	p := startCLI(t, args...)
	_ = p.stdin.Close()
	for line := range p.lines {
		stdout = append(stdout, line)
	}
	code = exitCode(p.wait())
	return code, stdout, p.stderr.String()
}

// TestAIQueryReadFolder_RefusesAFolderThatIsNoWorkbench: --read-folder takes
// only a workbench folder (exit 2, message on stderr, no provider started).
func TestAIQueryReadFolder_RefusesAFolderThatIsNoWorkbench(t *testing.T) {
	f := newReadFolderFixture(t)
	sub := filepath.Join(f.folder, "sub")
	require.NoError(t, os.Mkdir(sub, 0o755))

	for name, dir := range map[string]string{
		"unbound folder":   t.TempDir(),
		"workbench subdir": sub,
		"missing folder":   filepath.Join(f.folder, "gone"),
		"a file":           f.config,
	} {
		t.Run(name, func(t *testing.T) {
			code, stdout, stderr := f.run(t, "--read-folder", dir)
			assert.Equal(t, 2, code)
			assert.Contains(t, stderr, "--read-folder")
			assert.Empty(t, stdout, "no provider ran")
		})
	}
}

// A read-folder run never mounts the chat write tools.
func TestAIQueryReadFolder_RefusesToolsChat(t *testing.T) {
	f := newReadFolderFixture(t)
	code, stdout, stderr := f.run(t, "--read-folder", f.folder, "--tools", "chat")
	assert.Equal(t, 2, code)
	assert.Contains(t, stderr, "--tools")
	assert.Empty(t, stdout)
}

// TestAIQueryReadFolder_RunsClaudeInTheFolder: a workbench folder, named
// through a symlink, runs claude with cwd = the folder, the read tools
// allowed and unhidden and everything else still hidden, no settings files.
func TestAIQueryReadFolder_RunsClaudeInTheFolder(t *testing.T) {
	f := newReadFolderFixture(t)
	link := filepath.Join(t.TempDir(), "link")
	require.NoError(t, os.Symlink(f.folder, link))

	code, stdout, stderr := f.run(t, "--read-folder", link)
	require.Equal(t, 0, code, stderr)
	text := firstText(t, stdout)
	parts := strings.Split(text, "|")
	require.Len(t, parts, 4, text)
	assert.Equal(t, f.folder, parts[0], "cwd")
	disallowed := strings.Split(parts[1], ",")
	for _, tool := range []string{"Read", "Grep", "Glob", "LS"} {
		assert.NotContains(t, disallowed, tool)
	}
	for _, tool := range []string{"Edit", "Write", "Bash", "WebFetch", "WebSearch", "Task"} {
		assert.Contains(t, disallowed, tool)
	}
	assert.Empty(t, parts[2], "--setting-sources is empty")
	assert.Equal(t, "ToolSearch,Read,Grep,Glob,LS", parts[3], "the --tools allowlist adds only the reads")
}

// Without --read-folder the run is today's: temp-dir cwd, read tools hidden.
func TestAIQueryReadFolder_AbsentKeepsTodaysRun(t *testing.T) {
	f := newReadFolderFixture(t)
	code, stdout, stderr := f.run(t)
	require.Equal(t, 0, code, stderr)
	parts := strings.Split(firstText(t, stdout), "|")
	require.Len(t, parts, 4)
	assert.NotEqual(t, f.folder, parts[0])
	assert.Contains(t, strings.Split(parts[1], ","), "Read")
	assert.Equal(t, "project,local", parts[2])
	assert.Equal(t, "ToolSearch", parts[3])
}

// The codex provider gets the folder as its working root under the
// read-only sandbox; ollama has no file tools at all.
func TestAIQueryReadFolder_ProviderWiring(t *testing.T) {
	cfg := &config.Config{ActiveWorkspace: "test-ws", AI: config.AIConfig{Provider: "codex"}}
	codexClient := newAIClientWithModel(cfg, "", "gpt-5.4")
	_, ok := codexClient.(readFolderConfigurable)
	assert.True(t, ok, "codex reads the folder with its own tools")
	_, ok = newAIClientWithModel(&config.Config{AI: config.AIConfig{Provider: "claude"}}, "", "m").(readFolderConfigurable)
	assert.True(t, ok, "claude reads the folder with its own tools")
	_, ok = newAIClientWithModel(&config.Config{AI: config.AIConfig{Provider: "ollama"}}, "", "m").(readFolderConfigurable)
	assert.False(t, ok, "ollama has no file tools: a read-folder run answers from the prompt alone")
}

func firstText(t *testing.T, lines []string) string {
	t.Helper()
	for _, line := range lines {
		var ev aiStreamEvent
		require.NoError(t, json.Unmarshal([]byte(line), &ev), line)
		if ev.Type == "error" {
			t.Fatalf("error event: %s", ev.Error)
		}
		if ev.Type == "text" {
			return ev.Text
		}
	}
	t.Fatalf("no text event in %v", lines)
	return ""
}
