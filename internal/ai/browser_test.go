package ai

import (
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/connectwire"
)

var updateGolden = flag.Bool("update", false, "rewrite the golden files")

// connectClient is a connect run's client: the watchtower server in
// connect mode with the run's socket and token passed through.
func connectClient(browser bool) *Client {
	c := NewClient("sonnet", "/tmp/wt.db", "")
	c.SetMCPArgs([]string{"--connect", "slack"})
	c.SetMCPEnvVars([]string{connectwire.SocketEnv, connectwire.TokenEnv})
	c.SetBrowser(browser)
	c.SetBrowserHosts([]string{"api.slack.com", "app.slack.com"})
	return c
}

func count(args []string, s string) int {
	n := 0
	for _, a := range args {
		if a == s {
			n++
		}
	}
	return n
}

// TestClaudeArgs_BrowserOnlyWhenSet: SetBrowser(true) adds --chrome once,
// the browser tools to --allowedTools, S2's deny list and the navigate
// guard; a default client has none of them. The connect argv is pinned in
// testdata/connect_argv.golden (-update rewrites it).
func TestClaudeArgs_BrowserOnlyWhenSet(t *testing.T) {
	t.Setenv(connectwire.SocketEnv, "/tmp/connect.sock")
	t.Setenv(connectwire.TokenEnv, "tok-sample")

	on, _, _ := connectClient(true).buildArgs("sys", "hi", "stream-json")
	assert.Equal(t, 1, count(on, "--chrome"))
	assert.Contains(t, strings.Split(flagValue(t, on, "--allowedTools"), ","), BrowserToolsToken)
	disallowed := strings.Split(flagValue(t, on, "--disallowedTools"), ",")
	for _, tool := range strings.Split(BrowserDeniedTools, ",") {
		assert.Contains(t, disallowed, tool)
	}
	var settings struct {
		Hooks struct {
			PreToolUse []struct {
				Matcher string `json:"matcher"`
				Hooks   []struct {
					Type, Command string
				} `json:"hooks"`
			} `json:"PreToolUse"`
		} `json:"hooks"`
	}
	require.NoError(t, json.Unmarshal([]byte(flagValue(t, on, "--settings")), &settings))
	require.Len(t, settings.Hooks.PreToolUse, 1)
	assert.Equal(t, BrowserNavigateTool, settings.Hooks.PreToolUse[0].Matcher)
	require.Len(t, settings.Hooks.PreToolUse[0].Hooks, 1)
	assert.Equal(t, shellQuote(watchtowerBinary())+" ai connect-guard --host 'api.slack.com' --host 'app.slack.com'",
		settings.Hooks.PreToolUse[0].Hooks[0].Command)

	golden := strings.ReplaceAll(strings.Join(on, "\n")+"\n", watchtowerBinary(), "<watchtower>")
	path := filepath.Join("testdata", "connect_argv.golden")
	if *updateGolden {
		require.NoError(t, os.WriteFile(path, []byte(golden), 0o644))
	}
	want, err := os.ReadFile(path)
	require.NoError(t, err, "run with -update")
	assert.Equal(t, string(want), golden)

	for name, c := range map[string]*Client{
		"default":     NewClient("sonnet", "/tmp/wt.db", ""),
		"browser off": connectClient(false),
	} {
		off, _, _ := c.buildArgs("sys", "hi", "stream-json")
		assert.Zero(t, count(off, "--chrome"), name)
		assert.Zero(t, count(off, "--settings"), name)
		assert.NotContains(t, strings.Join(off, " "), "claude-in-chrome", name)
	}
}

// TestClaudeArgs_BrowserKeepsStrictMCP: the browser comes with Claude in
// Chrome's own server only; the run still loads no other MCP server and
// sees no other built-in tool.
func TestClaudeArgs_BrowserKeepsStrictMCP(t *testing.T) {
	args, _, _ := connectClient(true).buildArgs("sys", "hi", "stream-json")
	assert.Equal(t, 1, count(args, "--strict-mcp-config"))
	assert.Empty(t, flagValue(t, args, "--tools"), "S3.argv: no built-in, ToolSearch included")
	words, _, _ := connectClient(false).buildArgs("sys", "hi", "stream-json")
	assert.Equal(t, ChatBuiltinTools, flagValue(t, words, "--tools"), "a run without the browser keeps today's built-ins")
	assert.NotContains(t, strings.Split(flagValue(t, args, "--allowedTools"), ","), "Bash")
	assert.True(t, slices.Contains(strings.Split(flagValue(t, args, "--disallowedTools"), ","), "Bash"))
}

// TestChatMCPConfig_EnvVarsCopied: the named variables reach the
// watchtower server's env; an unset or empty one is left out, and none at
// all leaves the entry without env.
func TestChatMCPConfig_EnvVarsCopied(t *testing.T) {
	t.Setenv(connectwire.SocketEnv, "/tmp/connect.sock")
	t.Setenv(connectwire.TokenEnv, "")
	t.Setenv("WATCHTOWER_TEST_ABSENT", "x")
	require.NoError(t, os.Unsetenv("WATCHTOWER_TEST_ABSENT"))

	c := NewClient("m", "/tmp/wt.db", "")
	c.SetMCPArgs([]string{"--connect", "slack"})
	c.SetMCPEnvVars([]string{connectwire.SocketEnv, connectwire.TokenEnv, "WATCHTOWER_TEST_ABSENT"})
	var cfg struct {
		MCPServers map[string]struct {
			Args []string          `json:"args"`
			Env  map[string]string `json:"env"`
		} `json:"mcpServers"`
	}
	require.NoError(t, json.Unmarshal([]byte(c.buildMCPConfig()), &cfg))
	assert.Equal(t, map[string]string{connectwire.SocketEnv: "/tmp/connect.sock"}, cfg.MCPServers["watchtower"].Env)
	assert.Equal(t, []string{"mcp", "--db-path", "/tmp/wt.db", "--connect", "slack"}, cfg.MCPServers["watchtower"].Args)

	assert.NotContains(t, ChatMCPConfig("/tmp/wt.db", nil, nil), `"env"`)
}

// TestBuildArgs_ConnectTokenNeverInArgv: the run token is copied into the
// config, and the config then travels over the /dev/fd pipe, never argv.
func TestBuildArgs_ConnectTokenNeverInArgv(t *testing.T) {
	t.Setenv(connectwire.SocketEnv, "/tmp/connect.sock")
	t.Setenv(connectwire.TokenEnv, "tok-sample")
	for _, browser := range []bool{false, true} {
		args, _, payloads := connectClient(browser).buildArgs("sys", "hi", "stream-json")
		for _, a := range args {
			assert.NotContains(t, a, "tok-sample")
		}
		assert.True(t, strings.HasPrefix(flagValue(t, args, "--mcp-config"), "/dev/fd/"))
		var cfg struct {
			MCPServers map[string]struct {
				Env map[string]string `json:"env"`
			} `json:"mcpServers"`
		}
		require.NoError(t, json.Unmarshal([]byte(payloadFor(t, args, payloads, "--mcp-config")), &cfg))
		assert.Equal(t, "tok-sample", cfg.MCPServers["watchtower"].Env[connectwire.TokenEnv])
	}
}
