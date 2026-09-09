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
	connectionsFlagJSON = false
	connectionsAddFlagName = ""
	connectionsAddFlagKind = ""
	connectionsAddFlagCommand = ""
	connectionsAddFlagArgs = nil
	connectionsAddFlagURL = ""
	connectionsAddFlagSecretStdin = false
	return out.String(), err
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
