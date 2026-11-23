package cmd

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/aiconsent/aiconsenttest"
	"watchtower/internal/chat"
	"watchtower/internal/codex"
	"watchtower/internal/config"
	"watchtower/internal/connectplay"
	"watchtower/internal/connectwire"
	"watchtower/internal/policy/policytest"
	"watchtower/internal/providers"
	"watchtower/internal/providers/transport"
)

// setConnectFlags sets the connect run's flags for an in-process
// newQueryClient, restored at cleanup.
func setConnectFlags(t *testing.T, service, mode string) {
	t.Helper()
	oldTools, oldModel, oldService, oldMode := aiFlagTools, aiFlagModel, aiFlagConnectService, aiFlagConnectMode
	t.Cleanup(func() {
		aiFlagTools, aiFlagModel, aiFlagConnectService, aiFlagConnectMode = oldTools, oldModel, oldService, oldMode
	})
	aiFlagTools, aiFlagModel, aiFlagConnectService, aiFlagConnectMode = toolsConnect, "", service, mode
}

// connectClaudeStub is a claude that records its argv, its system prompt
// and its mcp-config (both read from their /dev/fd pipes) under out, then
// answers one line.
func connectClaudeStub(t *testing.T, out string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "claude")
	script := fmt.Sprintf(`#!/bin/sh
out='%s'
cat > /dev/null
printf '%%s\n' "$@" > "$out/argv"
env > "$out/env"
while [ $# -gt 0 ]; do
  case "$1" in
    --mcp-config) cat "$2" > "$out/mcp" ;;
    --system-prompt-file) cat "$2" > "$out/system" ;;
  esac
  shift
done
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"ok"}]}}\n'
printf '{"type":"result","subtype":"success","result":"ok","session_id":"s1"}\n'
`, out)
	require.NoError(t, os.WriteFile(path, []byte(script), 0o755))
	return path
}

// connectFixture writes a config for provider (claude through stub when
// given) and returns its path and a database path.
func connectFixture(t *testing.T, provider, claudePath, ollamaURL string) (cfgPath, dbPath string) {
	t.Helper()
	dir := t.TempDir()
	cfgPath = filepath.Join(dir, "config.yaml")
	require.NoError(t, os.WriteFile(cfgPath, fmt.Appendf(nil, `active_workspace: test-ws
workspaces:
  test-ws:
    slack_token: "xoxp-test-token"
claude_path: %q
ai:
  provider: %s
  ollama_url: %q
  models:
    strong: some-model
digest:
  language: Russian
`, claudePath, provider, ollamaURL), 0o600))
	return cfgPath, filepath.Join(dir, "wt.db")
}

func runConnectCLI(t *testing.T, cfgPath, dbPath string, extra ...string) (code int, stdout []string, stderr string) {
	t.Helper()
	args := append([]string{"ai", "query", "--config", cfgPath, "--db-path", dbPath, "--events", "v2",
		"--tools", "connect", "--prompt-stdin"}, extra...)
	p := startCLI(t, args...)
	_, err := p.stdin.Write([]byte(`{"prompt":"connect slack","system_prompt":"STATE: no Slack account yet"}`))
	require.NoError(t, err)
	_ = p.stdin.Close()
	for line := range p.lines {
		stdout = append(stdout, line)
	}
	return exitCode(p.wait()), stdout, p.stderr.String()
}

func v2ErrorOf(t *testing.T, lines []string) *chat.Event {
	t.Helper()
	for _, line := range lines {
		var ev chat.Event
		require.NoError(t, json.Unmarshal([]byte(line), &ev), line)
		assert.NotEqual(t, chat.EventTextDelta, ev.Type, "no model answer")
		if ev.Type == chat.EventError {
			return &ev
		}
	}
	return nil
}

// The connect run end to end on claude in browser mode: --chrome, the
// browser tools and the navigate guard on argv; the run's token only in
// the mcp-config pipe; the connect prompt, then the Desktop's state.
func TestAIQueryConnect_ClaudeBrowserRun(t *testing.T) {
	out := t.TempDir()
	cfgPath, dbPath := connectFixture(t, "claude", connectClaudeStub(t, out), "")
	t.Setenv(connectwire.SocketEnv, "/tmp/connect.sock")
	t.Setenv(connectwire.TokenEnv, "tok-sample")

	code, stdout, stderr := runConnectCLI(t, cfgPath, dbPath, "--connect-service", "slack", "--connect-mode", "browser")
	require.Equal(t, 0, code, "stderr: %s\nstdout: %v", stderr, stdout)
	assert.NotContains(t, strings.Join(stdout, "\n"), `"type":"error"`)

	argv, err := os.ReadFile(filepath.Join(out, "argv"))
	require.NoError(t, err)
	args := strings.Split(strings.TrimSpace(string(argv)), "\n")
	assert.Contains(t, args, "--chrome")
	assert.NotContains(t, string(argv), "tok-sample", "the token never rides argv")
	assert.Contains(t, string(argv), "ai connect-guard --host 'api.slack.com' --host 'app.slack.com'")
	env, err := os.ReadFile(filepath.Join(out, "env"))
	require.NoError(t, err)
	assert.Contains(t, string(env), connectwire.SocketEnv, "a run's child inherits them (the probe's does not)")

	mcp, err := os.ReadFile(filepath.Join(out, "mcp"))
	require.NoError(t, err)
	var cfg struct {
		MCPServers map[string]struct {
			Args []string          `json:"args"`
			Env  map[string]string `json:"env"`
		} `json:"mcpServers"`
	}
	require.NoError(t, json.Unmarshal(mcp, &cfg))
	require.Len(t, cfg.MCPServers, 1, "only the watchtower server: no Quick Connections")
	w := cfg.MCPServers["watchtower"]
	assert.Equal(t, []string{"--connect", "slack"}, w.Args[len(w.Args)-2:])
	assert.Equal(t, map[string]string{connectwire.SocketEnv: "/tmp/connect.sock", connectwire.TokenEnv: "tok-sample"}, w.Env)

	system, err := os.ReadFile(filepath.Join(out, "system"))
	require.NoError(t, err)
	pbs, err := connectplay.ForService("slack", "")
	require.NoError(t, err)
	assert.Equal(t, connectplay.SystemPrompt(pbs, connectplay.ModeBrowser, "Russian")+"\n\nSTATE: no Slack account yet", string(system))
	assert.Contains(t, string(system), "Write every message in Russian", "the owner's assistant language (digest.language)")
}

// TestAIQueryConnect_ProbeRun: `--connect-mode probe` end to end on claude
// (spec §10 S1): --chrome, list_connected_browsers as the only allowed
// tool, no --mcp-config (the connect MCP server is absent, so neither the
// socket nor the token reaches the child), and the Desktop's system prompt
// alone, with no playbook.
func TestAIQueryConnect_ProbeRun(t *testing.T) {
	out := t.TempDir()
	cfgPath, dbPath := connectFixture(t, "claude", connectClaudeStub(t, out), "")
	t.Setenv(connectwire.SocketEnv, "/tmp/connect.sock")
	t.Setenv(connectwire.TokenEnv, "tok-sample")

	code, stdout, stderr := runConnectCLI(t, cfgPath, dbPath, "--connect-service", "slack", "--connect-mode", "probe")
	require.Equal(t, 0, code, "stderr: %s\nstdout: %v", stderr, stdout)

	argv, err := os.ReadFile(filepath.Join(out, "argv"))
	require.NoError(t, err)
	args := strings.Split(strings.TrimSpace(string(argv)), "\n")
	assert.Contains(t, args, "--chrome")
	assert.Contains(t, args, "--strict-mcp-config")
	assert.Equal(t, ai.BrowserProbeTool, args[slices.Index(args, "--allowedTools")+1])
	assert.Empty(t, args[slices.Index(args, "--tools")+1])
	assert.NotContains(t, args, "--mcp-config")
	assert.NotContains(t, string(argv), "tok-sample")
	assert.NotContains(t, string(argv), "connect-guard")
	_, err = os.Stat(filepath.Join(out, "mcp"))
	assert.True(t, os.IsNotExist(err), "no MCP config reached the child")
	assert.Contains(t, strings.Split(args[slices.Index(args, "--disallowedTools")+1], ","), ai.BrowserNavigateTool)

	env, err := os.ReadFile(filepath.Join(out, "env"))
	require.NoError(t, err)
	assert.NotContains(t, string(env), connectwire.SocketEnv, "set in the parent, dropped for the probe child")
	assert.NotContains(t, string(env), connectwire.TokenEnv)
	assert.NotContains(t, string(env), "tok-sample")

	system, err := os.ReadFile(filepath.Join(out, "system"))
	require.NoError(t, err)
	assert.Equal(t, "STATE: no Slack account yet", string(system), "no playbook prompt")
}

// TestAIQueryConnect_ProbeEnvFailsClosed: an environment holding only the
// connect variables gives the probe child an empty one, never nil (which
// the transport reads as "inherit this process's", socket and token too).
func TestAIQueryConnect_ProbeEnvFailsClosed(t *testing.T) {
	env := connectProbeEnv([]string{connectwire.SocketEnv + "=/tmp/connect.sock", connectwire.TokenEnv + "=tok-sample"})
	require.NotNil(t, env)
	assert.Empty(t, env)
	assert.Equal(t, []string{"HOME=/tmp"},
		connectProbeEnv([]string{"HOME=/tmp", connectwire.TokenEnv + "=tok-sample"}))
}

// TestAIQueryConnect_ProbeRefusals: a probe needs a browser: codex (words),
// ollama (none) and a policy-blocked claude are refused before any model
// call, at the CLI's check and in the client factory.
func TestAIQueryConnect_ProbeRefusals(t *testing.T) {
	policytest.Set(t, nil)
	setConnectFlags(t, "slack", "probe")
	for _, provider := range []string{"codex", "ollama"} {
		var failure *providers.Failure
		require.ErrorAs(t, connectProbeCheck(provider), &failure, provider)
		assert.Equal(t, providers.Capability, failure.Category, provider)
		client, _, err := newQueryClient(&config.Config{AI: config.AIConfig{Provider: provider}}, "/tmp/wt.db", transport.Options{})
		require.Error(t, err, provider)
		assert.Nil(t, client, provider)
	}
	client, _, err := newQueryClient(&config.Config{AI: config.AIConfig{Provider: "claude"}}, "/tmp/wt.db", transport.Options{})
	require.NoError(t, err)
	args := client.(*ai.Client).ArgsForTest("sys", "hi")
	assert.NotContains(t, args, "--mcp-config")
	assert.Contains(t, args, "--chrome")

	policytest.Set(t, map[string]any{"AllowedAIProviders": []any{"codex"}})
	var failure *providers.Failure
	require.ErrorAs(t, connectProbeCheck("claude"), &failure)
	assert.Equal(t, providers.Policy, failure.Category)

	// End to end: codex is refused with a v2 error and no model run.
	policytest.Set(t, nil)
	cfgPath, dbPath := connectFixture(t, "codex", "", "")
	code, stdout, _ := runConnectCLI(t, cfgPath, dbPath, "--connect-service", "slack", "--connect-mode", "probe")
	assert.NotEqual(t, 0, code)
	ev := v2ErrorOf(t, stdout)
	require.NotNil(t, ev, "%v", stdout)
	assert.Equal(t, "required_capability_missing", ev.Reason)
}

// TestAIQueryConnect_RefusesNoneCapability: ollama's agent cannot guide a
// connection; the run is refused before any model call.
func TestAIQueryConnect_RefusesNoneCapability(t *testing.T) {
	var hits atomic.Int32
	model := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		hits.Add(1)
		http.Error(w, "must not be called", http.StatusTeapot)
	}))
	t.Cleanup(model.Close)
	cfgPath, dbPath := connectFixture(t, "ollama", "", model.URL)

	code, stdout, _ := runConnectCLI(t, cfgPath, dbPath, "--connect-service", "slack", "--connect-mode", "words")
	assert.NotEqual(t, 0, code, "the refusal is a failed command")
	assert.Zero(t, hits.Load(), "no model call")
	ev := v2ErrorOf(t, stdout)
	require.NotNil(t, ev, "a v2 error: %v", stdout)
	assert.Equal(t, "required_capability_missing", ev.Reason)
	assert.False(t, ev.Retryable)

	// The zero row (Connect "") cannot guide either; the leaf refuses too.
	assert.False(t, connectGuides(providers.Capabilities{}))
	setConnectFlags(t, "slack", "words")
	client, _, err := newQueryClient(&config.Config{AI: config.AIConfig{Provider: "ollama"}}, dbPath, transport.Options{})
	require.Error(t, err)
	assert.Nil(t, client, "never runtime B")
}

// Bad flags are refused before the config is read: the config path does
// not exist, so a later check would report a config error instead.
func TestAIQueryConnect_FlagRefusals(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "missing.yaml")
	for name, tc := range map[string]struct {
		args []string
		want string
	}{
		"no mode":            {[]string{"--tools", "connect", "--connect-service", "slack"}, "--connect-mode must be browser, words or probe"},
		"bad mode":           {[]string{"--tools", "connect", "--connect-service", "slack", "--connect-mode", "auto"}, "--connect-mode must be browser, words or probe"},
		"unknown service":    {[]string{"--tools", "connect", "--connect-service", "acme", "--connect-mode", "words"}, `connect service "acme": unknown`},
		"persist":            {[]string{"--tools", "connect", "--connect-service", "slack", "--connect-mode", "words", "--persist"}, "without --persist"},
		"owner instructions": {[]string{"--tools", "connect", "--connect-service", "slack", "--connect-mode", "words", "--owner-instructions"}, "without --owner-instructions"},
		"read folder":        {[]string{"--tools", "connect", "--connect-service", "slack", "--connect-mode", "words", "--read-folder", "/tmp"}, "without --read-folder"},
		"no --tools connect": {[]string{"--connect-service", "slack"}, "need --tools connect"},
	} {
		t.Run(name, func(t *testing.T) {
			args := append([]string{"ai", "query", "--config", missing, "--events", "v2"}, tc.args...)
			p := startCLI(t, append(args, "--", "hi")...)
			_ = p.stdin.Close()
			var lines []string
			for line := range p.lines {
				lines = append(lines, line)
			}
			_ = p.wait()
			ev := v2ErrorOf(t, lines)
			require.NotNil(t, ev, "%v", lines)
			assert.Contains(t, ev.Message, tc.want)
		})
	}
}

// TestAIQueryConnect_RefusesPolicyBlockedProvider: a provider the
// organization blocks is refused as a policy failure, at the CLI's check
// and in the client factory.
func TestAIQueryConnect_RefusesPolicyBlockedProvider(t *testing.T) {
	policytest.Set(t, map[string]any{"AllowedAIProviders": []any{"codex"}})
	setConnectFlags(t, "slack", "browser")

	_, err := connectRunMode("claude")
	var failure *providers.Failure
	require.ErrorAs(t, err, &failure)
	assert.Equal(t, providers.Policy, failure.Category)

	client, _, err := newQueryClient(&config.Config{AI: config.AIConfig{Provider: "claude"}}, "/tmp/wt.db", transport.Options{})
	require.Error(t, err)
	assert.Nil(t, client)

	mode, err := connectRunMode("codex")
	require.NoError(t, err)
	assert.Equal(t, connectplay.ModeWords, mode, "the allowed codex runs in words")
}

// TestAIQueryConnect_NoQuickConnections: the owner's Quick Connections
// are never mounted on a connect run (they are on a chat run).
func TestAIQueryConnect_NoQuickConnections(t *testing.T) {
	policytest.Set(t, nil)
	oldSurface := aiFlagSurface
	t.Cleanup(func() { aiFlagSurface = oldSurface })
	for _, provider := range []string{"claude", "codex"} {
		t.Setenv("HOME", t.TempDir())
		cfg := &config.Config{ActiveWorkspace: "test-ws", AI: config.AIConfig{Provider: provider}}
		dbPath := seedQuickConnection(t, cfg)

		setConnectFlags(t, "slack", "browser")
		client, cleanup, err := newQueryClient(cfg, dbPath, transport.Options{})
		require.NoError(t, err)
		cleanup()
		switch c := client.(type) {
		case *ai.Client:
			assert.Nil(t, c.ExternalServersForTest(), provider)
		case *codex.Client:
			assert.NotContains(t, strings.Join(c.ArgsForTest("sys", "hi"), " "), "trello", provider)
		default:
			t.Fatalf("%s: got %T", provider, client)
		}

		// The seed is mountable: a chat run does mount it.
		aiFlagTools, aiFlagSurface = "chat", "main"
		client, cleanup, err = newQueryClient(cfg, dbPath, transport.Options{})
		require.NoError(t, err)
		cleanup()
		if c, ok := client.(*ai.Client); ok {
			assert.Len(t, c.ExternalServersForTest(), 1)
		}
	}
}

// TestAIQueryConnect_WordsModeHasNoChrome: claude asked for words gets no
// browser; asked for browser it does.
func TestAIQueryConnect_WordsModeHasNoChrome(t *testing.T) {
	policytest.Set(t, nil)
	cfg := &config.Config{AI: config.AIConfig{Provider: "claude"}}
	for mode, want := range map[string]bool{"words": false, "browser": true} {
		setConnectFlags(t, "slack", mode)
		client, _, err := newQueryClient(cfg, "/tmp/wt.db", transport.Options{BrowserHosts: []string{"api.slack.com"}})
		require.NoError(t, err)
		args := client.(*ai.Client).ArgsForTest("sys", "hi")
		assert.Equal(t, want, slices.Contains(args, "--chrome"), mode)
		assert.Equal(t, want, strings.Contains(strings.Join(args, " "), "claude-in-chrome"), mode)
		assert.Contains(t, args, "--strict-mcp-config", mode)
	}
}

// TestAIQueryConnect_CodexArgvUnchanged: codex has no browser (spec §10
// S3.verdict): in either requested mode its argv is the plain tool run's
// plus the --connect server args and the env pass-through, with every
// browser feature still forced off.
func TestAIQueryConnect_CodexArgvUnchanged(t *testing.T) {
	policytest.Set(t, nil)
	cfg := &config.Config{AI: config.AIConfig{Provider: "codex"}}
	// The prompt file's name is random per call.
	argsOf := func(c ai.Provider) []string {
		args := c.(*codex.Client).ArgsForTest("sys", "hi")
		for i, a := range args {
			if strings.HasPrefix(a, "model_instructions_file=") {
				args[i] = "model_instructions_file=<file>"
			}
		}
		return args
	}
	plain := argsOf(buildQuerier(cfg, transport.Options{DBPath: "/tmp/wt.db", MCPArgs: []string{"--connect", "slack"},
		MCPEnvVars: []string{connectwire.SocketEnv, connectwire.TokenEnv}}))
	for _, mode := range []string{"words", "browser"} {
		setConnectFlags(t, "slack", mode)
		client, _, err := newQueryClient(cfg, "/tmp/wt.db", transport.Options{BrowserHosts: []string{"api.slack.com"}})
		require.NoError(t, err)
		args := argsOf(client)
		assert.Equal(t, plain, args, mode)
		joined := strings.Join(args, " ")
		for _, f := range []string{"browser_use", "browser_use_external", "in_app_browser"} {
			assert.Contains(t, joined, "features."+f+"=false", mode)
			assert.NotContains(t, joined, "features."+f+"=true", mode)
		}
		assert.Contains(t, joined, connectwire.TokenEnv, "codex passes the token by name (env_vars)")
	}
	run, err := connectRunMode("codex")
	require.NoError(t, err)
	assert.Equal(t, connectplay.ModeWords, run, "codex's prompt is words mode even when browser is asked")
}

// TestAIQueryConnect_NotGatedByPause (BGAI-02): the connect run is the
// owner's own gesture; paused background AI does not stop it.
func TestAIQueryConnect_NotGatedByPause(t *testing.T) {
	policytest.Set(t, nil)
	aiconsenttest.Use(t, "cli", nil, false)
	setConnectFlags(t, "slack", "words")
	client, _, err := newQueryClient(&config.Config{AI: config.AIConfig{Provider: "claude"}}, "/tmp/wt.db", transport.Options{})
	require.NoError(t, err)
	assert.NotNil(t, client)
}

// A connect run is never routed (spec §8: no automatic fallback mid-run):
// with fallback on it still runs the configured provider's own client.
func TestAIQueryConnect_NeverRouted(t *testing.T) {
	policytest.Set(t, nil)
	cfg := &config.Config{AI: config.AIConfig{Provider: "claude"}}
	cfg.AI.Fallback.Enabled, cfg.AI.Fallback.Provider = true, "codex"
	setConnectFlags(t, "slack", "browser")
	require.True(t, toolRoutingEnabled(cfg, aiFlagModel), "the fixture would route a chat turn")

	client, _, err := newQueryClient(cfg, "/tmp/wt.db", transport.Options{})
	require.NoError(t, err)
	c, ok := client.(*ai.Client)
	require.True(t, ok, "the pinned claude client, got %T", client)
	assert.Contains(t, c.ArgsForTest("sys", "hi"), "--chrome")

	aiFlagTools = "chat"
	client, _, err = newQueryClient(cfg, "/tmp/wt.db", transport.Options{})
	require.NoError(t, err)
	assert.IsType(t, &toolRouteProvider{}, client, "a chat turn is routed")
}

// Every failure of the guard command exits 2 (a blocking hook error), so a
// bad flag or argument never lets the navigation through.
func TestConnectGuard_FailuresExit2(t *testing.T) {
	for name, args := range map[string][]string{
		"unknown flag":  {"ai", "connect-guard", "--bogus"},
		"flag no value": {"ai", "connect-guard", "--host"},
		"extra arg":     {"ai", "connect-guard", "--host", "api.slack.com", "extra"},
	} {
		t.Run(name, func(t *testing.T) {
			p := startCLI(t, args...)
			_ = p.stdin.Close()
			for range p.lines {
			}
			assert.Equal(t, 2, exitCode(p.wait()))
		})
	}
	// The real command, end to end: an outside host is denied, exit 0.
	p := startCLI(t, "ai", "connect-guard", "--host", "api.slack.com")
	_, err := p.stdin.Write([]byte(`{"tool_name":"` + ai.BrowserNavigateTool + `","tool_input":{"url":"https://evil.example.com/"}}`))
	require.NoError(t, err)
	_ = p.stdin.Close()
	var out []string
	for line := range p.lines {
		out = append(out, line)
	}
	assert.Equal(t, 0, exitCode(p.wait()))
	assert.Contains(t, strings.Join(out, ""), `"permissionDecision":"deny"`)
}

// The navigate guard: an allowed host passes (no output), anything else,
// unreadable input included, is denied with Claude Code's PreToolUse
// denial, and a denial it cannot write fails the hook.
func TestConnectGuard(t *testing.T) {
	hosts := []string{"api.slack.com", "app.slack.com"}
	input := func(tool, url string) string {
		return fmt.Sprintf(`{"hook_event_name":"PreToolUse","tool_name":%q,"tool_input":{"url":%q}}`, tool, url)
	}
	for name, tc := range map[string]struct {
		in   string
		deny bool
	}{
		"allowed host":   {input(ai.BrowserNavigateTool, "https://api.slack.com/apps"), false},
		"back":           {input(ai.BrowserNavigateTool, "back"), false},
		"other host":     {input(ai.BrowserNavigateTool, "https://evil.example.com/"), true},
		"no url":         {`{"tool_name":"` + ai.BrowserNavigateTool + `","tool_input":{}}`, true},
		"unreadable":     {"not json", true},
		"empty":          {"", true},
		"no tool_name":   {`{"tool_input":{"url":"https://evil.example.com/"}}`, true},
		"empty tool":     {input("", "https://evil.example.com/"), true},
		"empty object":   {`{}`, true},
		"other tool":     {input("mcp__claude-in-chrome__computer", "https://evil.example.com/"), false},
		"suffix spoofed": {input(ai.BrowserNavigateTool, "https://api.slack.com.evil.example/"), true},
	} {
		t.Run(name, func(t *testing.T) {
			var out bytes.Buffer
			require.NoError(t, runConnectGuard(strings.NewReader(tc.in), &out, hosts))
			if !tc.deny {
				assert.Empty(t, out.String())
				return
			}
			var d preToolUseDenial
			require.NoError(t, json.Unmarshal(out.Bytes(), &d), out.String())
			assert.Equal(t, "PreToolUse", d.HookSpecificOutput.HookEventName)
			assert.Equal(t, "deny", d.HookSpecificOutput.PermissionDecision)
			assert.NotEmpty(t, d.HookSpecificOutput.PermissionDecisionReason)
		})
	}
	assert.Error(t, runConnectGuard(strings.NewReader("not json"), failingWriter{}, hosts))
}

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) { return 0, errors.New("closed") }
