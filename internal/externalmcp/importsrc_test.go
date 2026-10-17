package externalmcp

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

const importCodexTOML = `model = "gpt-x"

[mcp_servers.tracker]
command = "npx"
args = ["-y", "tracker-mcp"]
env = { TRACKER_TOKEN = "tok-1" }
env_vars = ["TRACKER_ORG", { name = "TRACKER_REGION", source = "local" }]

[mcp_servers.notes]
url = "https://notes.example.com/mcp"
bearer_token_env_var = "NOTES_TOKEN"

[mcp_servers.needs-var]
command = "srv"
env_vars = ["UNSET_VAR"]

[mcp_servers.in-folder]
command = "srv"
cwd = "/srv"

[mcp_servers.paused]
command = "srv"
enabled = false

[mcp_servers.odd]
command = "srv"
args = "not-a-list"

[mcp_servers.watchtower]
command = "/usr/local/bin/watchtower"
args = ["mcp"]
`

const importClaudeJSON = `{
  "numStartups": 3,
  "mcpServers": {
    "tracker": {"command": "npx", "args": ["-y", "tracker-mcp"]},
    "notes": {"type": "http", "url": "https://other.example.com/mcp"},
    "wiki.docs": {"type": "http", "url": "https://wiki.example.com/mcp", "headers": {"Authorization": "Bearer ${WIKI_TOKEN}"}},
    "legacy": {"type": "sse", "url": "https://legacy.example.com/sse"},
    "plain": {"type": "http", "url": "http://mcp.example.com/mcp", "headers": {"X-Key": "${MISSING:-k1}"}},
    "home": {"command": "${HOME_BIN}/srv"},
    "broken": {"command": 7}
  },
  "projects": {"/x": {"mcpServers": {"project-only": {"command": "p"}}}}
}`

func writeImportFixtures(t *testing.T) (string, string) {
	t.Helper()
	dir := t.TempDir()
	codex := filepath.Join(dir, "config.toml")
	claude := filepath.Join(dir, ".claude.json")
	require.NoError(t, os.WriteFile(codex, []byte(importCodexTOML), 0o600))
	require.NoError(t, os.WriteFile(claude, []byte(importClaudeJSON), 0o600))
	return codex, claude
}

func importEnv(k string) string {
	return map[string]string{"TRACKER_ORG": "acme", "TRACKER_REGION": "eu", "NOTES_TOKEN": "nt-1", "WIKI_TOKEN": "wk-1"}[k]
}

func TestDiscoverImports(t *testing.T) {
	codex, claude := writeImportFixtures(t)
	got, warnings := DiscoverImports(codex, claude, importEnv)
	assert.Empty(t, warnings)
	byName := map[string]ImportCandidate{}
	var names []string
	for _, c := range got {
		byName[c.Name] = c
		names = append(names, c.Name)
	}
	// codex first (sorted), then Claude: the same tracker server is not
	// offered twice, a different "notes" gets a suffix, project scopes are
	// ignored.
	assert.Equal(t, []string{"in-folder", "needs-var", "notes", "odd", "paused", "tracker", "watchtower",
		"broken", "home", "legacy", "notes-2", "plain", "wiki-docs"}, names)

	tr := byName["tracker"]
	assert.Equal(t, "codex", tr.Source)
	assert.Equal(t, "stdio", tr.Kind)
	assert.True(t, tr.Enabled)
	assert.Empty(t, tr.Skip)
	assert.True(t, tr.HasSecret)
	assert.Equal(t, map[string]string{"TRACKER_TOKEN": "tok-1", "TRACKER_ORG": "acme", "TRACKER_REGION": "eu"}, tr.Secret.Env)

	nt := byName["notes"]
	assert.Equal(t, "http", nt.Kind)
	assert.Empty(t, nt.Skip)
	assert.Equal(t, map[string]string{"Authorization": "Bearer nt-1"}, nt.Secret.Headers)

	assert.Contains(t, byName["needs-var"].Skip, "$UNSET_VAR")
	assert.Contains(t, byName["in-folder"].Skip, "cwd")
	assert.Contains(t, byName["watchtower"].Skip, "Watchtower's own server")
	assert.Contains(t, byName["odd"].Skip, "could not be read", "one odd server does not drop the file")
	assert.Contains(t, byName["broken"].Skip, "could not be read")
	assert.False(t, byName["paused"].Enabled, "a server the owner turned off imports disabled")
	assert.Empty(t, byName["paused"].Skip)

	wk := byName["wiki-docs"]
	assert.Empty(t, wk.Skip)
	assert.Equal(t, "claude", wk.Source)
	assert.Contains(t, wk.Note, `renamed from "wiki.docs"`)
	assert.Equal(t, map[string]string{"Authorization": "Bearer wk-1"}, wk.Secret.Headers)

	nc := byName["notes-2"]
	assert.Empty(t, nc.Skip)
	assert.Contains(t, nc.Note, "notes is taken")
	assert.False(t, nc.HasSecret)
	assert.Nil(t, nc.Secret)

	assert.Contains(t, byName["legacy"].Skip, "sse")
	assert.Contains(t, byName["home"].Skip, "$HOME_BIN")
	// A default fills the header; the transport rule is the cmd layer's.
	assert.Equal(t, map[string]string{"X-Key": "k1"}, byName["plain"].Secret.Headers)
}

func TestDiscoverImports_MissingAndBrokenFiles(t *testing.T) {
	dir := t.TempDir()
	got, warnings := DiscoverImports(filepath.Join(dir, "none.toml"), filepath.Join(dir, "none.json"), importEnv)
	assert.Empty(t, got)
	assert.Empty(t, warnings)

	codex, _ := writeImportFixtures(t)
	broken := filepath.Join(dir, ".claude.json")
	require.NoError(t, os.WriteFile(broken, []byte("{not json"), 0o600))
	got, warnings = DiscoverImports(codex, broken, importEnv)
	assert.Len(t, warnings, 1, "a broken Claude config is a warning")
	assert.Len(t, got, 7, "the codex servers still count")
}
