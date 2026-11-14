package slacklive

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

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
				assert.Equal(t, []string{"acme"}, r.Teams)
			}
		})
	}
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
	for _, provider := range []string{"claude", "codex"} {
		t.Run(provider, func(t *testing.T) {
			dir := t.TempDir()
			ready, pidfile := filepath.Join(dir, "ready"), filepath.Join(dir, "pid")
			require.NoError(t, syscall.Mkfifo(ready, 0o600))
			home := t.TempDir()
			env := append(os.Environ(), "SCENARIO=hang", "READY="+ready, "PIDFILE="+pidfile, "CODEX_HOME="+home)
			bin := stub(t, "fake_"+provider+".sh")
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			go func() {
				_, _ = os.ReadFile(ready) // blocks until the stub is mid-call
				cancel()
			}()
			d := openDB(t)
			_, err := Check(ctx, d, provider, bin, env, time.Now())
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
	env := append(os.Environ(), "SCENARIO=ok", "CODEX_HOME="+home)
	r := ProbeCodex(context.Background(), stub(t, "fake_codex.sh"), env)
	assert.Equal(t, "not_connected", r.Status)
	assert.Equal(t, "connector_id_unknown", r.ErrorClass)
	assert.Empty(t, r.ConnectorID)
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
	r, err := Check(context.Background(), d, "claude", stub(t, "fake_claude.sh"), env, now)
	require.NoError(t, err)
	assert.Equal(t, "ok", r.Status)
	rows, err := d.ListSlackLiveStatus()
	require.NoError(t, err)
	got := map[string]string{}
	for _, row := range rows {
		got[row.TeamID] = row.Status
	}
	assert.Equal(t, map[string]string{"TACME12345": "ok", "": "ok"}, got)

	env = append(os.Environ(), "SCENARIO=unknown")
	_, err = Check(context.Background(), d, "claude", stub(t, "fake_claude.sh"), env, now.Add(time.Minute))
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
	id := slackConnectorID(codexHome(nil))
	require.NotEmpty(t, id, "run the probe once so Codex caches its apps")
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, "exec", "--json", "--ephemeral", "--skip-git-repo-check",
		"-c", "approval_policy=never", "-c", "sandbox_mode=read-only", "-c", "features.apps=true",
		"-c", "apps."+id+".default_tools_enabled=false",
		"-c", "apps."+id+".tools.slack_list_workspaces.enabled=true",
		"Call slack_list_workspaces once, then call slack_search_channels once with query a. Reply done.")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	out, _ := cmd.Output()
	assert.Contains(t, string(out), "slack_list_workspaces")
	assert.NotContains(t, string(out), "slack_search_channels\"", "the disabled tool is never called")
}
