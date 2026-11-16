package cmd

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/chat"
	"watchtower/internal/codex"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/policy/policytest"
	"watchtower/internal/slackconnector"
)

// liveAgentRecipe is a manual slack:live recipe whose script runs one agent().
func liveAgentRecipe() string {
	return "---\nname: Live agent\ntrigger:\n  manual: true\npermissions:\n  - slack:live\n  - agent:run\n  - llm:light\n" +
		"  - tool:list_targets\noutputs: [report]\n---\nA Live Slack agent() recipe.\n\n```js\nreturn agent(\"read the channel\").text\n```\n"
}

func liveAgentFixture(t *testing.T, cfg *config.Config) *agentFixture {
	t.Helper()
	d := db.OpenTestDB(t)
	a := automationstest.SeedAutomation(t, d, liveAgentRecipe(), automationstest.SeedOptions{Slug: "live-agent"})
	exec := automations.NewExecutor(d, automationBackends(cfg, d, &automationstest.FakeGenerator{Replies: []string{"ok"}}),
		automations.ExecutorOptions{})
	return &agentFixture{d: d, a: a, exec: exec}
}

func liveSlackOf(t *testing.T, d *db.DB, runID int64) int {
	t.Helper()
	var live int
	require.NoError(t, d.QueryRow(`SELECT live_slack FROM automation_runs WHERE id = ?`, runID).Scan(&live))
	return live
}

// writeClaudeStreamStub is a claude stream-json child: it answers
// mcp_status with claude.ai Slack connected, then asks permission for a
// connector write and for another connector's tool (the host's answers go to
// <dir>/answers), reads one channel and ends with a result.
func writeClaudeStreamStub(t *testing.T, connected bool) (dir, path string) {
	t.Helper()
	status := "connected"
	if !connected {
		status = "pending"
	}
	dir = t.TempDir()
	path = filepath.Join(dir, "claude")
	script := `#!/bin/sh
echo $$ > '` + dir + `/pid'
for a in "$@"; do printf '%s\0' "$a"; done > '` + dir + `/argv'
rf=$(for a in "$@"; do printf '%s\n' "$a"; done | sed -n 's/.*"--automation-ready-file", *"\([^"]*\)".*/\1/p' | head -n 1)
[ -n "$rf" ] && : > "$rf"
can_use() { printf '{"type":"control_request","request_id":"%s","request":{"subtype":"can_use_tool","tool_name":"%s","input":{}}}\n' "$1" "$2"; }
while IFS= read -r line; do
  case "$line" in
    *'"subtype":"mcp_status"'*)
      id=$(printf '%s' "$line" | sed 's/.*"request_id":"\([^"]*\)".*/\1/')
      printf '{"type":"control_response","response":{"subtype":"success","request_id":"%s","response":{"mcpServers":[{"name":"claude.ai Slack","status":"` + status + `"}]}}}\n' "$id"
      ;;
    *'"type":"user"'*)
      can_use p1 mcp__claude_ai_Slack__slack_send_message
      IFS= read -r a; echo "$a" >> '` + dir + `/answers'
      can_use p2 mcp__claude_ai_Gmail__send_email
      IFS= read -r a; echo "$a" >> '` + dir + `/answers'
      echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"mcp__claude_ai_Slack__slack_read_channel","input":{}}]}}'
      echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"hello"}]}}'
      echo '{"type":"result","subtype":"success","is_error":false,"result":"read it","usage":{"input_tokens":7,"output_tokens":3}}'
      ;;
  esac
done
`
	require.NoError(t, os.WriteFile(path, []byte(script), 0o700))
	t.Cleanup(func() {
		if data, err := os.ReadFile(filepath.Join(dir, "pid")); err == nil {
			if pid, _ := strconv.Atoi(strings.TrimSpace(string(data))); pid > 0 {
				_ = syscall.Kill(-pid, syscall.SIGKILL)
			}
		}
	})
	return dir, path
}

func stubArgv(t *testing.T, dir string) []string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(dir, "argv"))
	require.NoError(t, err)
	return strings.Split(strings.TrimSuffix(string(data), "\x00"), "\x00")
}

// A Claude agent() on Live: the stream-json launch, the read tools allowed,
// connector writes disallowed and denied at the gate (logged on the step),
// any other connector denied, the run marked and the status written on use.
// liveClaudeConfig is a Claude agent config with the owner's claude.ai
// connectors on (the default of a real config).
func liveClaudeConfig(bin string) *config.Config {
	cfg := &config.Config{ActiveWorkspace: "acme", ClaudePath: bin, AI: config.AIConfig{Provider: "claude"}}
	cfg.AI.ClaudeAI.Connectors = true
	return cfg
}

// agentStepSummary decodes the run's agent step summary.
func agentStepSummary(t *testing.T, f *agentFixture, runID int64) map[string]any {
	t.Helper()
	var summary map[string]any
	require.NoError(t, json.Unmarshal([]byte(f.agentStep(t, runID).ResultSummary), &summary))
	return summary
}

func TestAgentRun_ClaudeLiveStreamJSON(t *testing.T) {
	dir, bin := writeClaudeStreamStub(t, true)
	t.Setenv("HOME", t.TempDir())
	policytest.Set(t, nil)
	sandboxLog := standInSandbox(t)
	f := liveAgentFixture(t, liveClaudeConfig(bin))
	run := f.run(t, db.TriggerManual)
	require.Equal(t, db.RunSucceeded, run.Status, run.Error)
	assert.Equal(t, "read it", run.Summary)
	assert.Equal(t, 1, liveSlackOf(t, f.d, run.ID))
	sandboxed, err := os.ReadFile(sandboxLog)
	require.NoError(t, err)
	assert.Contains(t, string(sandboxed), bin+"\n", "the connectors' child started inside the file sandbox (CHAT-05)")
	assert.NotContains(t, agentStepSummary(t, f, run.ID), "slack_live_unavailable")

	argv := stubArgv(t, dir)
	joined := strings.Join(argv, " ")
	assert.NotContains(t, argv, "--strict-mcp-config")
	assert.Contains(t, joined, "--input-format stream-json --permission-prompt-tool stdio")
	assert.Contains(t, joined, "--setting-sources project,local")
	allowed := argv[slices.Index(argv, "--allowedTools")+1]
	assert.Contains(t, allowed, "mcp__watchtower__list_targets")
	assert.Contains(t, allowed, "mcp__claude_ai_Slack__slack_read_channel")
	assert.NotContains(t, allowed, "slack_send_message")
	assert.Contains(t, argv[slices.Index(argv, "--disallowedTools")+1], "mcp__claude_ai_Slack__slack_send_message")

	answers, err := os.ReadFile(filepath.Join(dir, "answers"))
	require.NoError(t, err)
	lines := strings.Split(strings.TrimSpace(string(answers)), "\n")
	require.Len(t, lines, 2)
	assert.Contains(t, lines[0], `"behavior":"deny"`)
	assert.Contains(t, lines[0], agentSlackWriteDenied)
	assert.Contains(t, lines[1], `"behavior":"deny"`)
	assert.Contains(t, lines[1], agentToolNotAllowed)

	var summary struct {
		Denied []struct {
			Tool string `json:"tool"`
			OK   bool   `json:"ok"`
		} `json:"slack_live_denied"`
	}
	require.NoError(t, json.Unmarshal([]byte(f.agentStep(t, run.ID).ResultSummary), &summary))
	require.Len(t, summary.Denied, 1)
	assert.Equal(t, "slack_send_message", summary.Denied[0].Tool)

	rows, err := f.d.ListSlackLiveStatus()
	require.NoError(t, err)
	r, ok := newestSlackLive(rows, "claude")
	require.True(t, ok, "the connector call wrote the status")
	assert.Equal(t, "ok", r.Status)
}

// codexLiveFixture is a Live agent() run on a codex stub playing stream; the
// owner's codex home is signed in with ChatGPT and its newest probe is ok
// with a connector id.
func codexLiveFixture(t *testing.T, stream string, probeOK bool) (*claudeStub, *agentFixture) {
	t.Helper()
	stub := newClaudeStub(t, stream)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CODEX_HOME", "")
	require.NoError(t, os.MkdirAll(filepath.Join(home, ".codex"), 0o700))
	require.NoError(t, os.WriteFile(filepath.Join(home, ".codex", "auth.json"), []byte(`{"auth_mode":"chatgpt"}`), 0o600))
	cfg := &config.Config{ActiveWorkspace: "acme", CodexPath: stub.path, AI: config.AIConfig{Provider: "codex"}}
	f := liveAgentFixture(t, cfg)
	if probeOK {
		require.NoError(t, f.d.UpsertSlackLiveStatus(db.SlackLiveStatus{Provider: "codex", Status: "ok",
			ConnectorID: "connector_abc", CheckedAt: time.Now().Add(-time.Hour)}))
	}
	return stub, f
}

const codexSlackReadStream = `{"type":"turn.started"}
{"type":"item.completed","item":{"id":"s1","type":"mcp_tool_call","server":"codex_apps","tool":"slack.slack_read_channel","arguments":{},"result":{"content":[{"type":"text","text":"hello"}]},"status":"completed"}}
{"type":"item.completed","item":{"id":"m","type":"agent_message","text":"read it"}}
{"type":"turn.completed","usage":{"input_tokens":7,"output_tokens":3}}`

func TestAgentRun_CodexMarksUsedSlackLive(t *testing.T) {
	stub, f := codexLiveFixture(t, codexSlackReadStream, true)
	run := f.run(t, db.TriggerManual)
	require.Equal(t, db.RunSucceeded, run.Status, run.Error)
	assert.Equal(t, 1, liveSlackOf(t, f.d, run.ID))
	argv := strings.Join(stub.argv(t), " ")
	assert.Contains(t, argv, "features.apps=true")
	assert.Contains(t, argv, "apps.connector_abc.tools.slack_read_channel.enabled=true")
	for _, w := range slackconnector.WriteTools {
		assert.NotContains(t, argv, w, "no connector write is visible to the Codex agent")
	}
	rows, err := f.d.ListSlackLiveStatus()
	require.NoError(t, err)
	r, ok := newestSlackLive(rows, "codex")
	require.True(t, ok)
	assert.Equal(t, "ok", r.Status)
	assert.Equal(t, "connector_abc", r.ConnectorID, "the status on use keeps the probe's connector id")
	assert.WithinDuration(t, time.Now(), r.CheckedAt, time.Minute, "the use refreshed the status")
}

// Without an ok Codex probe the run gets no apps at all (fail closed) and is
// not marked.
func TestAgentRun_CodexLiveWithoutProbeHasNoApps(t *testing.T) {
	stub, f := codexLiveFixture(t, codexResponses(1), false)
	run := f.run(t, db.TriggerManual)
	require.Equal(t, db.RunSucceeded, run.Status, run.Error)
	assert.Equal(t, 0, liveSlackOf(t, f.d, run.ID))
	assert.NotContains(t, strings.Join(stub.argv(t), " "), "features.apps=true")
	assert.Equal(t, "no passing Live Slack check for Codex with a ChatGPT login",
		agentStepSummary(t, f, run.ID)["slack_live_unavailable"], "the run log says why Live was off")
}

// claudeLiveOffCase runs a Live Claude agent() whose Live is off for a
// reason before launch: the child keeps today's argv (no stream-json, no
// connectors), the run succeeds unmarked and the step says why.
func claudeLiveOffCase(t *testing.T, cfg *config.Config, want string) {
	t.Helper()
	stub := newClaudeStub(t, `{"type":"result","subtype":"success","is_error":false,"result":"done","usage":{"input_tokens":7,"output_tokens":3}}`)
	cfg.ClaudePath = stub.path
	t.Setenv("HOME", t.TempDir())
	standInSandbox(t)
	f := liveAgentFixture(t, cfg)
	run := f.run(t, db.TriggerManual)
	require.Equal(t, db.RunSucceeded, run.Status, run.Error)
	assert.Equal(t, 0, liveSlackOf(t, f.d, run.ID))
	argv := stub.argv(t)
	assert.Contains(t, argv, "--strict-mcp-config", "no claude.ai connectors load")
	assert.NotContains(t, argv, "--input-format")
	assert.Contains(t, agentStepSummary(t, f, run.ID)["slack_live_unavailable"], want)
}

// AllowClaudeAITools=false (MDM, #608) covers automation Live: no
// connectors, the run log says the policy turned it off.
func TestAgentRun_ClaudeLivePolicyOff(t *testing.T) {
	policytest.Set(t, map[string]any{"AllowClaudeAITools": false})
	claudeLiveOffCase(t, liveClaudeConfig(""), "organization's policy")
}

// The owner's claude.ai connectors switch and the Slack connector switched
// off one by one cover automation Live.
func TestAgentRun_ClaudeLiveOwnerSwitchesOff(t *testing.T) {
	policytest.Set(t, nil)
	cfg := liveClaudeConfig("")
	cfg.AI.ClaudeAI.Connectors = false
	claudeLiveOffCase(t, cfg, "connectors are switched off")
	cfg = liveClaudeConfig("")
	cfg.AI.ClaudeAI.DisabledConnectors = []string{"Slack"}
	claudeLiveOffCase(t, cfg, "Slack connector is switched off")
}

// A failed newest Claude probe keeps Live off for the run.
func TestAgentRun_ClaudeLiveFailedProbeOff(t *testing.T) {
	policytest.Set(t, nil)
	stub := newClaudeStub(t, `{"type":"result","subtype":"success","is_error":false,"result":"done","usage":{"input_tokens":7,"output_tokens":3}}`)
	t.Setenv("HOME", t.TempDir())
	standInSandbox(t)
	f := liveAgentFixture(t, liveClaudeConfig(stub.path))
	require.NoError(t, f.d.UpsertSlackLiveStatus(db.SlackLiveStatus{Provider: "claude", Status: "no_plan", ErrorClass: "plan",
		CheckedAt: time.Now().Add(-time.Hour)}))
	run := f.run(t, db.TriggerManual)
	require.Equal(t, db.RunSucceeded, run.Status, run.Error)
	assert.Contains(t, stub.argv(t), "--strict-mcp-config")
	assert.Contains(t, agentStepSummary(t, f, run.ID)["slack_live_unavailable"], "did not pass")
}

// No file sandbox: the Live run fails and no child starts (fail closed).
func TestAgentRun_ClaudeLiveWithoutSandboxFails(t *testing.T) {
	policytest.Set(t, nil)
	dir, bin := writeClaudeStreamStub(t, true)
	t.Setenv("HOME", t.TempDir())
	prev := aiSessionSandbox
	aiSessionSandbox = func() (*chat.ChildSandbox, error) { return nil, errors.New("no sandbox-exec") }
	t.Cleanup(func() { aiSessionSandbox = prev })
	f := liveAgentFixture(t, liveClaudeConfig(bin))
	run := f.run(t, db.TriggerManual)
	assert.Equal(t, db.RunFailed, run.Status)
	assert.Contains(t, run.Error, "file sandbox")
	_, err := os.Stat(filepath.Join(dir, "pid"))
	assert.ErrorIs(t, err, os.ErrNotExist, "no child started")
}

// The claude.ai Slack connector never connects: the agent runs without it
// and the run log says so (not only a log line).
func TestAgentRun_ClaudeLiveConnectorNotConnected(t *testing.T) {
	policytest.Set(t, nil)
	old := agentSlackConnectWait
	agentSlackConnectWait = 50 * time.Millisecond
	t.Cleanup(func() { agentSlackConnectWait = old })
	_, bin := writeClaudeStreamStub(t, false)
	t.Setenv("HOME", t.TempDir())
	standInSandbox(t)
	f := liveAgentFixture(t, liveClaudeConfig(bin))
	run := f.run(t, db.TriggerManual)
	require.Equal(t, db.RunSucceeded, run.Status, run.Error)
	assert.Contains(t, agentStepSummary(t, f, run.ID)["slack_live_unavailable"], "did not connect")
}

// The stream-json mode is opt-in: an agent() child of a recipe without
// slack:live keeps today's argv byte for byte (claude), and codex gets no
// apps.
func TestAgentRun_NoSlackLiveKeepsArgv(t *testing.T) {
	stub := newClaudeStub(t, `{"type":"result","subtype":"success","is_error":false,"result":"done","usage":{"input_tokens":7,"output_tokens":3}}`)
	f := newAgentFixture(t, stub.config(t), `return agent("triage").text`, "")
	run := f.run(t, db.TriggerManual)
	require.Equal(t, db.RunSucceeded, run.Status, run.Error)
	argv := stub.argv(t)
	i := slices.Index(argv, "--mcp-config")
	require.Greater(t, i, 0)
	argv[i+1] = "<mcp-config>"
	assert.Equal(t, []string{"-p", "--output-format", "json", "--model", argv[4],
		"--allowedTools", "mcp__watchtower__create_target,mcp__watchtower__list_targets,mcp__watchtower__get_action",
		"--tools", ai.ChatBuiltinTools, "--disallowedTools", ai.DisallowedTools, "--setting-sources", "project,local", "--strict-mcp-config",
		"--max-turns", "12", "--mcp-config", "<mcp-config>", "--no-session-persistence", "--system-prompt-file", "/dev/fd/3"}, argv)

	cstub, cf := codexAgentFixture(t, codexResponses(1), codexRollout(1), false)
	crun := cf.run(t, db.TriggerManual)
	require.Equal(t, db.RunSucceeded, crun.Status, crun.Error)
	assert.NotContains(t, strings.Join(cstub.argv(t), " "), "features.apps=true")
	assert.Equal(t, 0, liveSlackOf(t, cf.d, crun.ID))
}

func TestAgentSlackLive_Gate(t *testing.T) {
	l := newAgentSlackLive(nil, "claude")
	req := func(id, tool string) string {
		return `{"type":"control_request","request_id":"` + id + `","request":{"subtype":"can_use_tool","tool_name":"` + tool + `","input":{"a":1}}}`
	}
	assert.Contains(t, l.claudeControl(req("1", "mcp__claude_ai_Slack__slack_read_thread")), `"behavior":"allow"`)
	deny := l.claudeControl(req("2", "mcp__claude_ai_Slack__slack_update_canvas"))
	assert.Contains(t, deny, `"behavior":"deny"`)
	assert.Contains(t, deny, agentSlackWriteDenied)
	assert.Contains(t, l.claudeControl(req("3", "Bash")), agentToolNotAllowed)
	assert.Contains(t, l.claudeControl(`{"type":"control_request","request_id":"4","request":{"subtype":"hook_callback"}}`), `"subtype":"error"`)
	assert.Empty(t, l.claudeControl(`{"type":"assistant"}`))
	used, denied := l.result()
	assert.False(t, used)
	assert.Equal(t, []string{"slack_update_canvas"}, denied)

	l.claudeHooks().OnToolResult("mcp__claude_ai_Slack__slack_read_channel", false, "x")
	used, _ = l.result()
	assert.True(t, used)

	c := newAgentSlackLive(nil, "codex")
	c.observeCodex(codexToolCall("watchtower", "list_targets"))
	c.observeCodex(codexToolCall("codex_apps", "gmail.search"))
	used, _ = c.result()
	assert.False(t, used)
	c.observeCodex(codexToolCall("codex_apps", "slack.slack_search_public"))
	used, _ = c.result()
	assert.True(t, used)
}

func codexToolCall(server, tool string) codex.ToolCall {
	return codex.ToolCall{Server: server, Tool: tool}
}
