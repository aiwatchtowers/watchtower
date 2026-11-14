package slacklive

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/codex"
	"watchtower/internal/db"
)

func init() {
	connectTimeout = 10 * time.Second
	pollInterval = 5 * time.Millisecond
}

func shortConnect(t *testing.T) {
	old := connectTimeout
	connectTimeout = 150 * time.Millisecond
	t.Cleanup(func() { connectTimeout = old })
}

func stub(t *testing.T, name string) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("testdata", name))
	require.NoError(t, err)
	return p
}

func openDB(t *testing.T) *db.DB {
	t.Helper()
	d, err := db.Open(":memory:")
	require.NoError(t, err)
	t.Cleanup(func() { _ = d.Close() })
	return d
}

func TestReadToolsPinned(t *testing.T) {
	assert.Equal(t, []string{
		"slack_search_public", "slack_search_public_and_private", "slack_search_channels",
		"slack_search_users", "slack_read_channel", "slack_read_thread", "slack_read_canvas",
		"slack_read_user_profile", "slack_list_user_channels", "slack_list_channel_members",
		"slack_get_reactions", "slack_read_file", "slack_list_workspaces",
	}, ReadTools)
}

func TestLiveProbe_Classifies(t *testing.T) {
	cases := []struct {
		name, scenario, apiKey string
		status, class          string
	}{
		{"ok", "ok", "none", "ok", ""},
		{"unknown tool", "unknown", "none", "not_connected", "not_authorized"},
		{"admin", "admin", "none", "needs_admin", "admin_approval"},
		{"rate limit", "rate", "none", "unavailable", "rate_limited"},
		{"plan", "plan", "none", "no_plan", "plan"},
		{"timeout", "timeout", "none", "unavailable", "timeout"},
		{"no connector", "absent", "none", "not_connected", "no_connector"},
		{"api key", "apikey", "ANTHROPIC_API_KEY", "not_connected", "api_key_login"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if tc.scenario == "absent" || tc.scenario == "apikey" {
				shortConnect(t) // the connector never shows up: do not wait the full poll
			}
			env := append(os.Environ(), "SCENARIO="+tc.scenario, "API_KEY_SRC="+tc.apiKey)
			r := ProbeClaude(context.Background(), stub(t, "fake_claude.sh"), env)
			assert.Equal(t, tc.status, r.Status)
			assert.Equal(t, tc.class, r.ErrorClass)
			if tc.status == "ok" {
				assert.Equal(t, []string{"acme"}, r.TeamDomains)
			}
		})
	}
}

func TestClassify(t *testing.T) {
	cases := []struct {
		name, text        string
		connected, readOK bool
		status, class     string
	}{
		{"ok", "", true, true, "ok", ""},
		{"api key", SentinelAPIKeyLogin, false, false, "not_connected", "api_key_login"},
		{"no connector", "", false, false, "not_connected", "no_connector"},
		{"unknown tool", "Unknown tool: x", true, false, "not_connected", "not_authorized"},
		{"admin", "An admin must approve this app", true, false, "needs_admin", "admin_approval"},
		{"admin alone", "admin only", true, false, "unavailable", "read_failed"},
		{"429", "HTTP 429", true, false, "unavailable", "rate_limited"},
		{"rate limit", "rate limit exceeded", true, false, "unavailable", "rate_limited"},
		{"timeout", "request timed out", true, false, "unavailable", "timeout"},
		{"plan", "This is not available on your plan", true, false, "no_plan", "plan"},
		{"loose upgrade is not a plan error", "please upgrade the CLI", true, false, "unavailable", "read_failed"},
		{"connected, read failed", "boom", true, false, "unavailable", "read_failed"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			status, class := Classify("claude", tc.text, tc.connected, tc.readOK)
			assert.Equal(t, tc.status, status)
			assert.Equal(t, tc.class, class)
		})
	}
}

func TestClassify_PlanWordingOnlyFromToolText(t *testing.T) {
	status, class := classify("", "warning: upgrade to a newer version; your plan", true, false)
	assert.Equal(t, "unavailable", status)
	assert.Equal(t, "read_failed", class)
	status, _ = classify("not available on your plan", "", true, false)
	assert.Equal(t, "no_plan", status)
}

func TestClaudeArgs(t *testing.T) {
	args := claudeArgs()
	assert.NotContains(t, args, "--strict-mcp-config")
	i := slices.Index(args, "--setting-sources")
	require.GreaterOrEqual(t, i, 0)
	assert.Equal(t, "project,local", args[i+1])
	j := slices.Index(args, "--disallowedTools")
	require.GreaterOrEqual(t, j, 0)
	for _, w := range []string{"slack_send_message", "slack_schedule_message", "slack_send_message_draft",
		"slack_create_canvas", "slack_update_canvas", "slack_add_reaction"} {
		assert.Contains(t, args[j+1], "mcp__claude_ai_Slack__"+w)
	}
	assert.Equal(t, "stdio", args[slices.Index(args, "--permission-prompt-tool")+1])
}

func TestControlErrorFor(t *testing.T) {
	reply := controlErrorFor(`{"type":"control_request","request_id":"r9","request":{"subtype":"hook_callback"}}`)
	assert.Contains(t, reply, `"request_id":"r9"`)
	assert.Contains(t, reply, `"subtype":"error"`)
	assert.Empty(t, controlErrorFor(`{"type":"control_request","request_id":"r9","request":{"subtype":"can_use_tool"}}`))
	assert.Empty(t, controlErrorFor(`{"type":"result"}`))
}

func TestLiveProbe_ClaudeAnswersOtherControlRequests(t *testing.T) {
	record := filepath.Join(t.TempDir(), "answers")
	env := append(os.Environ(), "SCENARIO=ok", "RECORD="+record, "EXTRA_CONTROL=1")
	r := ProbeClaude(context.Background(), stub(t, "fake_claude.sh"), env)
	assert.Equal(t, "ok", r.Status)
	b, err := os.ReadFile(record)
	require.NoError(t, err)
	assert.Contains(t, string(b), `"subtype":"error"`)
}

func TestLiveProbe_ClaudeDeniesOtherTools(t *testing.T) {
	record := filepath.Join(t.TempDir(), "answers")
	env := append(os.Environ(), "SCENARIO=deny", "RECORD="+record)
	r := ProbeClaude(context.Background(), stub(t, "fake_claude.sh"), env)
	assert.NotEqual(t, "ok", r.Status)
	b, err := os.ReadFile(record)
	require.NoError(t, err)
	assert.Contains(t, string(b), `"behavior":"deny"`)
	assert.NotContains(t, string(b), `"behavior":"allow"`)
}

func TestLiveProbe_ClaudeAllowsOnlySearchChannels(t *testing.T) {
	record := filepath.Join(t.TempDir(), "answers")
	env := append(os.Environ(), "SCENARIO=ok", "RECORD="+record)
	ProbeClaude(context.Background(), stub(t, "fake_claude.sh"), env)
	b, err := os.ReadFile(record)
	require.NoError(t, err)
	assert.Contains(t, string(b), `"behavior":"allow"`)
}

func TestLiveProbe_KilledLeavesNoRow(t *testing.T) {
	for provider, probe := range map[string]Probe{"claude": ProbeClaude, "codex": ProbeCodex} {
		t.Run(provider, func(t *testing.T) {
			dir := t.TempDir()
			ready, pidfile := filepath.Join(dir, "ready"), filepath.Join(dir, "pid")
			require.NoError(t, syscall.Mkfifo(ready, 0o600))
			home := codexHomeWith(t, "chatgpt", true)
			env := append(os.Environ(), "SCENARIO=hang", "READY="+ready, "PIDFILE="+pidfile, "CODEX_HOME="+home)
			bin := stub(t, "fake_"+provider+".sh")
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			go func() {
				_, _ = os.ReadFile(ready) // blocks until the stub is mid-call
				cancel()
			}()
			d := openDB(t)
			_, err := Check(ctx, d, probe, bin, env, time.Now())
			require.Error(t, err)
			rows, err := d.ListSlackLiveStatus()
			require.NoError(t, err)
			assert.Empty(t, rows)
			raw, err := os.ReadFile(pidfile)
			require.NoError(t, err)
			pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
			require.NoError(t, err)
			assert.ErrorIs(t, syscall.Kill(pid, 0), syscall.ESRCH, "the stub is gone")
		})
	}
}

func codexHomeWith(t *testing.T, authMode string, cache bool) string {
	t.Helper()
	home := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(home, "auth.json"), []byte(`{"auth_mode":"`+authMode+`"}`), 0o600))
	if cache {
		dir := filepath.Join(home, "cache", "codex_apps_tools")
		require.NoError(t, os.MkdirAll(dir, 0o700))
		b, err := os.ReadFile(filepath.Join("testdata", "codex_apps_tools.json"))
		require.NoError(t, err)
		require.NoError(t, os.WriteFile(filepath.Join(dir, "abc.json"), b, 0o600))
	}
	return home
}

func TestLiveProbe_CodexConnectorIDFromCache(t *testing.T) {
	home := codexHomeWith(t, "chatgpt", true)
	env := append(os.Environ(), "SCENARIO=ok", "CODEX_HOME="+home)
	r := ProbeCodex(context.Background(), stub(t, "fake_codex.sh"), env)
	assert.Equal(t, "ok", r.Status)
	assert.Equal(t, "asdk_app_test", r.ConnectorID)
	assert.Equal(t, []string{"TACME12345"}, r.Teams)
}

func TestLiveProbe_CodexConnectorIDMissingFailsClosed(t *testing.T) {
	home := codexHomeWith(t, "chatgpt", false)
	argsFile := filepath.Join(t.TempDir(), "args")
	env := append(os.Environ(), "SCENARIO=ok", "CODEX_HOME="+home, "ARGSFILE="+argsFile)
	r := ProbeCodex(context.Background(), stub(t, "fake_codex.sh"), env)
	assert.Equal(t, "not_connected", r.Status)
	assert.Equal(t, "connector_id_unknown", r.ErrorClass)
	assert.Empty(t, r.ConnectorID)
	b, err := os.ReadFile(argsFile)
	require.NoError(t, err)
	runs := strings.Split(strings.TrimSpace(string(b)), "\n")
	require.Len(t, runs, 1, "only the warm-up ran; apps are never on without the allow-list")
	assert.Contains(t, runs[0], "apps._default.default_tools_enabled=false")
	assert.NotContains(t, runs[0], "slack_list_workspaces")
}

func TestLiveProbe_CodexWarmupFillsCacheThenReadOnlyRun(t *testing.T) {
	home := codexHomeWith(t, "chatgpt", false)
	// The owner's config tries to enable a write tool and another app.
	require.NoError(t, os.WriteFile(filepath.Join(home, "config.toml"), []byte(
		"[apps.asdk_app_test]\ndefault_tools_enabled = true\n[apps.asdk_app_test.tools.slack_send_message]\nenabled = true\n[apps.asdk_app_other]\nenabled = true\n[mcp_servers.mine]\ncommand = \"x\"\n"), 0o600))
	fixture, err := filepath.Abs(filepath.Join("testdata", "codex_apps_tools.json"))
	require.NoError(t, err)
	argsFile := filepath.Join(t.TempDir(), "args")
	env := append(os.Environ(), "SCENARIO=ok", "CODEX_HOME="+home, "ARGSFILE="+argsFile, "WARM_FIXTURE="+fixture)
	r := ProbeCodex(context.Background(), stub(t, "fake_codex.sh"), env)
	assert.Equal(t, "ok", r.Status)
	assert.Equal(t, "asdk_app_test", r.ConnectorID)
	b, err := os.ReadFile(argsFile)
	require.NoError(t, err)
	runs := strings.Split(strings.TrimSpace(string(b)), "\n")
	require.Len(t, runs, 2)
	assert.NotContains(t, runs[0], "slack_list_workspaces")
	for _, want := range []string{"features.apps=true", "apps._default.default_tools_enabled=false",
		"apps.asdk_app_test.default_tools_enabled=false", "apps.asdk_app_test.tools.slack_send_message.enabled=false"} {
		assert.Contains(t, runs[0], want, "warm-up")
	}
	for _, run := range runs {
		assert.Contains(t, run, `"mine"={enabled=false}`, "the owner's MCP servers are off in every run")
	}
	for _, want := range []string{"features.apps=true", "apps._default.enabled=false",
		"apps.asdk_app_test.tools.slack_list_workspaces.enabled=true",
		"apps.asdk_app_test.tools.slack_send_message.enabled=false", "apps.asdk_app_other.enabled=false"} {
		assert.Contains(t, runs[1], want)
	}
}

func TestLiveProbe_CodexInvalidConfigFailsClosed(t *testing.T) {
	home := codexHomeWith(t, "chatgpt", true)
	require.NoError(t, os.WriteFile(filepath.Join(home, "config.toml"), []byte("[apps\nbroken"), 0o600))
	argsFile := filepath.Join(t.TempDir(), "args")
	env := append(os.Environ(), "SCENARIO=ok", "CODEX_HOME="+home, "ARGSFILE="+argsFile)
	r := ProbeCodex(context.Background(), stub(t, "fake_codex.sh"), env)
	assert.NotEqual(t, "ok", r.Status)
	_, err := os.Stat(argsFile)
	assert.True(t, os.IsNotExist(err), "codex never ran")
}

func TestLiveProbe_CodexAuthWithoutModeIsNotAnAPIKey(t *testing.T) {
	home := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(home, "auth.json"), []byte(`{"tokens":{}}`), 0o600))
	assert.False(t, codexAPIKeyLogin(home))
	assert.True(t, codexAPIKeyLogin(codexHomeWith(t, "apikey", false)))
}

func TestWorkspaceTeamIDsFallbackNeedsADigit(t *testing.T) {
	assert.Equal(t, []string{"TACME12345"}, workspaceTeamIDs(json.RawMessage(`{"content":[{"text":"TEAMNAMES TACME12345"}]}`)))
}

func TestLiveProbe_CodexClassifies(t *testing.T) {
	cases := []struct {
		name, scenario, auth, status, class string
	}{
		{"unknown tool", "fail", "chatgpt", "not_connected", "not_authorized"},
		{"no call", "none", "chatgpt", "not_connected", "no_connector"},
		{"api key", "ok", "apikey", "not_connected", "api_key_login"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			env := append(os.Environ(), "SCENARIO="+tc.scenario, "CODEX_HOME="+codexHomeWith(t, tc.auth, true))
			r := ProbeCodex(context.Background(), stub(t, "fake_codex.sh"), env)
			assert.Equal(t, tc.status, r.Status)
			assert.Equal(t, tc.class, r.ErrorClass)
		})
	}
}

func TestCheck_WritesRowsPerTeam(t *testing.T) {
	d := openDB(t)
	_, err := d.CreateSlackAccount(db.SlackAccount{TeamID: "TACME12345", TeamDomain: "acme"})
	require.NoError(t, err)
	_, err = d.CreateSlackAccount(db.SlackAccount{TeamID: "TOTHER1234", TeamDomain: "other"})
	require.NoError(t, err)
	now := time.Now()

	env := append(os.Environ(), "SCENARIO=ok")
	r, err := Check(context.Background(), d, ProbeClaude, stub(t, "fake_claude.sh"), env, now)
	require.NoError(t, err)
	assert.Equal(t, "ok", r.Status)
	rows, err := d.ListSlackLiveStatus()
	require.NoError(t, err)
	got := map[string]string{}
	for _, row := range rows {
		got[row.TeamID] = row.Status
	}
	assert.Equal(t, map[string]string{"TACME12345": "ok", "": "ok", "TOTHER1234": "not_connected"}, got,
		"an account the connector did not show is not connected")

	env = append(os.Environ(), "SCENARIO=unknown")
	_, err = Check(context.Background(), d, ProbeClaude, stub(t, "fake_claude.sh"), env, now.Add(time.Minute))
	require.NoError(t, err)
	rows, err = d.ListSlackLiveStatus()
	require.NoError(t, err)
	got = map[string]string{}
	for _, row := range rows {
		got[row.TeamID] = row.Status
	}
	assert.Equal(t, map[string]string{"TACME12345": "not_connected", "TOTHER1234": "not_connected", "": "not_connected"}, got)
}

func TestWaitConnected_TimesOut(t *testing.T) {
	lines := make(chan string)
	err := WaitConnected(context.Background(), lines, func(string) error { return nil }, 20*time.Millisecond)
	assert.ErrorIs(t, err, ErrNotConnected)
}

func TestWaitConnected_Connected(t *testing.T) {
	lines := make(chan string, 1)
	write := func(l string) error {
		var req struct {
			RequestID string `json:"request_id"`
		}
		require.NoError(t, json.Unmarshal([]byte(l), &req))
		lines <- `{"type":"control_response","response":{"subtype":"success","request_id":"` + req.RequestID +
			`","response":{"mcpServers":[{"name":"claude.ai Slack","status":"connected"}]}}}`
		return nil
	}
	assert.NoError(t, WaitConnected(context.Background(), lines, write, time.Second))
}

func TestWorkspaceTeamIDs(t *testing.T) {
	structured := json.RawMessage(`{"content":[{"type":"text","text":"TFAKE9999 in text"}],"structured_content":{"ok":true,"teams":[{"id":"TACME12345","name":"Acme"},{"id":"TOTHER1234","name":"Other"}]}}`)
	assert.Equal(t, []string{"TACME12345", "TOTHER1234"}, workspaceTeamIDs(structured), "structured ids win over text")
	assert.Equal(t, []string{"TACME12345"}, workspaceTeamIDs(json.RawMessage(`{"content":[{"text":"TACME12345 Acme"}]}`)), "regex fallback")
	assert.Empty(t, workspaceTeamIDs(json.RawMessage(`{"structured_content":{"teams":[]}}`)))
}

// Runs the real codex with only slack_list_workspaces enabled; needs a
// ChatGPT login with the Slack app. Opt in with WATCHTOWER_LIVE_CODEX=1.
func TestLiveProbe_CodexAllowListReal(t *testing.T) {
	if os.Getenv("WATCHTOWER_LIVE_CODEX") != "1" {
		t.Skip("set WATCHTOWER_LIVE_CODEX=1 to run against the real codex")
	}
	bin, err := exec.LookPath("codex")
	require.NoError(t, err)
	home := codexHome(nil)
	id := slackConnectorID(home)
	require.NotEmpty(t, id, "run the probe once so Codex caches its apps")
	apps, err := codex.ReadOnlyAppOverrides(home, id, []string{codexListTool})
	require.NoError(t, err)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	args := append([]string{"exec", "--json", "--ephemeral", "--skip-git-repo-check",
		"-c", "approval_policy=never", "-c", "sandbox_mode=read-only"}, apps...)
	cmd := exec.CommandContext(ctx, bin, append(args,
		"Call slack_list_workspaces once, then call slack_search_channels once with query a. Reply done.")...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	out, _ := cmd.Output()
	assert.Contains(t, string(out), "slack_list_workspaces")
	assert.NotContains(t, string(out), "slack_search_channels\"", "the disabled tool is never called")
}
