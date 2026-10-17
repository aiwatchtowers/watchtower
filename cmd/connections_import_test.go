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
// config with the given content.
func writeImportSources(t *testing.T, codexTOML, claudeJSON string) {
	t.Helper()
	home := os.Getenv("HOME")
	t.Setenv("CODEX_HOME", "")
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	require.NoError(t, os.MkdirAll(filepath.Join(home, ".codex"), 0o700))
	require.NoError(t, os.WriteFile(filepath.Join(home, ".codex", "config.toml"), []byte(codexTOML), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(home, ".claude.json"), []byte(claudeJSON), 0o600))
}

// `connections import --json` lists what the owner's codex and Claude Code
// configs offer; importing names adds each as an enabled connection with its
// secret only in the 0600 secret file, lists its tools, and flags an http
// server with no headers whose listing failed for an OAuth sign-in. A name
// that is already a connection is offered no more.
func TestConnectionsImport_ListAndImport(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	writeImportSources(t,
		"[mcp_servers.tracker]\ncommand = \"npx\"\nargs = [\"-y\", \"tracker-mcp\"]\nenv = { TRACKER_TOKEN = \"tok-1\" }\n",
		`{"mcpServers":{"notes":{"type":"http","url":"https://notes.example.com/mcp"},"legacy":{"type":"sse","url":"https://legacy.example.com/sse"}}}`)
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
	require.Len(t, list.Servers, 3)
	assert.Equal(t, "tracker", list.Servers[0].Name)
	assert.True(t, list.Servers[0].HasSecret)
	assert.NotContains(t, stdout, "tok-1", "the list never prints a secret")
	assert.Contains(t, list.Servers[1].Skip, "sse")

	stdout, stderr, err = runConnectionsSplit(t, "", "import", "--json", "tracker", "notes", "legacy", "nope")
	require.NoError(t, err, stderr)
	var results []connectionImportResultJSON
	require.NoError(t, json.Unmarshal([]byte(stdout), &results), stdout)
	require.Len(t, results, 4)

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
	assert.Contains(t, results[3].Error, "not found")

	stdout, _, err = runConnectionsSplit(t, "", "import", "--json")
	require.NoError(t, err)
	require.NoError(t, json.Unmarshal([]byte(stdout), &list), stdout)
	assert.Contains(t, list.Servers[0].Skip, "already exists")
}
