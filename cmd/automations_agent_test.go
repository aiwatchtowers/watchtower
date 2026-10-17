package cmd

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/automations"
	"watchtower/internal/automations/automationstest"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

// agentRecipeText is a manual recipe allowed agent:run, the light tier, one
// read and one write tool; SCRIPT and EXTRA (more frontmatter) are replaced.
func agentRecipeText(script, extra string) string {
	return "---\nname: Agent test\ntrigger:\n  manual: true\npermissions:\n  - agent:run\n  - llm:light\n" +
		"  - tool:list_targets\n  - tool:create_target\noutputs: [report]\n" + extra + "---\nAn agent() test recipe.\n\n```js\n" +
		script + "\n```\n"
}

// agentFixture runs one recipe through an executor built on the production
// backends (automationBackends) for cfg.
type agentFixture struct {
	d    *db.DB
	a    db.Automation
	exec *automations.Executor
}

func newAgentFixture(t *testing.T, cfg *config.Config, script, extra string) *agentFixture {
	t.Helper()
	d := db.OpenTestDB(t)
	a := automationstest.SeedAutomation(t, d, agentRecipeText(script, extra), automationstest.SeedOptions{Slug: "agent-test"})
	exec := automations.NewExecutor(d, automationBackends(cfg, d, &automationstest.FakeGenerator{Replies: []string{"ok"}}),
		automations.ExecutorOptions{})
	return &agentFixture{d: d, a: a, exec: exec}
}

func (f *agentFixture) enqueue(t *testing.T, trigger string) int64 {
	t.Helper()
	id, _, err := f.d.EnqueueAutomationRun(db.EnqueueRequest{AutomationID: f.a.ID, Trigger: trigger, Now: time.Now()})
	require.NoError(t, err)
	return id
}

// run executes one run of trigger inline and returns it as stored.
func (f *agentFixture) run(t *testing.T, trigger string) *db.AutomationRun {
	t.Helper()
	id := f.enqueue(t, trigger)
	_, err := f.exec.ExecuteInline(context.Background(), id)
	require.NoError(t, err)
	run, err := f.d.GetAutomationRun(id)
	require.NoError(t, err)
	return run
}

// agentStep is the run's one agent step.
func (f *agentFixture) agentStep(t *testing.T, runID int64) db.AutomationRunStep {
	t.Helper()
	steps, err := f.d.ListAutomationRunSteps(runID)
	require.NoError(t, err)
	i := slices.IndexFunc(steps, func(s db.AutomationRunStep) bool { return s.Kind == automations.StepKindAgent })
	require.GreaterOrEqual(t, i, 0, "steps: %+v", steps)
	return steps[i]
}

// fakeOpenAI is an OpenAI-compatible server: reply(i) answers request i; it
// records the tool names each request advertised.
type fakeOpenAI struct {
	reply func(i int) map[string]any

	mu    sync.Mutex
	tools [][]string
}

func newFakeOpenAI(t *testing.T, reply func(i int) map[string]any) (*fakeOpenAI, *httptest.Server) {
	t.Helper()
	f := &fakeOpenAI{reply: reply}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Tools []struct {
				Function struct {
					Name string `json:"name"`
				} `json:"function"`
			} `json:"tools"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		names := []string{}
		for _, tl := range req.Tools {
			names = append(names, tl.Function.Name)
		}
		f.mu.Lock()
		i := len(f.tools)
		f.tools = append(f.tools, names)
		f.mu.Unlock()
		_ = json.NewEncoder(w).Encode(f.reply(i))
	}))
	t.Cleanup(srv.Close)
	return f, srv
}

func (f *fakeOpenAI) requests() [][]string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.tools)
}

func toolCallReply(name, args string, in, out int) map[string]any {
	return map[string]any{
		"choices": []any{map[string]any{"message": map[string]any{"role": "assistant",
			"tool_calls": []any{map[string]any{"id": "c1", "type": "function",
				"function": map[string]any{"name": name, "arguments": args}}}}}},
		"usage": map[string]any{"prompt_tokens": in, "completion_tokens": out, "total_tokens": in + out},
	}
}

func textReply(text string, in, out int) map[string]any {
	return map[string]any{
		"choices": []any{map[string]any{"message": map[string]any{"role": "assistant", "content": text}}},
		"usage":   map[string]any{"prompt_tokens": in, "completion_tokens": out, "total_tokens": in + out},
	}
}

// ollamaConfig is a runtime-B config on the fake server.
func ollamaConfig(t *testing.T, url string) *config.Config {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	return &config.Config{ActiveWorkspace: "acme", AI: config.AIConfig{Provider: "ollama", OllamaURL: url}}
}

func TestAgent_IterationsCapped12(t *testing.T) {
	srv, ts := newFakeOpenAI(t, func(int) map[string]any { return toolCallReply("list_targets", `{}`, 10, 5) })
	f := newAgentFixture(t, ollamaConfig(t, ts.URL), `return agent("loop forever").text`, "")
	run := f.run(t, db.TriggerManual)
	assert.Equal(t, db.RunSucceeded, run.Status, run.Error)
	assert.Len(t, srv.requests(), 12, "runtime B stops at 12 model calls")
	step := f.agentStep(t, run.ID)
	assert.Equal(t, "runtime-b", step.Name)
	assert.Equal(t, int64(120), step.InputTokens, "each model call is debited on the step")
	assert.Equal(t, int64(120), run.InputTokens)
	assert.Equal(t, int64(60), run.OutputTokens)
	assert.False(t, run.TokensEstimated)
}

func TestAgent_WritesStayProposals(t *testing.T) {
	_, ts := newFakeOpenAI(t, func(i int) map[string]any {
		if i == 0 {
			return toolCallReply("create_target", `{"text":"Ship the PAY report","reason":"the owner asked"}`, 10, 5)
		}
		return textReply("filed", 10, 5)
	})
	f := newAgentFixture(t, ollamaConfig(t, ts.URL), `const r = agent("file it", {tools: ["create_target"]}); return r.actions.length`, "")
	// An active auto grant does not cover a call inside agent() (AGENT-03).
	require.NoError(t, f.d.SetAutomationToolGrant(f.a.ID, "create_target", f.a.ApprovalHash, time.Now()))

	run := f.run(t, db.TriggerManual)
	require.Equal(t, db.RunSucceeded, run.Status, run.Error)
	actions, err := f.d.ListAgentActions(db.AgentActionFilter{})
	require.NoError(t, err)
	require.Len(t, actions, 1)
	row := actions[0]
	assert.Equal(t, "pending", row.Status)
	assert.Equal(t, "ask", row.TrustAtCreate)
	assert.Equal(t, "automation_run", row.ContextType)
	assert.Equal(t, strconv.FormatInt(run.ID, 10), row.ContextID)
	var targets int
	require.NoError(t, f.d.QueryRow(`SELECT COUNT(*) FROM targets`).Scan(&targets))
	assert.Zero(t, targets, "nothing executed")
	assert.JSONEq(t, `{"text":"filed","actions":[`+strconv.FormatInt(row.ID, 10)+`]}`, f.agentStep(t, run.ID).ResultSummary)
}

func TestAgent_LocalBudgetSpentThrowsCatchable(t *testing.T) {
	srv, ts := newFakeOpenAI(t, func(int) map[string]any { return toolCallReply("list_targets", `{}`, 5000, 1000) })
	f := newAgentFixture(t, ollamaConfig(t, ts.URL),
		`try { agent("x", {budget: {tokens: 5000}}); return "ran" } catch (e) { if (e.name !== "BudgetExceeded") throw e; return "caught" }`, "")
	run := f.run(t, db.TriggerManual)
	assert.Equal(t, db.RunSucceeded, run.Status, run.Error)
	assert.Len(t, srv.requests(), 1, "the carve is spent after the first model call")
	assert.Equal(t, int64(6000), run.InputTokens+run.OutputTokens)
	assert.Equal(t, automations.StepError, f.agentStep(t, run.ID).Status)
}

func TestAgent_RunBudgetCrossedInterruptsRun(t *testing.T) {
	srv, ts := newFakeOpenAI(t, func(int) map[string]any { return toolCallReply("list_targets", `{}`, 1500, 500) })
	f := newAgentFixture(t, ollamaConfig(t, ts.URL), `try { agent("x") } catch (e) {} return "ran"`, "budget: {tokens: 1000}\n")
	run := f.run(t, db.TriggerManual)
	assert.Equal(t, db.RunBudgetExceeded, run.Status, run.Error)
	assert.Equal(t, db.ErrKindBudget, run.ErrorKind)
	assert.Len(t, srv.requests(), 1)
}

// AUTO-12: a dry run's agent() is offered no write tool, on runtime B and on
// the CLI child alike.
func TestAgent_DryRunRemovesWriteTools(t *testing.T) {
	t.Run("runtime B", func(t *testing.T) {
		srv, ts := newFakeOpenAI(t, func(int) map[string]any { return textReply("nothing to do", 1, 1) })
		f := newAgentFixture(t, ollamaConfig(t, ts.URL), `return agent("x").text`, "")
		run := f.run(t, db.TriggerDryRun)
		require.Equal(t, db.RunSucceeded, run.Status, run.Error)
		reqs := srv.requests()
		require.Len(t, reqs, 1)
		assert.Contains(t, reqs[0], "list_targets")
		assert.NotContains(t, reqs[0], "create_target")
	})
	t.Run("claude", func(t *testing.T) {
		stub := newClaudeStub(t, `{"type":"result","result":"done","usage":{"input_tokens":1,"output_tokens":1}}`)
		f := newAgentFixture(t, stub.config(t), `return agent("x").text`, "")
		run := f.run(t, db.TriggerDryRun)
		require.Equal(t, db.RunSucceeded, run.Status, run.Error)
		argv := stub.argv(t)
		assert.Equal(t, "mcp__watchtower__list_targets,mcp__watchtower__get_action", flagAfter(t, argv, "--allowedTools"))
		assert.Equal(t, "list_targets", flagAfter(t, stub.mcpArgs(t), "--automation-tools"))
	})
}

// claudeStub is a fake claude (or codex) CLI: it records its environment,
// its argv and a codex child's CODEX_HOME config.toml, writes its pid, sleeps
// ignoring SIGINT when its dir holds a "sleep" file, exits 1 with no output
// when it holds a "fail" file, and prints reply. It touches the server's
// ready file (as a started `watchtower mcp` would) unless it holds a
// "noserver" file.
type claudeStub struct {
	dir, path string
}

const claudeStubName = "wt-agent-claude-stub"

func newClaudeStub(t *testing.T, reply string) *claudeStub {
	t.Helper()
	dir := t.TempDir()
	s := &claudeStub{dir: dir, path: filepath.Join(dir, claudeStubName)}
	require.NoError(t, os.WriteFile(filepath.Join(dir, "reply"), []byte(reply), 0o600))
	script := "#!/bin/sh\n" +
		"env > '" + dir + "/env'\n" +
		"for a in \"$@\"; do printf '%s\\0' \"$a\"; done > '" + dir + "/argv'\n" +
		"if [ -n \"$CODEX_HOME\" ]; then echo \"$CODEX_HOME\" > '" + dir + "/codex-home'; cp \"$CODEX_HOME/config.toml\" '" + dir + "/codex-home.toml'; " +
		"readlink \"$CODEX_HOME/auth.json\" > '" + dir + "/codex-auth-link'; fi\n" +
		// Act as the bound server starting: touch the ready file the
		// watchtower server's args name (in --mcp-config or the codex TOML),
		// unless the dir holds a "noserver" file.
		"{ for a in \"$@\"; do printf '%s\\n' \"$a\"; done; cat '" + dir + "/codex-home.toml' 2>/dev/null; } > '" + dir + "/allargs'\n" +
		"rf=$(sed -n 's/.*\"--automation-ready-file\", *\"\\([^\"]*\\)\".*/\\1/p' '" + dir + "/allargs' | head -n 1)\n" +
		"if [ -n \"$rf\" ] && [ ! -f '" + dir + "/noserver' ]; then : > \"$rf\"; fi\n" +
		"echo $$ > '" + dir + "/pid'\n" +
		"if [ -f '" + dir + "/sleep' ]; then trap '' INT; exec sleep 30; fi\n" +
		"if [ -f '" + dir + "/fail' ]; then exit 1; fi\n" +
		"cat '" + dir + "/reply'\n"
	require.NoError(t, os.WriteFile(s.path, []byte(script), 0o700))
	t.Cleanup(func() {
		if pid := s.pid(); pid > 0 {
			_ = syscall.Kill(-pid, syscall.SIGKILL)
		}
	})
	return s
}

func (s *claudeStub) config(t *testing.T) *config.Config {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	return &config.Config{ActiveWorkspace: "acme", ClaudePath: s.path, AI: config.AIConfig{Provider: "claude"}}
}

// pid is the stub's last pid (its process group), 0 before it ran.
func (s *claudeStub) pid() int {
	data, err := os.ReadFile(filepath.Join(s.dir, "pid"))
	if err != nil {
		return 0
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(data)))
	return pid
}

func (s *claudeStub) argv(t *testing.T) []string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(s.dir, "argv"))
	require.NoError(t, err)
	return strings.Split(strings.TrimSuffix(string(data), "\x00"), "\x00")
}

// env is the stub's environment without what the shell adds itself.
func (s *claudeStub) env(t *testing.T) []string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(s.dir, "env"))
	require.NoError(t, err)
	var out []string
	for _, l := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if k, _, _ := strings.Cut(l, "="); k == "PWD" || k == "SHLVL" || k == "_" || k == "OLDPWD" {
			continue
		}
		out = append(out, l)
	}
	return out
}

// mcpServers is the --mcp-config the stub was given.
func (s *claudeStub) mcpServers(t *testing.T) map[string]struct {
	Args []string `json:"args"`
} {
	t.Helper()
	var cfg struct {
		MCPServers map[string]struct {
			Args []string `json:"args"`
		} `json:"mcpServers"`
	}
	require.NoError(t, json.Unmarshal([]byte(flagAfter(t, s.argv(t), "--mcp-config")), &cfg))
	return cfg.MCPServers
}

// mcpArgs is the watchtower server's argv in the stub's --mcp-config.
func (s *claudeStub) mcpArgs(t *testing.T) []string {
	t.Helper()
	srv, ok := s.mcpServers(t)["watchtower"]
	require.True(t, ok)
	return srv.Args
}

func flagAfter(t *testing.T, args []string, flag string) string {
	t.Helper()
	i := slices.Index(args, flag)
	require.GreaterOrEqual(t, i, 0, "%s missing from %q", flag, args)
	require.Less(t, i+1, len(args))
	return args[i+1]
}

func TestAgent_CLIChildEnvHasRunMarkerAndNoSecrets(t *testing.T) {
	stub := newClaudeStub(t, `{"type":"result","result":"done","usage":{"input_tokens":1,"output_tokens":1}}`)
	cfg := stub.config(t)
	home := os.Getenv("HOME")
	t.Setenv("LANG", "en_US.UTF-8")
	t.Setenv("USER", "acme")
	t.Setenv("CLAUDECODE", "1")
	t.Setenv("WT_FAKE_SECRET", "s3cret")
	t.Setenv("SLACK_TOKEN", "xoxp-fake")
	t.Setenv("ANTHROPIC_API_KEY", "sk-fake")
	t.Setenv("CLAUDE_CODE_OAUTH_TOKEN", "oauth-fake")
	t.Setenv("OPENAI_API_KEY", "sk-openai-fake")
	// An exported CODEX_HOME is the owner's, never the claude child's.
	t.Setenv("CODEX_HOME", filepath.Join(t.TempDir(), "acme-codex-home"))
	// The allowed network plumbing (owner ask #185); no_proxy is left unset.
	allowed := map[string]string{
		"HTTPS_PROXY": "http://proxy.example.com:3128", "HTTP_PROXY": "http://proxy.example.com:3128",
		"NO_PROXY": "localhost", "https_proxy": "http://proxy.example.com:3128",
		"http_proxy": "http://proxy.example.com:3128", "ALL_PROXY": "socks5://proxy.example.com:1080",
		"all_proxy": "socks5://proxy.example.com:1080", "NODE_EXTRA_CA_CERTS": "/etc/ca/extra.pem",
		"SSL_CERT_FILE": "/etc/ca/cert.pem", "SSL_CERT_DIR": "/etc/ca/certs", "TMPDIR": t.TempDir(),
	}
	for k, v := range allowed {
		t.Setenv(k, v)
	}
	t.Setenv("no_proxy", "")
	require.NoError(t, os.Unsetenv("no_proxy"))
	configPath := setFlagConfig(t)
	f := newAgentFixture(t, cfg, `return agent("triage").text`, "")
	_, err := f.d.InsertExternalConnection(db.ExternalConnection{Name: "github", Kind: "stdio", Command: "/bin/false", Enabled: true})
	require.NoError(t, err)

	run := f.run(t, db.TriggerManual)
	require.Equal(t, db.RunSucceeded, run.Status, run.Error)
	runID := strconv.FormatInt(run.ID, 10)

	env := stub.env(t)
	keys := make([]string, 0, len(env))
	for _, e := range env {
		k, _, _ := strings.Cut(e, "=")
		keys = append(keys, k)
	}
	slices.Sort(keys)
	wantKeys := []string{"HOME", "LANG", "PATH", "USER", automations.RunEnvMarker}
	for k := range allowed {
		wantKeys = append(wantKeys, k)
	}
	slices.Sort(wantKeys)
	assert.Equal(t, wantKeys, keys, "env: %q", env)
	for k, v := range allowed {
		assert.Contains(t, env, k+"="+v)
	}
	for _, secret := range []string{"SLACK_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "CLAUDECODE", "WT_FAKE_SECRET"} {
		assert.NotContains(t, strings.Join(keys, " "), secret)
	}
	assert.Contains(t, env, "HOME="+home)
	assert.Contains(t, env, "LANG=en_US.UTF-8")
	assert.Contains(t, env, "USER=acme")
	assert.Contains(t, env, automations.RunEnvMarker+"="+runID)

	argv := stub.argv(t)
	assert.Equal(t, "12", flagAfter(t, argv, "--max-turns"))
	assert.Equal(t, "mcp__watchtower__create_target,mcp__watchtower__list_targets,mcp__watchtower__get_action",
		flagAfter(t, argv, "--allowedTools"), "one token per tool, never the whole server")
	servers := stub.mcpServers(t)
	assert.Len(t, servers, 1, "no Quick Connection server: %v", servers)
	mcpArgs := stub.mcpArgs(t)
	assert.Equal(t, "automation", flagAfter(t, mcpArgs, "--surface"))
	assert.Equal(t, runID, flagAfter(t, mcpArgs, "--automation-run"))
	assert.Equal(t, "create_target,list_targets", flagAfter(t, mcpArgs, "--automation-tools"))
	assert.Contains(t, mcpArgs, "--chat")
	// The env drops WATCHTOWER_CONFIG_PATH: the server is pointed at this
	// process's config file and workspace instead.
	assert.Equal(t, configPath, flagAfter(t, mcpArgs, "--config"))
	assert.Equal(t, "acme", flagAfter(t, mcpArgs, "--workspace"))
}

// setFlagConfig points --config at a file in a temp dir for the test and
// returns its path.
func setFlagConfig(t *testing.T) string {
	t.Helper()
	original := flagConfig
	t.Cleanup(func() { flagConfig = original })
	flagConfig = filepath.Join(t.TempDir(), "config.yaml")
	return flagConfig
}

func TestAgent_CLIUsageDebitedOrEstimated(t *testing.T) {
	stub := newClaudeStub(t, `{"type":"result","result":"done","total_cost_usd":0.0125,"usage":{"input_tokens":120,"output_tokens":30}}`)
	f := newAgentFixture(t, stub.config(t), `return agent("triage the inbox").text`, "")
	run := f.run(t, db.TriggerManual)
	require.Equal(t, db.RunSucceeded, run.Status, run.Error)
	assert.Equal(t, int64(120), run.InputTokens)
	assert.Equal(t, int64(30), run.OutputTokens)
	assert.False(t, run.TokensEstimated)
	require.NotNil(t, run.ReportedCostUSD, "claude's total_cost_usd is stored")
	assert.InDelta(t, 0.0125, *run.ReportedCostUSD, 1e-9)
	step := f.agentStep(t, run.ID)
	assert.Equal(t, "claude", step.Name)
	assert.Equal(t, int64(120), step.InputTokens)
	require.NotNil(t, step.ReportedCostUSD)
	assert.InDelta(t, 0.0125, *step.ReportedCostUSD, 1e-9)

	require.NoError(t, os.WriteFile(filepath.Join(stub.dir, "reply"), []byte(`{"type":"result","result":"done","usage":{}}`), 0o600))
	run = f.run(t, db.TriggerManual)
	require.Equal(t, db.RunSucceeded, run.Status, run.Error)
	want := int64(len("triage the inbox")+len("done")+3) / 4
	assert.Equal(t, want, run.InputTokens+run.OutputTokens, "ceil(len(instruction+text)/4)")
	assert.True(t, run.TokensEstimated)
	assert.True(t, f.agentStep(t, run.ID).TokensEstimated)

	// A child that fails (or is killed) reports nothing: its instruction is
	// still debited as an estimate.
	require.NoError(t, os.WriteFile(filepath.Join(stub.dir, "fail"), nil, 0o600))
	run = f.run(t, db.TriggerManual)
	require.Equal(t, db.RunFailed, run.Status)
	assert.Equal(t, int64(len("triage the inbox")+3)/4, run.InputTokens+run.OutputTokens, "ceil(len(instruction)/4)")
	assert.True(t, run.TokensEstimated)
}

// A child whose bound watchtower server never started (no ready file)
// answered with no tools: agent() fails with a ToolError, its usage still
// debited.
func TestAgent_CLIServerNeverStartedIsToolError(t *testing.T) {
	stub := newClaudeStub(t, `{"type":"result","result":"done","usage":{"input_tokens":40,"output_tokens":10}}`)
	require.NoError(t, os.WriteFile(filepath.Join(stub.dir, "noserver"), nil, 0o600))
	f := newAgentFixture(t, stub.config(t), `return agent("triage").text`, "")
	run := f.run(t, db.TriggerManual)
	require.Equal(t, db.RunFailed, run.Status)
	assert.Contains(t, run.Error, "ToolError")
	assert.Contains(t, run.Error, "agent(): the watchtower tools never connected (the bound MCP server did not start)")
	assert.Equal(t, int64(50), run.InputTokens+run.OutputTokens, "the usage is still debited")
	step := f.agentStep(t, run.ID)
	assert.Equal(t, automations.StepError, step.Status)
	assert.Contains(t, step.Error, "never connected")
	assert.Contains(t, flagAfter(t, stub.mcpArgs(t), "--automation-ready-file"), "wt-agent-ready-")
}

func TestAgent_CancelKillsCLIChild(t *testing.T) {
	stub := newClaudeStub(t, `{"type":"result","result":"done","usage":{}}`)
	require.NoError(t, os.WriteFile(filepath.Join(stub.dir, "sleep"), nil, 0o600))
	f := newAgentFixture(t, stub.config(t), `return agent("x").text`, "")
	id := f.enqueue(t, db.TriggerManual)
	done := make(chan error, 1)
	go func() {
		_, err := f.exec.ExecuteInline(context.Background(), id)
		done <- err
	}()
	deadline := time.Now().Add(10 * time.Second)
	for stub.pid() == 0 {
		require.True(t, time.Now().Before(deadline), "the stub never started")
		time.Sleep(10 * time.Millisecond)
	}
	pid := stub.pid()
	ok, err := f.d.CancelAutomationRun(id, time.Now())
	require.NoError(t, err)
	require.True(t, ok)
	f.exec.Wake()
	select {
	case err := <-done:
		require.NoError(t, err)
	case <-time.After(15 * time.Second):
		t.Fatal("the run did not end after its cancel")
	}
	run, err := f.d.GetAutomationRun(id)
	require.NoError(t, err)
	assert.Equal(t, db.RunCancelled, run.Status)
	// The SIGINT-ignoring child is SIGKILLed within the sandbox's
	// AbandonGrace: the call returns with the group dead, so the run is not
	// abandoned (which would disable the automation) and a stopping daemon,
	// which waits for its runs, cannot outlive the child.
	assert.True(t, errors.Is(syscall.Kill(-pid, 0), syscall.ESRCH), "the stub's process group is gone")
	a, err := f.d.GetAutomation(f.a.ID)
	require.NoError(t, err)
	assert.True(t, a.Enabled, "a cancelled agent() run is not abandoned")
}

func TestAgent_CodexChildBoundToRun(t *testing.T) {
	stub := newClaudeStub(t, `{"type":"item.completed","item":{"type":"agent_message","text":"done"}}`+"\n"+
		`{"type":"turn.completed","usage":{"input_tokens":7,"output_tokens":3}}`)
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CODEX_HOME", "")
	t.Setenv("WT_FAKE_SECRET", "s3cret")
	// The owner's own codex home: a sign-in and a personal MCP server.
	ownerHome := filepath.Join(home, ".codex")
	require.NoError(t, os.MkdirAll(ownerHome, 0o700))
	require.NoError(t, os.WriteFile(filepath.Join(ownerHome, "auth.json"), []byte(`{"fake":true}`), 0o600))
	require.NoError(t, os.WriteFile(filepath.Join(ownerHome, "config.toml"),
		[]byte("[mcp_servers.personal]\ncommand = \"/bin/false\"\n"), 0o600))
	cfg := &config.Config{ActiveWorkspace: "acme", CodexPath: stub.path, AI: config.AIConfig{Provider: "codex"}}
	f := newAgentFixture(t, cfg, `return agent("triage").text`, "")
	run := f.run(t, db.TriggerManual)
	require.Equal(t, db.RunSucceeded, run.Status, run.Error)
	assert.Equal(t, "codex", f.agentStep(t, run.ID).Name)
	assert.Equal(t, int64(10), run.InputTokens+run.OutputTokens)

	runID := strconv.FormatInt(run.ID, 10)
	assert.Contains(t, stub.env(t), automations.RunEnvMarker+"="+runID)
	assert.NotContains(t, strings.Join(stub.env(t), "\n"), "WT_FAKE_SECRET")
	// CODEX_HOME is a scrubbed per-run home: web search off, only the
	// watchtower server, the owner's sign-in linked; gone after the run.
	codexHome, err := os.ReadFile(filepath.Join(stub.dir, "codex-home"))
	require.NoError(t, err)
	scrubbed := strings.TrimSpace(string(codexHome))
	assert.NotEqual(t, ownerHome, scrubbed)
	assert.Contains(t, stub.env(t), "CODEX_HOME="+scrubbed)
	homeTOML, err := os.ReadFile(filepath.Join(stub.dir, "codex-home.toml"))
	require.NoError(t, err)
	assert.Contains(t, string(homeTOML), `web_search = "disabled"`)
	assert.Contains(t, string(homeTOML), "[mcp_servers.watchtower]")
	assert.Equal(t, 1, strings.Count(string(homeTOML), "[mcp_servers."), "no server of the owner's: %s", homeTOML)
	assert.Contains(t, string(homeTOML), `"--surface", "automation", "--automation-run", "`+runID+`", "--automation-tools", "create_target,list_targets"`)
	// codex starts MCP servers with a filtered environment: the run marker
	// the server checks is passed through by name.
	assert.Contains(t, string(homeTOML), `env_vars = ["`+automations.RunEnvMarker+`"]`)
	link, err := os.ReadFile(filepath.Join(stub.dir, "codex-auth-link"))
	require.NoError(t, err)
	assert.Equal(t, filepath.Join(ownerHome, "auth.json"), strings.TrimSpace(string(link)))
	_, err = os.Stat(scrubbed)
	assert.True(t, os.IsNotExist(err), "the per-run home is removed")
	_, err = os.Stat(filepath.Join(ownerHome, "auth.json"))
	assert.NoError(t, err, "the owner's sign-in is untouched")
}

// Both executors that run recipes — the daemon's and `automations dry-run`'s
// — get their backends here: the Quick Connection caller and the agent()
// runner of the configured provider, the shell() runner and the workbench
// resolver.
func TestAutomationBackends_WireMCPAndAgent(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	d := db.OpenTestDB(t)
	for provider, want := range map[string]string{"": "claude", "claude": "claude", "codex": "codex", "ollama": "runtime-b"} {
		cfg := &config.Config{ActiveWorkspace: "acme", AI: config.AIConfig{Provider: provider}}
		b := automationBackends(cfg, d, &automationstest.FakeGenerator{})
		require.NotNil(t, b.MCP, provider)
		require.NotNil(t, b.Shell, provider)
		require.NotNil(t, b.Workbench, provider)
		require.NotNil(t, b.Agent, provider)
		assert.Equal(t, want, b.Agent.Name(), provider)
		assert.NotNil(t, b.Registry)
	}
}
