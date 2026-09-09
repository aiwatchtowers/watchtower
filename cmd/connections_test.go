package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/externalmcp"
)

// writeConnectionsConfig points flagConfig at a temp workspace whose DB path
// lives under a temp HOME (the writeActionsConfig/writeFeaturesConfig
// precedent) and returns the resolved config for reading WorkspaceDir().
func writeConnectionsConfig(t *testing.T) *config.Config {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "config.yaml")
	require.NoError(t, os.WriteFile(configPath, []byte("active_workspace: test\n"), 0o600))
	original := flagConfig
	flagConfig = configPath
	t.Cleanup(func() { flagConfig = original })

	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	return cfg
}

// writeConnectionsConfigWithProvider is the writeConnectionsConfig precedent,
// but stamps ai.provider so ConfiguredProviderID() resolves to a specific
// value — used to exercise warnIfProviderIgnoresConnections under codex/ollama.
func writeConnectionsConfigWithProvider(t *testing.T, provider string) *config.Config {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	tmpDir := t.TempDir()
	configPath := filepath.Join(tmpDir, "config.yaml")
	configYAML := "active_workspace: test\nai:\n  provider: " + provider + "\n"
	require.NoError(t, os.WriteFile(configPath, []byte(configYAML), 0o600))
	original := flagConfig
	flagConfig = configPath
	t.Cleanup(func() { flagConfig = original })

	cfg, err := config.Load(configPath)
	require.NoError(t, err)
	return cfg
}

// runConnections executes the real "connections" command tree via rootCmd,
// the actions_test.go/runActions precedent, feeding stdin (if any) through
// rootCmd so it reaches InOrStdin() on the dispatched child command.
func runConnections(t *testing.T, stdin string, args ...string) (string, error) {
	t.Helper()
	var out bytes.Buffer
	rootCmd.SetOut(&out)
	rootCmd.SetErr(&out)
	rootCmd.SetIn(strings.NewReader(stdin))
	rootCmd.SetArgs(append([]string{"connections"}, args...))
	err := rootCmd.Execute()
	rootCmd.SetArgs(nil)
	rootCmd.SetIn(nil)
	resetConnectionsFlags()
	return out.String(), err
}

// runConnectionsSplit is runConnections with stdout and stderr captured in
// SEPARATE buffers, so a test can prove WHICH stream a line landed on — the
// combined buffer above cannot tell a stderr warning from a stdout one.
func runConnectionsSplit(t *testing.T, stdin string, args ...string) (stdout, stderr string, err error) {
	t.Helper()
	var outBuf, errBuf bytes.Buffer
	rootCmd.SetOut(&outBuf)
	rootCmd.SetErr(&errBuf)
	rootCmd.SetIn(strings.NewReader(stdin))
	rootCmd.SetArgs(append([]string{"connections"}, args...))
	err = rootCmd.Execute()
	rootCmd.SetArgs(nil)
	rootCmd.SetIn(nil)
	resetConnectionsFlags()
	return outBuf.String(), errBuf.String(), err
}

// resetConnectionsFlags clears the package-level cobra flag vars between
// invocations (the pflag-singleton gotcha shared by every connections test).
func resetConnectionsFlags() {
	connectionsFlagJSON = false
	connectionsAddFlagName = ""
	connectionsAddFlagKind = ""
	connectionsAddFlagCommand = ""
	connectionsAddFlagArgs = nil
	connectionsAddFlagURL = ""
	connectionsAddFlagSecretStdin = false
}

func TestConnections_AddListEnableDisableRemove(t *testing.T) {
	cfg := writeConnectionsConfig(t)

	secretJSON := `{"env":{"API_KEY":"s3cr3t"},"headers":{"X-Token":"tok"}}`
	out, err := runConnections(t, secretJSON,
		"add", "--name", "My-Server", "--kind", "stdio",
		"--command", "npx", "--arg", "-y", "--arg", "some-mcp-server",
		"--secret-stdin")
	require.NoError(t, err, out)
	assert.Contains(t, out, "Added connection")
	assert.Contains(t, out, "disabled")

	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })

	conns, err := database.ListExternalConnections()
	require.NoError(t, err)
	require.Len(t, conns, 1)
	added := conns[0]
	assert.Equal(t, "My-Server", added.Name)
	assert.Equal(t, "stdio", added.Kind)
	assert.Equal(t, "npx", added.Command)
	assert.Equal(t, []string{"-y", "some-mcp-server"}, added.Args)
	assert.False(t, added.Enabled, "add must create the row disabled — owner enables explicitly")

	secretPath := externalmcp.NewSecretStore(cfg.WorkspaceDir(), added.ID).Path()
	require.FileExists(t, secretPath, "secret-stdin must persist the secret via the SecretStore")
	sec, err := externalmcp.NewSecretStore(cfg.WorkspaceDir(), added.ID).Load()
	require.NoError(t, err)
	require.NotNil(t, sec)
	assert.Equal(t, "s3cr3t", sec.Env["API_KEY"])
	assert.Equal(t, "tok", sec.Headers["X-Token"])

	idArg := strconv.FormatInt(added.ID, 10)

	// enable
	out, err = runConnections(t, "", "enable", idArg)
	require.NoError(t, err, out)
	assert.Contains(t, out, "enabled")
	enabledConn, err := database.GetExternalConnection(added.ID)
	require.NoError(t, err)
	assert.True(t, enabledConn.Enabled)

	// list --json contains the name
	out, err = runConnections(t, "", "list", "--json")
	require.NoError(t, err, out)
	assert.Contains(t, out, "My-Server")
	assert.Contains(t, out, `"enabled": true`)

	// disable
	out, err = runConnections(t, "", "disable", idArg)
	require.NoError(t, err, out)
	assert.Contains(t, out, "disabled")
	disabledConn, err := database.GetExternalConnection(added.ID)
	require.NoError(t, err)
	assert.False(t, disabledConn.Enabled)

	// remove: row and secret file both gone
	out, err = runConnections(t, "", "remove", idArg)
	require.NoError(t, err, out)
	assert.Contains(t, out, "Removed connection")

	_, err = database.GetExternalConnection(added.ID)
	assert.Error(t, err, "row must be gone after remove")
	assert.NoFileExists(t, secretPath, "remove must best-effort delete the secret file")
}

func TestConnections_AddRejectsEmptyName(t *testing.T) {
	writeConnectionsConfig(t)
	out, err := runConnections(t, "", "add", "--name", "", "--kind", "stdio", "--command", "npx")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--name is required")
	_ = out
}

func TestConnections_AddStdioRequiresCommand(t *testing.T) {
	writeConnectionsConfig(t)
	_, err := runConnections(t, "", "add", "--name", "N", "--kind", "stdio")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--command is required")
}

func TestConnections_AddHTTPRequiresURL(t *testing.T) {
	writeConnectionsConfig(t)
	_, err := runConnections(t, "", "add", "--name", "N", "--kind", "http")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "--url is required")
}

func TestConnections_AddRejectsUnknownKind(t *testing.T) {
	writeConnectionsConfig(t)
	_, err := runConnections(t, "", "add", "--name", "N", "--kind", "carrier-pigeon")
	require.Error(t, err)
	assert.Contains(t, err.Error(), `--kind must be "stdio" or "http"`)
}

func TestConnections_AddRejectsUnsafeName(t *testing.T) {
	writeConnectionsConfig(t)

	// A comma would inject an extra --allowedTools token when joined as
	// mcp__<Name> (see buildArgs in internal/ai/client.go).
	_, err := runConnections(t, "", "add", "--name", "x,Bash", "--kind", "stdio", "--command", "npx")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "invalid")

	// A space is also rejected — only [A-Za-z0-9_-] is safe.
	_, err = runConnections(t, "", "add", "--name", "my server", "--kind", "stdio", "--command", "npx")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "invalid")
}

func TestConnections_AddRejectsReservedName(t *testing.T) {
	cfg := writeConnectionsConfig(t)

	// "watchtower" collides with the built-in MCP server key in
	// buildMCPConfig (map key collision) — rejected case-insensitively.
	_, err := runConnections(t, "", "add", "--name", "watchtower", "--kind", "stdio", "--command", "npx")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "reserved")

	_, err = runConnections(t, "", "add", "--name", "Watchtower", "--kind", "stdio", "--command", "npx")
	require.Error(t, err)
	assert.Contains(t, err.Error(), "reserved")

	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	conns, err := database.ListExternalConnections()
	require.NoError(t, err)
	assert.Empty(t, conns, "a rejected reserved name must create no row")
}

// TestConnectionsEnable_WarnsUnderNonClaudeProvider covers the provider-
// honesty warning: codex/ollama chats never wire external connections
// (codex.Client has no SetExternalMCPServers, ollama routes through runtime
// B), so enabling a connection under either is inert. The warning must not
// block the enable — the row still ends up Enabled either way.
func TestConnectionsEnable_WarnsUnderNonClaudeProvider(t *testing.T) {
	tests := []struct {
		name        string
		provider    string
		wantWarning bool
	}{
		{"ollama provider warns", "ollama", true},
		{"claude provider silent", "claude", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := writeConnectionsConfigWithProvider(t, tt.provider)

			out, err := runConnections(t, "", "add", "--name", "My-Server", "--kind", "stdio", "--command", "npx")
			require.NoError(t, err, out)

			database, err := db.Open(cfg.DBPath())
			require.NoError(t, err)
			t.Cleanup(func() { _ = database.Close() })
			conns, err := database.ListExternalConnections()
			require.NoError(t, err)
			require.Len(t, conns, 1)
			idArg := strconv.FormatInt(conns[0].ID, 10)

			// Re-run for "enable" with SPLIT stdout/stderr buffers so this
			// assertion only sees the enable output (not the add warning above)
			// AND can prove which stream the warning landed on.
			stdout, stderr, err := runConnectionsSplit(t, "", "enable", idArg)
			require.NoError(t, err, stdout+stderr)

			enabledConn, err := database.GetExternalConnection(conns[0].ID)
			require.NoError(t, err)
			assert.True(t, enabledConn.Enabled, "enable must still succeed regardless of provider")

			if tt.wantWarning {
				assert.Contains(t, stderr, "only")
				assert.Contains(t, stderr, "claude")
				assert.Contains(t, stderr, "My-Server")
				assert.NotContains(t, stdout, "warning", "the warning belongs on stderr, never stdout")
			} else {
				assert.Empty(t, stderr, "a claude provider must produce no warning at all")
			}
		})
	}
}

// TestConnectionsAdd_WarnsUnderNonClaudeProvider mirrors the enable case for
// "connections add" — non-claude warns (row still created disabled, as
// always), claude stays silent.
func TestConnectionsAdd_WarnsUnderNonClaudeProvider(t *testing.T) {
	tests := []struct {
		name        string
		provider    string
		wantWarning bool
	}{
		{"ollama provider warns", "ollama", true},
		{"claude provider silent", "claude", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := writeConnectionsConfigWithProvider(t, tt.provider)

			stdout, stderr, err := runConnectionsSplit(t, "", "add", "--name", "My-Server", "--kind", "stdio", "--command", "npx")
			require.NoError(t, err, stdout+stderr)

			database, err := db.Open(cfg.DBPath())
			require.NoError(t, err)
			t.Cleanup(func() { _ = database.Close() })
			conns, err := database.ListExternalConnections()
			require.NoError(t, err)
			require.Len(t, conns, 1)
			assert.False(t, conns[0].Enabled, "add must still create the row disabled regardless of provider")

			if tt.wantWarning {
				assert.Contains(t, stderr, "only")
				assert.Contains(t, stderr, "claude")
				assert.Contains(t, stderr, "My-Server")
				assert.NotContains(t, stdout, "warning", "the warning belongs on stderr, never stdout")
			} else {
				assert.Empty(t, stderr, "a claude provider must produce no warning at all")
			}
		})
	}
}

func TestConnections_AddHTTPWithoutSecretStdinCreatesNoSecretFile(t *testing.T) {
	cfg := writeConnectionsConfig(t)
	out, err := runConnections(t, "", "add", "--name", "Web-Tool", "--kind", "http", "--url", "https://example.com/mcp")
	require.NoError(t, err, out)

	database, err := db.Open(cfg.DBPath())
	require.NoError(t, err)
	t.Cleanup(func() { _ = database.Close() })
	conns, err := database.ListExternalConnections()
	require.NoError(t, err)
	require.Len(t, conns, 1)
	assert.Equal(t, "https://example.com/mcp", conns[0].URL)

	secretPath := externalmcp.NewSecretStore(cfg.WorkspaceDir(), conns[0].ID).Path()
	assert.NoFileExists(t, secretPath, "no --secret-stdin means no secret file at all")
}
