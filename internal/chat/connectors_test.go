package chat

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// connectorsFixture is the pinned sidecar the Desktop decodes (Task 15).
const connectorsFixture = "testdata/claude_ai_connectors.json"

func boolp(b bool) *bool { return &b }

func server(name, status string, tools ...MCPToolInfo) MCPServerStatus {
	return MCPServerStatus{Name: name, Status: status, Source: "claudeai", ConfigType: "claudeai-proxy", Tools: tools}
}

// fixtureSnapshot is the snapshot connectorsFixture holds: every status,
// every hint shape.
func fixtureSnapshot() ConnectorSnapshot {
	return ConnectorSnapshot{
		UpdatedAt: time.Date(2026, 10, 17, 9, 30, 0, 0, time.UTC),
		Available: true,
		Servers: []MCPServerStatus{
			server("claude.ai Claude Docs", ConnectorConnected,
				MCPToolInfo{Name: "read", ReadOnly: boolp(true)},
				MCPToolInfo{Name: "update"},
				MCPToolInfo{Name: "delete", Destructive: boolp(true)}),
			server("claude.ai Connector A", ConnectorNeedsAuth),
			server("claude.ai Connector B", ConnectorDisabled,
				MCPToolInfo{Name: "search", ReadOnly: boolp(true), Destructive: boolp(false)},
				MCPToolInfo{Name: "send", ReadOnly: boolp(false)}),
			server("claude.ai Connector C", ConnectorPending),
			server("claude.ai Connector D", ConnectorFailed),
		},
	}
}

// sidecarFixture runs the gate fixture with a sidecar path and fast watch
// bounds.
func sidecarFixture(t *testing.T) (*gateFixture, string) {
	t.Helper()
	fx := gateFake(t)
	path := filepath.Join(t.TempDir(), ConnectorsFileName)
	fx.opts.ConnectorsFile = path
	return fx, path
}

func fastWatch(b Backend, poll, settle time.Duration) Backend {
	cb := b.(*claudeBackend)
	cb.connPoll, cb.connSettle = poll, settle
	return cb
}

// mcpStatusRequests counts the mcp_status requests the session sent.
func mcpStatusRequests(t *testing.T, fx *gateFixture) int {
	t.Helper()
	data, err := os.ReadFile(fx.files.stdin)
	if os.IsNotExist(err) {
		return 0
	}
	require.NoError(t, err)
	return strings.Count(string(data), `"subtype":"mcp_status"`)
}

func readSidecar(t *testing.T, path string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil
	}
	require.NoError(t, err)
	var m map[string]any
	require.NoError(t, json.Unmarshal(data, &m))
	return m
}

func sidecarStatuses(t *testing.T, path string) map[string]string {
	t.Helper()
	s, err := ReadConnectorsFile(path)
	require.NoError(t, err)
	out := map[string]string{}
	for _, srv := range s.Servers {
		out[srv.Name] = srv.Status
	}
	return out
}

func connectorJSON(name, status string) string {
	return `{"name":"claude.ai ` + name + `","status":"` + status + `","source":"claudeai","config":{"type":"claudeai-proxy"}` +
		`,"tools":[{"name":"search","annotations":{"readOnly":true}}]}`
}

func TestConnectors_SnapshotWaitsForPendingUpTo10s(t *testing.T) {
	fx, path := sidecarFixture(t)
	fx.setStatus(t, `[]`, `[`+connectorJSON("Gmail", "pending")+`]`, `[`+connectorJSON("Gmail", "pending")+`]`,
		`[`+connectorJSON("Gmail", "connected")+`]`)
	h := startSession(t, fastWatch(NewClaudeBackend(fx.opts), 20*time.Millisecond, 5*time.Second), nil)
	h.next(EventSessionReady)

	waitUntil(t, "the settled sidecar", func() bool {
		return readSidecar(t, path) != nil && sidecarStatuses(t, path)["claude.ai Gmail"] == ConnectorConnected
	})
	time.Sleep(100 * time.Millisecond) // five more poll intervals: the watch has stopped
	require.NoError(t, h.finish())
	assert.Equal(t, 4, mcpStatusRequests(t, fx), "an empty list, pending twice, then connected — and no more")
}

func TestConnectors_GivesUpAfter10s(t *testing.T) {
	fx, path := sidecarFixture(t)
	fx.setStatus(t, `[`+connectorJSON("Gmail", "pending")+`]`)
	h := startSession(t, fastWatch(NewClaudeBackend(fx.opts), 20*time.Millisecond, 150*time.Millisecond), nil)
	h.next(EventSessionReady)

	waitUntil(t, "the sidecar", func() bool { return readSidecar(t, path) != nil })
	assert.Equal(t, ConnectorPending, sidecarStatuses(t, path)["claude.ai Gmail"], "written as it stands")
	time.Sleep(150 * time.Millisecond)
	sent := mcpStatusRequests(t, fx)
	assert.LessOrEqual(t, sent, 12, "bounded by the settle window")

	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "hello"})
	h.next(EventTurnDone)
	require.NoError(t, h.finish())
	assert.Equal(t, sent, mcpStatusRequests(t, fx), "the chat went on; no more polling")
}

func TestConnectors_SidecarIs0600AndAtomic(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, ConnectorsFileName)
	require.NoError(t, os.WriteFile(path, []byte("old"), 0o644))

	require.NoError(t, WriteConnectorsFile(path, fixtureSnapshot()))
	info, err := os.Stat(path)
	require.NoError(t, err)
	assert.Equal(t, os.FileMode(0o600), info.Mode().Perm())
	entries, err := os.ReadDir(dir)
	require.NoError(t, err)
	require.Len(t, entries, 1, "no temp file left behind")

	missing, err := ReadConnectorsFile(filepath.Join(dir, "none.json"))
	require.NoError(t, err, "a missing sidecar is no error")
	assert.False(t, missing.Available)
	assert.Empty(t, missing.Servers)

	require.NoError(t, os.WriteFile(path, []byte("{not json"), 0o600))
	_, err = ReadConnectorsFile(path)
	assert.Error(t, err)
}

func TestConnectors_FixtureRoundTrips(t *testing.T) {
	path := filepath.Join(t.TempDir(), ConnectorsFileName)
	require.NoError(t, WriteConnectorsFile(path, fixtureSnapshot()))
	written, err := os.ReadFile(path)
	require.NoError(t, err)
	if *updateGolden {
		require.NoError(t, os.WriteFile(connectorsFixture, written, 0o600))
	}
	pinned, err := os.ReadFile(connectorsFixture)
	require.NoError(t, err)
	assert.Equal(t, string(pinned), string(written), "the sidecar format is pinned (go test -run FixtureRoundTrips -update)")

	back, err := ReadConnectorsFile(connectorsFixture)
	require.NoError(t, err)
	assert.Equal(t, fixtureSnapshot(), back)
}

func TestConnectors_SidecarKeepsOnlyAccountConnectors(t *testing.T) {
	snap := newConnectorSnapshot(time.Now(), []MCPServerStatus{
		server("claude.ai Gmail", "connected"),
		{Name: "watchtower", Status: "connected", Source: "dynamic", ConfigType: "stdio"},
		{Name: "claude_ai_Spoof", Status: "connected", Source: "dynamic", ConfigType: "stdio"},
		{Name: "claude.ai Local", Status: "connected", Source: "claudeai", ConfigType: "stdio"},
		server("claude.ai Odd", "some-new-status"),
	}, map[string]bool{"claude_ai_Gmail": true})
	path := filepath.Join(t.TempDir(), ConnectorsFileName)
	require.NoError(t, WriteConnectorsFile(path, snap))
	assert.Equal(t, map[string]string{"claude.ai Gmail": ConnectorDisabled, "claude.ai Odd": ConnectorFailed},
		sidecarStatuses(t, path))
	assert.False(t, snap.Connector("claude_ai_Spoof"))
	assert.False(t, snap.Connector("claude_ai_Local"), "a claudeai server that is no claudeai-proxy is no connector")
}

func TestConnectors_DisabledToolTokens(t *testing.T) {
	last := ConnectorSnapshot{Servers: []MCPServerStatus{
		server("claude.ai Claude Docs", "connected"), server("claude.ai Example Tool (2)", "needs-auth"),
	}}
	assert.Equal(t, []string{
		"mcp__claude_ai_Claude_Docs__authenticate",
		"mcp__claude_ai_Claude_Docs__complete_authentication",
		"mcp__claude_ai_Connector_A",
		"mcp__claude_ai_Example_Tool_2",
		"mcp__claude_ai_Example_Tool_2__authenticate",
		"mcp__claude_ai_Example_Tool_2__complete_authentication",
	}, DisabledToolTokens([]string{"Connector A", " Example Tool (2) ", "", "claude.ai Connector A"}, last))
	assert.Empty(t, DisabledToolTokens(nil, ConnectorSnapshot{}))

	got := DisabledConnectorTokens(nil)
	require.NotNil(t, got, "never nil: nil would mean nothing is switched off by accident")
	assert.Empty(t, got)
	assert.Equal(t, map[string]bool{"claude_ai_Connector_A": true, "claude_ai_Example_Tool_2": true},
		DisabledConnectorTokens([]string{"Connector A", "Example Tool (2)"}))
}

func TestConnectors_UnknownServerRefreshesOnceThenDenies(t *testing.T) {
	fx := gateFake(t, canUseTool("r1", "tu1", "mcp__claude_ai_Stray__send", "claude.ai Stray", `{}`))
	h := startSession(t, NewClaudeBackend(fx.opts), nil)
	h.next(EventSessionReady)
	waitUntil(t, "the first mcp_status", func() bool { return mcpStatusRequests(t, fx) >= 1 })
	before := mcpStatusRequests(t, fx)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "send"})
	h.next(EventTurnDone)
	require.NoError(t, h.finish())

	answers := fx.controlAnswers(t)["r1"]
	require.Len(t, answers, 1)
	assert.Equal(t, "deny", behavior(t, answers[0]))
	assert.Contains(t, denyMessage(t, answers[0]), "not one of this account's claude.ai connectors")
	assert.Equal(t, before+1, mcpStatusRequests(t, fx), "one refresh before the decision")
	assert.Zero(t, fx.sink.count(), "an unlisted server never reaches the owner as a card")
}

func TestConnectors_UnknownToolRefreshesOnceThenAsks(t *testing.T) {
	fx := gateFake(t, canUseTool("r1", "tu1", "mcp__claude_ai_Gmail__label", "claude.ai Gmail", `{}`))
	h := startSession(t, NewClaudeBackend(fx.opts), nil)
	h.next(EventSessionReady)
	waitUntil(t, "the first mcp_status", func() bool { return mcpStatusRequests(t, fx) >= 1 })
	before := mcpStatusRequests(t, fx)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "label"})
	wait := h.next(EventToolWait)
	assert.Equal(t, before+1, mcpStatusRequests(t, fx), "one refresh before the decision")
	require.True(t, fx.sink.reject(wait.ActionID))
	h.next(EventTurnDone)
	require.NoError(t, h.finish())
}

// The owner connects a connector on claude.ai while the session is warm: the
// refresh finds it and its read-only tool runs without a card.
func TestConnectors_ServerConnectedMidSessionIsFoundByTheRefresh(t *testing.T) {
	fx := gateFake(t, canUseTool("r1", "tu1", "mcp__claude_ai_Drive__search", "claude.ai Drive", `{"q":"x"}`))
	fx.setStatus(t, testConnectors) // until the first answer is read
	h := startSession(t, NewClaudeBackend(fx.opts), nil)
	h.next(EventSessionReady)
	waitUntil(t, "the first mcp_status", func() bool { return mcpStatusRequests(t, fx) >= 1 })
	time.Sleep(50 * time.Millisecond) // the watch has stored the settled list
	fx.setStatus(t, testConnectors, `[`+connectorJSON("Drive", "connected")+`]`)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "search"})
	h.next(EventTurnDone)
	require.NoError(t, h.finish())

	answers := fx.controlAnswers(t)["r1"]
	require.Len(t, answers, 1)
	assert.Equal(t, "allow", behavior(t, answers[0]))
	assert.Zero(t, fx.sink.count())
}

func TestConnectors_UnavailableWritesReason(t *testing.T) {
	path := filepath.Join(t.TempDir(), ConnectorsFileName)
	reason := "claude.ai tools need a claude.ai login; this chat uses an API key."
	require.NoError(t, WriteConnectorsFile(path, UnavailableConnectors(time.Now(), reason)))
	m := readSidecar(t, path)
	assert.Equal(t, false, m["available"])
	assert.Equal(t, reason, m["unavailable_reason"])
	assert.Equal(t, []any{}, m["servers"])
}

// An init event naming an API key source switches the catalog off, whatever
// the environment markers said: no connector call runs, and the sidecar
// says why.
func TestConnectors_APIKeySourceSwitchesThemOff(t *testing.T) {
	docsRead := `{"ref":{"object":"project","id":"some-doc"}}`
	fx, path := sidecarFixture(t)
	fx.setRequests(t, canUseTool("r1", "tu1", "mcp__claude_ai_Claude_Docs__read", "claude.ai Claude Docs", docsRead))
	fx.opts.Env = append(fx.opts.Env, "FAKE_API_KEY_SOURCE=apiKeyHelper")
	h := startSession(t, NewClaudeBackend(fx.opts), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "read"})
	h.next(EventTurnDone)
	require.NoError(t, h.finish())

	answers := fx.controlAnswers(t)["r1"]
	require.Len(t, answers, 1)
	assert.Equal(t, "deny", behavior(t, answers[0]))
	m := readSidecar(t, path)
	assert.Equal(t, false, m["available"])
	assert.Contains(t, m["unavailable_reason"], "apiKeyHelper")
	assert.Equal(t, []any{}, m["servers"])
}

func TestConnectors_APIKeySourceNoneKeepsThemOn(t *testing.T) {
	assert.Empty(t, apiKeyUnavailableReason("none"))
	assert.Empty(t, apiKeyUnavailableReason(""))
	assert.NotEmpty(t, apiKeyUnavailableReason("ANTHROPIC_API_KEY"))
}

func TestConnectors_SwitchedOffServerIsMarkedDisabled(t *testing.T) {
	fx, path := sidecarFixture(t)
	fx.opts.Gate.Policy.Disabled = DisabledConnectorTokens([]string{"Gmail"})
	h := startSession(t, NewClaudeBackend(fx.opts), nil)
	h.next(EventSessionReady)
	waitUntil(t, "the sidecar", func() bool { return readSidecar(t, path) != nil })
	require.NoError(t, h.finish())
	assert.Equal(t, map[string]string{"claude.ai Gmail": ConnectorDisabled, "claude.ai Claude Docs": ConnectorConnected},
		sidecarStatuses(t, path))
}

// With every connector off the CLI lists none: no mcp_status is sent and the
// sidecar keeps the last known list, all disabled, for Settings to switch
// back on.
func TestConnectors_AllOffKeepsTheLastListDisabled(t *testing.T) {
	fx, path := sidecarFixture(t)
	require.NoError(t, WriteConnectorsFile(path, fixtureSnapshot()))
	fx.opts.ClaudeAI.Connectors = false
	h := startSession(t, NewClaudeBackend(fx.opts), nil)
	h.next(EventSessionReady)
	waitUntil(t, "the sidecar rewrite", func() bool {
		return sidecarStatuses(t, path)["claude.ai Claude Docs"] == ConnectorDisabled
	})
	require.NoError(t, h.finish())

	got, err := ReadConnectorsFile(path)
	require.NoError(t, err)
	assert.True(t, got.Available)
	require.Len(t, got.Servers, 5)
	for _, s := range got.Servers {
		assert.Equal(t, ConnectorDisabled, s.Status, s.Name)
		assert.Empty(t, s.Tools, s.Name)
	}
	assert.Zero(t, mcpStatusRequests(t, fx))
}

func TestConnectors_ModeOffSendsNoStatusRequest(t *testing.T) {
	fx, path := sidecarFixture(t)
	fx.opts.ClaudeAI = ClaudeAIMode{}
	fx.opts.Gate = nil
	h := startSession(t, NewClaudeBackend(fx.opts), nil)
	h.next(EventSessionReady)
	h.send(Command{Type: CommandTurn, TurnID: "t1", Text: "hello"})
	h.next(EventTurnDone)
	require.NoError(t, h.finish())
	assert.Zero(t, mcpStatusRequests(t, fx))
	assert.Nil(t, readSidecar(t, path))
}

func TestConnectors_StatusAnswerIsRoutedOnlyToItsQuery(t *testing.T) {
	b := NewClaudeBackend(ClaudeOptions{Binary: "claude", ClaudeAI: ClaudeAIMode{On: true, Connectors: true}}).(*claudeBackend)
	other := `{"type":"control_response","response":{"subtype":"success","request_id":"interrupt","response":{}}}`
	assert.False(t, b.routeStatusAnswer([]byte(other)), "an answer nobody waits for goes on to the translator")
	off := NewClaudeBackend(ClaudeOptions{Binary: "claude"}).(*claudeBackend)
	assert.False(t, off.routeStatusAnswer([]byte(other)))
}

func TestClaudeArgs_ClaudeAIModeDropsReservedAllowTokens(t *testing.T) {
	allowed := "mcp__watchtower,mcp__claude_ai_Gmail,mcp__claude_ai_Gmail__send,mcp__Claude_AI_Drive__search," +
		"mcp__claude__ai_x__y,mcp__github__get_issue,WebSearch"
	o := ClaudeOptions{AllowedTools: allowed, ClaudeAI: ClaudeAIMode{On: true}}
	assert.Equal(t, "mcp__watchtower,mcp__github__get_issue,WebSearch", flagValue(claudeArgs(o, "p", "", ""), "--allowedTools"))

	o.AllowedTools = "mcp__claude_ai_Gmail"
	assert.Empty(t, flagValue(claudeArgs(o, "p", "", ""), "--allowedTools"), "no empty --allowedTools flag")

	o = ClaudeOptions{AllowedTools: allowed}
	assert.Equal(t, allowed, flagValue(claudeArgs(o, "p", "", ""), "--allowedTools"), "off: unchanged")
}

// flagValue is the value after flag in args ("" when absent).
func flagValue(args []string, flag string) string {
	for i, a := range args {
		if a == flag && i+1 < len(args) {
			return args[i+1]
		}
	}
	return ""
}
