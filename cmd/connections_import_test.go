package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/codex"
	"watchtower/internal/db"
	"watchtower/internal/externalmcp"
)

// The codex client mounts Quick Connections (board #594), so newQueryClient
// and the codex session hand them over.
var _ externalMCPConfigurable = (*codex.Client)(nil)

// writeImportSources gives the test HOME a codex config and a Claude Code
// config (under CLAUDE_CONFIG_DIR) with the given content, and a login
// shell environment holding shellEnv.
func writeImportSources(t *testing.T, codexTOML, claudeJSON string, shellEnv map[string]string) {
	t.Helper()
	home := os.Getenv("HOME")
	claudeDir := t.TempDir()
	t.Setenv("CODEX_HOME", "")
	t.Setenv("CLAUDE_CONFIG_DIR", claudeDir)
	require.NoError(t, os.MkdirAll(filepath.Join(home, ".codex"), 0o700))
	require.NoError(t, os.WriteFile(filepath.Join(home, ".codex", "config.toml"), []byte(codexTOML), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(claudeDir, ".claude.json"), []byte(claudeJSON), 0o600))
	orig := loginShellEnv
	loginShellEnv = func() map[string]string { return shellEnv }
	t.Cleanup(func() { loginShellEnv = orig })
}

// `connections import --json` lists what the owner's codex and Claude Code
// configs offer; importing names adds each as a connection with its secret
// only in the 0600 secret file, enables it (lists its tools) unless its
// config turned it off, and flags an http server with no headers whose
// listing failed for an OAuth sign-in. A variable missing here is read from
// the login shell; headers to a remote plain-http URL and a non-http URL
// are refused as `connections add` refuses them; a name that is already a
// connection is offered no more.
func TestConnectionsImport_ListAndImport(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	writeImportSources(t,
		"[mcp_servers.tracker]\ncommand = \"npx\"\nargs = [\"-y\", \"tracker-mcp\"]\nenv_vars = [\"TRACKER_TOKEN\"]\n"+
			"[mcp_servers.paused]\ncommand = \"srv\"\nenabled = false\n",
		`{"mcpServers":{"notes":{"type":"http","url":"https://notes.example.com/mcp"},`+
			`"legacy":{"type":"sse","url":"https://legacy.example.com/sse"},`+
			`"plain":{"type":"http","url":"http://mcp.example.com/mcp","headers":{"X-Key":"k"}},`+
			`"weird":{"type":"http","url":"ftp://files.example.com/mcp"}}}`,
		map[string]string{"TRACKER_TOKEN": "tok-1"})
	orig := listServerTools
	listServerTools = func(_ context.Context, spec externalmcp.ServerSpec) ([]db.ExternalTool, error) {
		if spec.Kind == "http" {
			return nil, errors.New("401 unauthorized")
		}
		return []db.ExternalTool{{Name: "list_items", ReadOnlyHint: true}}, nil
	}
	t.Cleanup(func() { listServerTools = orig })

	stdout, stderr, err := runConnectionsSplit(t, "", "import", "--json")
	require.NoError(t, err, stderr)
	var list connectionImportListJSON
	require.NoError(t, json.Unmarshal([]byte(stdout), &list), stdout)
	byName := map[string]externalmcp.ImportCandidate{}
	for _, s := range list.Servers {
		byName[s.Name] = s
	}
	require.Len(t, byName, 6)
	assert.True(t, byName["tracker"].HasSecret)
	assert.Empty(t, byName["tracker"].Skip, "the login shell's variable resolves the server")
	assert.NotContains(t, stdout, "tok-1", "the list never prints a secret")
	assert.False(t, byName["paused"].Enabled)
	assert.Contains(t, byName["legacy"].Skip, "sse")
	assert.Contains(t, byName["plain"].Skip, "https")
	assert.Contains(t, byName["weird"].Skip, "not an http(s) URL")

	stdout, stderr, err = runConnectionsSplit(t, "", "import", "--json", "--", "tracker", "notes", "legacy", "paused", "nope")
	require.NoError(t, err, stderr)
	var results []connectionImportResultJSON
	require.NoError(t, json.Unmarshal([]byte(stdout), &results), stdout)
	require.Len(t, results, 5)

	tr := results[0]
	assert.Equal(t, "ok", tr.Status, tr.Error)
	assert.False(t, tr.SignIn)
	d, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	conn, err := d.GetExternalConnection(tr.ID)
	require.NoError(t, err)
	assert.True(t, conn.Enabled)
	assert.Equal(t, []string{"-y", "tracker-mcp"}, conn.Args)
	sec, err := externalmcp.NewSecretStore(cfg.WorkspaceDir(), tr.ID).Load()
	require.NoError(t, err)
	assert.Equal(t, "tok-1", sec.Env["TRACKER_TOKEN"])

	assert.NotZero(t, results[1].ID)
	assert.True(t, results[1].SignIn, "an http server with no headers that cannot list needs a sign-in")
	assert.Zero(t, results[2].ID)
	assert.Contains(t, results[2].Error, "sse")
	paused, err := d.GetExternalConnection(results[3].ID)
	require.NoError(t, err)
	assert.False(t, paused.Enabled, "a server its config turned off is imported disabled")
	assert.Equal(t, "disabled", results[3].Status)
	assert.Contains(t, results[4].Error, "not found")

	stdout, _, err = runConnectionsSplit(t, "", "import", "--json")
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal([]byte(stdout), &list), stdout)
	for _, s := range list.Servers {
		if s.Name == "tracker" {
			assert.Contains(t, s.Skip, "already exists")
		}
	}
}
