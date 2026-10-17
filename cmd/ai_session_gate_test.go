package cmd

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/ai"
	"watchtower/internal/chat"
	"watchtower/internal/config"
	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// claudeAIOffEnv are the child environment markers that turn claude.ai mode
// off (chat.ClaudeAIAvailability); the tests clear them so the developer's
// own environment never decides the mode.
var claudeAIOffEnv = []string{"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
	"CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"}

// claudeAILoginEnv makes the test process look like a claude.ai login and
// gives the session a private temp dir (its work and publish dirs).
func claudeAILoginEnv(t *testing.T) {
	t.Helper()
	for _, k := range claudeAIOffEnv {
		t.Setenv(k, "")
	}
	t.Setenv("TMPDIR", t.TempDir())
}

// One availability answer decides the prompt section, the mode and the
// publish dir: On ⇔ ClaudeAIMode.On, an embedded surface gets nothing,
// another provider gets its one line, an API key gets the reason.
func TestAISession_PromptOptionsClaudeAIByProvider(t *testing.T) {
	claudeAILoginEnv(t)
	cfgFor := func(provider string) *config.Config {
		cfg := &config.Config{}
		cfg.AI.Provider = provider
		cfg.AI.ClaudeAI.Connectors = true
		return cfg
	}

	on := resolveClaudeAI(cfgFor("claude"), "main", 7, os.Environ(), io.Discard)
	assert.Equal(t, chat.ClaudeAIPromptOn, on.prompt.Kind)
	assert.True(t, on.mode.On)
	assert.True(t, on.mode.Connectors)
	assert.True(t, on.prompt.Connectors)
	require.NotNil(t, on.publish)
	assert.Equal(t, on.publish.Path(), on.prompt.PublishDir)
	assert.True(t, filepath.IsAbs(on.prompt.PublishDir))
	assert.Equal(t, filepath.Join(chat.NeutralWorkDir(), "publish", "7"), on.publish.Path())
	assert.Empty(t, on.reason)

	def := resolveClaudeAI(cfgFor(""), "main", 7, os.Environ(), io.Discard)
	assert.True(t, def.mode.On, "the default provider is Claude")

	target := resolveClaudeAI(cfgFor("claude"), "target", 7, os.Environ(), io.Discard)
	assert.Equal(t, claudeAISetup{}, target, "an embedded surface gets no claude.ai text and no tools")

	for _, p := range []string{"codex", "ollama"} {
		s := resolveClaudeAI(cfgFor(p), "main", 7, os.Environ(), io.Discard)
		assert.Equal(t, chat.ClaudeAIPromptOtherProvider, s.prompt.Kind, p)
		assert.False(t, s.mode.On, p)
		assert.Nil(t, s.publish, p)
		assert.Empty(t, s.reason, p+": the provider is this conversation's own, so Settings is not told")
	}

	// The key is in the child's environment only — the merged env decides.
	keyed := resolveClaudeAI(cfgFor("claude"), "main", 7, append(os.Environ(), "ANTHROPIC_API_KEY=sk-test"), io.Discard)
	assert.Equal(t, chat.ClaudeAIPromptUnavailable, keyed.prompt.Kind)
	assert.False(t, keyed.mode.On)
	assert.Nil(t, keyed.publish)
	assert.Equal(t, "claude.ai tools need a claude.ai login; this chat uses an API key.", keyed.prompt.Reason)
	assert.Equal(t, keyed.prompt.Reason, keyed.reason)

	// A publish dir that cannot be made turns this conversation's mode off,
	// without telling Settings (the sidecar is every conversation's).
	require.NoError(t, os.WriteFile(filepath.Join(chat.NeutralWorkDir(), "publish", "8"), nil, 0o600))
	broken := resolveClaudeAI(cfgFor("claude"), "main", 8, os.Environ(), io.Discard)
	assert.Equal(t, chat.ClaudeAIPromptUnavailable, broken.prompt.Kind)
	assert.NotEmpty(t, broken.prompt.Reason)
	assert.False(t, broken.mode.On)
	assert.Nil(t, broken.publish)
	assert.Empty(t, broken.reason)

	// The prompt options carry exactly the resolved section.
	assert.Equal(t, on.prompt, sessionPromptOptions(cfgFor("claude"), "main", 0, time.Now(), on.prompt).ClaudeAI)
}

func TestClaudeSessionOptions_ClaudeAIModeWiring(t *testing.T) {
	claudeAILoginEnv(t)
	dbPath := filepath.Join(t.TempDir(), "watchtower.db")
	require.NoError(t, chat.WriteConnectorsFile(connectorsFilePath(dbPath), chat.ConnectorSnapshot{
		UpdatedAt: time.Now(), Available: true,
		Servers: []chat.MCPServerStatus{{Name: "claude.ai Connector A", Status: "connected",
			Source: "claudeai", ConfigType: "claudeai-proxy"}},
	}))
	cfg := &config.Config{}
	cfg.AI.ClaudeAI.Connectors = true
	cfg.AI.ClaudeAI.DisabledConnectors = []string{"Gmail"}
	conv := &db.ChatConversation{ID: 9}
	w := sessionWiring{cfg: cfg, database: db.OpenTestDB(t), dbPath: dbPath, conv: conv, warn: io.Discard,
		claudeAI: resolveClaudeAI(cfg, "main", conv.ID, os.Environ(), io.Discard)}
	require.True(t, w.claudeAI.mode.On)
	ext := []ai.ExternalMCPServer{{Name: "acme", Kind: "http", URL: "https://example.com/mcp",
		AllowTools: []string{"getIssue"}, DenyTools: []string{"createIssue"}}}
	sink := newRegistrySink(tools.New(w.database), w.database, conv, io.Discard)

	opts := withClaudeAI(claudeSessionOptions(w, ext), w, ext, sink)

	assert.Equal(t, w.claudeAI.mode, opts.ClaudeAI)
	assert.Equal(t, ai.ClaudeAISessionBuiltinTools, opts.Tools)
	assert.Equal(t, filepath.Join(filepath.Dir(dbPath), chat.ConnectorsFileName), opts.ConnectorsFile)
	hidden := strings.Split(opts.DisallowedTools, ",")
	for _, tok := range strings.Split(ai.ClaudeAISessionDisallowedTools, ",") {
		assert.Contains(t, hidden, tok)
	}
	assert.Contains(t, hidden, "mcp__claude_ai_Gmail", "a switched-off connector is hidden whole")
	assert.Contains(t, hidden, "mcp__claude_ai_Connector_A__authenticate")
	assert.Contains(t, hidden, "mcp__claude_ai_Connector_A__complete_authentication")
	assert.Contains(t, hidden, "mcp__acme__createIssue", "QC-02 denies still hide")
	assert.NotContains(t, hidden, "Artifact")
	assert.NotContains(t, hidden, "Write")
	assert.Equal(t, "mcp__watchtower,mcp__acme__getIssue,"+ai.WebSearchTool, opts.AllowedTools)

	require.NotNil(t, opts.Gate)
	assert.Same(t, sink, opts.Gate.Sink)
	assert.Same(t, w.claudeAI.publish, opts.Gate.Publish)
	assert.Equal(t, map[string]bool{"claude_ai_Gmail": true}, opts.Gate.Policy.Disabled)

	// Nothing switched off is an empty map, never nil (nil refuses to start).
	cfg.AI.ClaudeAI.DisabledConnectors = nil
	opts = withClaudeAI(claudeSessionOptions(w, nil), w, nil, sink)
	require.NotNil(t, opts.Gate.Policy.Disabled)
	assert.Empty(t, opts.Gate.Policy.Disabled)
}

// The sink binds every row to the conversation, the Desktop's turn and this
// process's token; another process's sink never touches it.
func TestAISession_RegistrySinkBindsConversationAndTurn(t *testing.T) {
	database := db.OpenTestDB(t)
	reg := tools.New(database)
	require.NoError(t, reg.Register(tools.NewClaudeAIConnectorCall()))
	ctx := context.Background()
	conv := &db.ChatConversation{ID: 3, ContextType: "track", ContextID: "12"}
	sink := newRegistrySink(reg, database, conv, io.Discard)
	other := newRegistrySink(reg, database, conv, io.Discard)
	require.NotEmpty(t, sink.token)
	assert.NotEqual(t, sink.token, other.token, "one random token per process")

	input := json.RawMessage(`{"to":"someone@example.com","body":"a <b> & c"}`)
	id, err := sink.ProposeConnectorCall(ctx, chat.ConnectorCall{TurnID: "turn-7",
		Server: "claude.ai Gmail", Tool: "mcp__claude_ai_Gmail__send", Reason: "Send", Input: input})
	require.NoError(t, err)

	row, err := database.GetAgentAction(id)
	require.NoError(t, err)
	assert.Equal(t, tools.ClaudeAIConnectorCallTool, row.Tool)
	assert.Equal(t, "pending", row.Status)
	assert.Equal(t, sink.token, row.SessionToken)
	assert.Equal(t, "turn-7", row.TurnID)
	assert.Equal(t, "main", row.Surface)
	assert.Equal(t, int64(3), row.ConversationID)
	assert.Equal(t, "track", row.ContextType)
	assert.Equal(t, "12", row.ContextID)
	assert.Equal(t, "Send", row.Reason)
	assert.Contains(t, row.ArgsJSON, `"body":"a <b> & c"`, "the card shows the input as sent")

	status, err := sink.ActionStatus(ctx, id)
	require.NoError(t, err)
	assert.Equal(t, "pending", status)
	_, err = other.ActionStatus(ctx, id)
	assert.ErrorIs(t, err, tools.ErrNotThisSession)
	_, ok, err := sink.ClaimApproved(ctx, id)
	require.NoError(t, err)
	assert.False(t, ok, "a pending row is not claimed")

	_, err = reg.Approve(ctx, id, json.RawMessage(`{"input":{"to":"someone@example.com","body":"edited"}}`))
	require.NoError(t, err)
	_, _, err = other.ClaimApproved(ctx, id)
	assert.ErrorIs(t, err, tools.ErrNotThisSession)
	got, ok, err := sink.ClaimApproved(ctx, id)
	require.NoError(t, err)
	require.True(t, ok)
	assert.JSONEq(t, `{"to":"someone@example.com","body":"edited"}`, string(got), "the approved input, edits included")
	require.NoError(t, sink.FinishCall(ctx, id, "sent", ""))
	row, err = database.GetAgentAction(id)
	require.NoError(t, err)
	assert.Equal(t, "applied", row.Status)

	// Cancel takes a pending row only; Expire takes an approved one.
	id2, err := sink.ProposeConnectorCall(ctx, chat.ConnectorCall{TurnID: "turn-8",
		Server: "claude.ai Gmail", Tool: "mcp__claude_ai_Gmail__send", Reason: "Send", Input: input})
	require.NoError(t, err)
	_, err = reg.Approve(ctx, id2, nil)
	require.NoError(t, err)
	cancelled, err := sink.CancelCall(ctx, id2, "stopped")
	require.NoError(t, err)
	assert.False(t, cancelled)
	expired, err := sink.ExpireCall(ctx, id2, "stopped before the approved call ran")
	require.NoError(t, err)
	assert.True(t, expired)

	// A claimed row whose input cannot be read fails at once — never left
	// executing.
	id3, err := sink.ProposeConnectorCall(ctx, chat.ConnectorCall{TurnID: "turn-9",
		Server: "claude.ai Gmail", Tool: "mcp__claude_ai_Gmail__send", Reason: "Send", Input: input})
	require.NoError(t, err)
	_, err = reg.Approve(ctx, id3, nil)
	require.NoError(t, err)
	_, err = database.Exec(`UPDATE agent_actions SET args_json = '{"server":"claude.ai Gmail"}' WHERE id = ?`, id3)
	require.NoError(t, err)
	_, ok, err = sink.ClaimApproved(ctx, id3)
	require.Error(t, err)
	assert.False(t, ok)
	row, err = database.GetAgentAction(id3)
	require.NoError(t, err)
	assert.Equal(t, "failed", row.Status)
	assert.Contains(t, row.Error, "no input")
}

// ExpireOrphans fails this conversation's open rows whatever their age and
// another conversation's only past 20 minutes.
func TestAISession_RegistrySinkExpireOrphans(t *testing.T) {
	database := db.OpenTestDB(t)
	reg := tools.New(database)
	require.NoError(t, reg.Register(tools.NewClaudeAIConnectorCall()))
	ctx := context.Background()
	propose := func(convID int64) int64 {
		s := newRegistrySink(reg, database, &db.ChatConversation{ID: convID}, io.Discard)
		id, err := s.ProposeConnectorCall(ctx, chat.ConnectorCall{TurnID: "t", Server: "claude.ai Gmail",
			Tool: "mcp__claude_ai_Gmail__send", Reason: "Send", Input: json.RawMessage(`{"to":"x@example.com"}`)})
		require.NoError(t, err)
		return id
	}
	own, other2, other3 := propose(1), propose(2), propose(3)
	sink := newRegistrySink(reg, database, &db.ChatConversation{ID: 1}, io.Discard)
	// 10 minutes on, the other conversations' rows may still have a live
	// session; 30 minutes on, none can.
	sink.now = func() time.Time { return time.Now().Add(10 * time.Minute) }
	require.NoError(t, sink.ExpireOrphans(ctx))
	status := func(id int64) string {
		row, err := database.GetAgentAction(id)
		require.NoError(t, err)
		return row.Status
	}
	assert.Equal(t, "failed", status(own))
	assert.Equal(t, "pending", status(other2))
	assert.Equal(t, "pending", status(other3))
	sink.now = func() time.Time { return time.Now().Add(30 * time.Minute) }
	require.NoError(t, sink.ExpireOrphans(ctx))
	assert.Equal(t, "failed", status(other2))
	assert.Equal(t, "failed", status(other3))
}

// aiSessionRun is one `ai session` run on the real command path.
type aiSessionRun struct {
	t      *testing.T
	dbPath string
	convID int64
	in     *io.PipeWriter
	events chan chat.Event
	done   chan error
}

// startAISession runs `ai session --surface surface` for a new conversation
// with claude as the fake CLI at claudePath.
func startAISession(t *testing.T, claudePath, surface string) *aiSessionRun {
	t.Helper()
	cleanup := setupWatchTestEnv(t)
	t.Cleanup(cleanup)
	resetAISessionFlags(t)
	t.Setenv("TMPDIR", t.TempDir()) // the session's work and publish dirs

	f, err := os.OpenFile(flagConfig, os.O_APPEND|os.O_WRONLY, 0)
	require.NoError(t, err)
	_, err = f.WriteString("claude_path: " + claudePath + "\n")
	require.NoError(t, err)
	require.NoError(t, f.Close())

	r := &aiSessionRun{t: t, events: make(chan chat.Event, 256), done: make(chan error, 1),
		dbPath: filepath.Join(os.Getenv("HOME"), ".local", "share", "watchtower", "test-ws", "watchtower.db")}
	database, err := db.Open(r.dbPath)
	require.NoError(t, err)
	res, err := database.Exec(`INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 1, 1)`)
	require.NoError(t, err)
	r.convID, err = res.LastInsertId()
	require.NoError(t, err)
	require.NoError(t, database.Close())

	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	r.in = inW
	aiSessionCmd.SetIn(inR)
	aiSessionCmd.SetOut(outW)
	t.Cleanup(func() { aiSessionCmd.SetIn(nil); aiSessionCmd.SetOut(nil) })
	aiSessionFlagConversation, aiSessionFlagSurface = r.convID, surface

	go func() {
		err := aiSessionCmd.RunE(aiSessionCmd, nil)
		_ = outW.Close()
		r.done <- err
		close(r.done)
	}()
	// A test that failed before close() still ends the session (stdin EOF
	// closes it) and waits for it, so no session outlives its test.
	t.Cleanup(func() {
		_ = inW.Close()
		select {
		case <-r.done:
		case <-time.After(15 * time.Second):
			t.Error("ai session did not exit at the end of the test")
		}
	})
	go func() {
		sc := bufio.NewScanner(outR)
		for sc.Scan() {
			var e chat.Event
			if json.Unmarshal(sc.Bytes(), &e) == nil {
				r.events <- e
			}
		}
		close(r.events)
	}()
	return r
}

// next returns the next event of type want, skipping the others.
func (r *aiSessionRun) next(want string) chat.Event {
	r.t.Helper()
	deadline := time.After(20 * time.Second)
	for {
		select {
		case e, ok := <-r.events:
			require.True(r.t, ok, "stream ended before %s", want)
			if e.Type == want {
				return e
			}
		case <-deadline:
			r.t.Fatalf("no %s event", want)
		}
	}
}

func (r *aiSessionRun) send(c chat.Command) {
	r.t.Helper()
	line, err := json.Marshal(c)
	require.NoError(r.t, err)
	_, err = r.in.Write(append(line, '\n'))
	require.NoError(r.t, err)
}

// close ends the session and waits for the command to return.
func (r *aiSessionRun) close() {
	r.t.Helper()
	r.send(chat.Command{Type: chat.CommandClose})
	select {
	case err := <-r.done:
		assert.NoError(r.t, err)
	case <-time.After(15 * time.Second):
		r.t.Fatal("ai session did not exit after close")
	}
}

// gateFakeClaude installs internal/chat's fake CLI in gate mode in a fresh
// dir and returns its path and that dir; every process started from it is
// killed when the test ends.
func gateFakeClaude(t *testing.T) (string, string) {
	t.Helper()
	dir := t.TempDir()
	t.Cleanup(func() { reapProcessesOf(t, dir) })
	script, err := os.ReadFile(filepath.Join("..", "internal", "chat", "testdata", "fake_claude.sh"))
	require.NoError(t, err)
	bin := filepath.Join(dir, "claude")
	require.NoError(t, os.WriteFile(bin, script, 0o755))
	t.Setenv("FAKE_MODE", "gate")
	for k, name := range map[string]string{"FAKE_ARGV": "argv", "FAKE_STDIN": "stdin", "FAKE_PID": "pid",
		"FAKE_CLAUDE_GATE_REQUESTS": "requests", "FAKE_MCP_STATUS": "mcp_status"} {
		t.Setenv(k, filepath.Join(dir, name))
	}
	require.NoError(t, os.WriteFile(filepath.Join(dir, "requests"), nil, 0o600))
	return bin, dir
}

// reapProcessesOf kills every process started from dir (the fake CLI and
// anything it left behind) and waits until none is left; a survivor fails
// the test.
func reapProcessesOf(t *testing.T, dir string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		_ = exec.Command("pkill", "-KILL", "-f", dir).Run()
		out, _ := exec.Command("pgrep", "-f", dir).Output()
		if strings.TrimSpace(string(out)) == "" {
			return
		}
		if time.Now().After(deadline) {
			t.Errorf("processes of %s survived the test: %s", dir, out)
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// spawnArgv waits for the fake CLI's first spawn to record its argv (the
// child writes it after session_ready may already be out) and returns it.
func spawnArgv(t *testing.T, dir string) []string {
	t.Helper()
	path := filepath.Join(dir, "argv")
	deadline := time.Now().Add(10 * time.Second)
	for {
		data, err := os.ReadFile(path)
		if run, _, found := strings.Cut(string(data), "\n--\n"); err == nil && found {
			return strings.Split(run, "\n")
		}
		if time.Now().After(deadline) {
			t.Fatalf("the fake CLI recorded no argv (%v)", err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// gateConnectors is the fake's mcp_status answer: Gmail with an unannotated
// send (a write) and a read-only search.
const gateConnectors = `[{"name":"claude.ai Gmail","status":"connected","source":"claudeai",` +
	`"config":{"type":"claudeai-proxy"},"tools":[{"name":"send","annotations":{}},` +
	`{"name":"search","annotations":{"readOnly":true}}]}]`

func gmailRequest(requestID, toolUseID, tool, input string) string {
	return `{"type":"control_request","request_id":"` + requestID + `","request":{"subtype":"can_use_tool",` +
		`"tool_name":"mcp__claude_ai_Gmail__` + tool + `","display_name":"` + tool + `",` +
		`"mcp_server":{"name":"claude.ai Gmail","source":"claudeai"},"input":` + input +
		`,"tool_use_id":"` + toolUseID + `"}}`
}

// controlAnswers are the gate's control_response bodies by request id, in
// the order written to the fake's stdin.
func controlAnswers(t *testing.T, stdinPath string) map[string][]map[string]any {
	t.Helper()
	data, err := os.ReadFile(stdinPath)
	require.NoError(t, err)
	out := map[string][]map[string]any{}
	for _, line := range strings.Split(string(data), "\n") {
		var l struct {
			Type     string `json:"type"`
			Response struct {
				RequestID string         `json:"request_id"`
				Response  map[string]any `json:"response"`
			} `json:"response"`
		}
		if json.Unmarshal([]byte(line), &l) == nil && l.Type == "control_response" {
			out[l.Response.RequestID] = append(out[l.Response.RequestID], l.Response.Response)
		}
	}
	return out
}

// TestAISession_ClaudeAIGateEndToEnd runs the real `ai session` path in
// claude.ai mode against the fake CLI: a connector read runs at once with no
// row; a write proposes one row bound to this process's token and the
// Desktop's turn, runs exactly once after Approve and records its result; an
// unanswered write is cancelled at the approval timeout and never runs.
func TestAISession_ClaudeAIGateEndToEnd(t *testing.T) {
	claudeAILoginEnv(t)
	bin, dir := gateFakeClaude(t)
	require.NoError(t, os.WriteFile(filepath.Join(dir, "mcp_status"), []byte(gateConnectors+"\n"), 0o600))
	requests := filepath.Join(dir, "requests")
	read := gmailRequest("r-read", "tu-read", "search", `{"q":"invoice"}`)
	write := gmailRequest("r-send", "tu-send", "send", `{"to":"someone@example.com","body":"hello"}`)
	require.NoError(t, os.WriteFile(requests, []byte(read+"\n"+write+"\n"), 0o600))
	prevTimeout, prevPoll := aiSessionApprovalTimeout, aiSessionGatePoll
	aiSessionApprovalTimeout, aiSessionGatePoll = 2*time.Second, 20*time.Millisecond
	t.Cleanup(func() { aiSessionApprovalTimeout, aiSessionGatePoll = prevTimeout, prevPoll })

	r := startAISession(t, bin, "main")
	r.next(chat.EventSessionReady)
	argv := spawnArgv(t, dir)
	assert.Equal(t, "stdio", argv[slices.Index(argv, "--permission-prompt-tool")+1])
	assert.NotContains(t, argv, "--strict-mcp-config")
	assert.Equal(t, ai.ClaudeAISessionBuiltinTools, argv[slices.Index(argv, "--tools")+1])

	database, err := db.Open(r.dbPath)
	require.NoError(t, err)
	t.Cleanup(func() { database.Close() })
	reg := tools.New(database)
	require.NoError(t, reg.Register(tools.NewClaudeAIConnectorCall()))
	sessionRows := func() []db.AgentAction {
		rows, err := database.ListAgentActions(db.AgentActionFilter{})
		require.NoError(t, err)
		return slices.DeleteFunc(rows, func(a db.AgentAction) bool { return a.Tool != tools.ClaudeAIConnectorCallTool })
	}

	// Turn 1: the read runs, the write waits for Approve, then runs once.
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "desk-turn-1", Text: "send it"})
	wait := r.next(chat.EventToolWait)
	assert.Equal(t, "desk-turn-1", wait.TurnID)
	assert.Equal(t, "tu-send", wait.ID)
	rows := sessionRows()
	require.Len(t, rows, 1, "only the write proposes a row")
	row := rows[0]
	assert.Equal(t, wait.ActionID, row.ID)
	assert.Equal(t, "pending", row.Status)
	assert.Equal(t, "desk-turn-1", row.TurnID, "the row's turn is the Desktop's")
	assert.Equal(t, r.convID, row.ConversationID)
	assert.Equal(t, "main", row.Surface)
	assert.NotEmpty(t, row.SessionToken)
	assert.Empty(t, controlAnswers(t, filepath.Join(dir, "stdin"))["r-send"], "nothing is answered while the row is pending")

	ok, err := reg.Approve(context.Background(), row.ID, nil)
	require.NoError(t, err)
	require.True(t, ok)
	r.next(chat.EventTurnDone)
	answers := controlAnswers(t, filepath.Join(dir, "stdin"))
	require.Len(t, answers["r-read"], 1)
	assert.Equal(t, "allow", answers["r-read"][0]["behavior"], "a connector read runs without a row")
	require.Len(t, answers["r-send"], 1, "the approved call is let through exactly once")
	assert.Equal(t, "allow", answers["r-send"][0]["behavior"])
	assert.Equal(t, map[string]any{"to": "someone@example.com", "body": "hello"}, answers["r-send"][0]["updatedInput"])
	got, err := database.GetAgentAction(row.ID)
	require.NoError(t, err)
	assert.Equal(t, "applied", got.Status)
	assert.Equal(t, `"ran"`, got.ResultJSON)

	// Turn 2: nobody approves; the call is cancelled and denied.
	write2 := gmailRequest("r-send2", "tu-send2", "send", `{"to":"someone@example.com","body":"again"}`)
	require.NoError(t, os.WriteFile(requests, []byte(write2+"\n"), 0o600))
	r.send(chat.Command{Type: chat.CommandTurn, TurnID: "desk-turn-2", Text: "send again"})
	wait2 := r.next(chat.EventToolWait)
	r.next(chat.EventTurnDone)
	got, err = database.GetAgentAction(wait2.ActionID)
	require.NoError(t, err)
	assert.Equal(t, "rejected", got.Status)
	assert.Equal(t, "not approved within 2s", got.Error)
	assert.Equal(t, "desk-turn-2", got.TurnID)
	assert.Equal(t, row.SessionToken, got.SessionToken, "one token for the whole process")
	answers = controlAnswers(t, filepath.Join(dir, "stdin"))
	require.Len(t, answers["r-send2"], 1)
	assert.Equal(t, "deny", answers["r-send2"][0]["behavior"])

	r.close()
}

// With an API key in the environment the session runs exactly as before
// claude.ai mode — today's argv — and Settings learns why.
func TestClaudeSessionOptions_APIKeyEnvTurnsClaudeAIOff(t *testing.T) {
	claudeAILoginEnv(t)
	t.Setenv("ANTHROPIC_API_KEY", "sk-test")
	bin, dir := gateFakeClaude(t)
	t.Setenv("FAKE_MODE", "normal")

	r := startAISession(t, bin, "main")
	r.next(chat.EventSessionReady)
	args := spawnArgv(t, dir)
	assert.Contains(t, args, "--strict-mcp-config")
	assert.NotContains(t, args, "--permission-prompt-tool")
	assert.Equal(t, ai.SessionBuiltinTools, args[slices.Index(args, "--tools")+1])
	assert.Equal(t, ai.SessionDisallowedTools, args[slices.Index(args, "--disallowedTools")+1])
	assert.Equal(t, "mcp__watchtower,"+ai.WebSearchTool, args[slices.Index(args, "--allowedTools")+1])
	_, err := os.Stat(filepath.Join(chat.NeutralWorkDir(), "publish"))
	assert.ErrorIs(t, err, os.ErrNotExist, "no publish dir without claude.ai mode")

	snap, err := chat.ReadConnectorsFile(connectorsFilePath(r.dbPath))
	require.NoError(t, err)
	assert.False(t, snap.Available)
	assert.Equal(t, "claude.ai tools need a claude.ai login; this chat uses an API key.", snap.UnavailableReason)
	r.close()
}

// An embedded surface never writes the sidecar: its "none" is not the main
// chat's.
func TestAISession_TargetSurfaceWritesNoConnectorsFile(t *testing.T) {
	claudeAILoginEnv(t)
	bin, dir := gateFakeClaude(t)
	t.Setenv("FAKE_MODE", "normal")
	r := startAISession(t, bin, "target")
	r.next(chat.EventSessionReady)
	argv := spawnArgv(t, dir)
	assert.Contains(t, argv, "--strict-mcp-config")
	_, err := os.Stat(connectorsFilePath(r.dbPath))
	assert.ErrorIs(t, err, os.ErrNotExist)
	r.close()
}
