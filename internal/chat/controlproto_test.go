package chat

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"

	"watchtower/internal/chat/connectorpolicy"
)

// rawRequestField returns request.<key> of a recorded control line exactly as
// recorded, for byte comparisons.
func rawRequestField(t *testing.T, line, key string) json.RawMessage {
	t.Helper()
	var l struct {
		Request map[string]json.RawMessage `json:"request"`
	}
	require.NoError(t, json.Unmarshal([]byte(line), &l))
	return l.Request[key]
}

func TestControlProto_ParsesRecordedCanUseTool(t *testing.T) {
	lines := readFixture(t, "claude_ai_can_use_tool.jsonl")
	// One row per recorded line, in the order claude_ai_probe.md lists them.
	want := []struct {
		tool, display, toolUseID, server, source string
	}{
		{"Read", "Read", "toolu_014gHpQQzWALJYf6sYKbXkkX", "", ""},
		{"Read", "Read", "toolu_01MD218Ab3Q9bEQ78BL2BYGX", "", ""},
		{"Edit", "Edit", "toolu_01UVWaioXm2eN7fEMvU4Wx5h", "", ""},
		{"Edit", "Edit", "toolu_01Xcv6xtHoxDULgECzWrkoKC", "", ""},
		{"Write", "Write", "toolu_015iL2kuAHtzL35ecfVsbXHD", "", ""},
		{"Write", "Write", "toolu_017UPtFaLycvPr7iPUSsXgy2", "", ""},
		{"Write", "Write", "toolu_0199UBS57N1kbgmyHVdYWD6J", "", ""},
		{"Artifact", "Artifact", "toolu_01Xn2Hi76kJ1KPMTGBqp7ixe", "", ""},
		{"Artifact", "Artifact", "toolu_01G3NXN5AWLH2NgrusJ8ntyQ", "", ""},
		{"Artifact", "Artifact", "toolu_01DdWKT8sqnXSjoFGRLRPPKy", "", ""},
		{"mcp__claude_ai_Claude_Docs__guide", "Guide", "toolu_01WCZx6BA2B4MUihxiahVdMn", "claude.ai Claude Docs", "claudeai"},
		{"mcp__claude_ai_Claude_Docs__delete", "Delete", "toolu_012DAzxzTcKsUABYq7nUo3Hn", "claude.ai Claude Docs", "claudeai"},
		{"Write", "Write", "toolu_018kwY5YZMUoM7z6f28K3TVZ", "", ""},
	}
	require.Len(t, lines, len(want), "the probe recorded 13 requests; re-check claude_ai_probe.md")
	for i, line := range lines {
		req, ok := parseControlRequest([]byte(line))
		require.True(t, ok, "line %d", i+1)
		w := want[i]
		assert.Equal(t, w.tool, req.ToolName, "line %d", i+1)
		assert.Equal(t, w.display, req.DisplayName, "line %d", i+1)
		assert.Equal(t, w.toolUseID, req.ToolUseID, "line %d", i+1)
		assert.Equal(t, w.server, req.MCPServer, "line %d", i+1)
		assert.Equal(t, w.source, req.MCPServerSource, "line %d", i+1)
		assert.Equal(t, w.server != "", req.hasMCPServer, "line %d", i+1)
		assert.Equal(t, []byte(rawRequestField(t, line, "input")), []byte(req.Input),
			"line %d: the input is kept byte for byte", i+1)
		assert.NotEmpty(t, req.RequestID, "line %d", i+1)
	}

	publish, _ := parseControlRequest([]byte(lines[7]))
	assert.Contains(t, string(publish.Input), `"__artifactPublishSourcePin":{`,
		"the CLI-internal publish keys reach the gate")
	assert.Equal(t, `publish "page.html" as an artifact`, publish.Description)
	assert.True(t, strings.HasPrefix(publish.DecisionReason, `Claude wants to publish "page.html"`))
}

func TestControlProto_RequestIsReadByExactKey(t *testing.T) {
	// A Go struct would also bind "Tool_Name"; the CLI (JavaScript) reads
	// only "tool_name". The codec must see what the CLI runs.
	line := `{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool",` +
		`"tool_name":"Write","Tool_Name":"Artifact","input":{"file_path":"/x"},"tool_use_id":"t1"}}`
	req, ok := parseControlRequest([]byte(line))
	require.True(t, ok)
	assert.Equal(t, "Write", req.ToolName)

	_, ok = parseControlRequest([]byte(`{"type":"control_request","request_id":"r1","request":{"Subtype":"can_use_tool","tool_name":"Write"}}`))
	assert.False(t, ok, "a subtype under another spelling is not a can_use_tool")
}

func TestControlProto_IgnoresOtherControlLines(t *testing.T) {
	var lines []string
	for _, f := range []string{"claude_ai_control_other.jsonl", "claude_ai_control_responses.jsonl",
		"claude_ai_mcp_status.jsonl", "claude_ai_init.jsonl", "claude_interrupt.jsonl", "claude_tool.jsonl"} {
		lines = append(lines, readFixture(t, f)...)
	}
	lines = append(lines,
		`{"type":"control_request","request":{"subtype":"can_use_tool","tool_name":"Write"}}`,
		`{"type":"control_request","request_id":"","request":{"subtype":"can_use_tool","tool_name":"Write"}}`,
		`{"type":"control_request","request_id":"interrupt-u1","request":{"subtype":"interrupt"}}`,
		`not json`, ``)
	for _, line := range lines {
		_, ok := parseControlRequest([]byte(line))
		assert.False(t, ok, "not a can_use_tool: %.120s", line)
	}
}

func TestControlProto_AllowDenyLinesRoundTrip(t *testing.T) {
	requests := readFixture(t, "claude_ai_can_use_tool.jsonl")
	responses := readFixture(t, "claude_ai_control_responses.jsonl")
	require.Len(t, responses, 12, "the CLI accepted an answer to each of lines 1–12")

	for i, recorded := range responses {
		req, ok := parseControlRequest([]byte(requests[i]))
		require.True(t, ok)
		var rec struct {
			Response struct {
				RequestID string `json:"request_id"`
				Response  struct {
					Behavior     string          `json:"behavior"`
					UpdatedInput json.RawMessage `json:"updatedInput"`
					Message      string          `json:"message"`
				} `json:"response"`
			} `json:"response"`
		}
		require.NoError(t, json.Unmarshal([]byte(recorded), &rec))
		require.Equal(t, req.RequestID, rec.Response.RequestID, "answer %d pairs with request %d", i+1, i+1)

		var got []byte
		if rec.Response.Response.Behavior == "deny" {
			got = permissionDenyLine(req.RequestID, rec.Response.Response.Message)
		} else {
			var err error
			got, err = permissionAllowLine(req.RequestID, rec.Response.Response.UpdatedInput)
			require.NoError(t, err)
		}
		require.True(t, strings.HasSuffix(string(got), "\n"), "newline-terminated")
		assert.Equal(t, 1, strings.Count(string(got), "\n"), "one line")
		assert.JSONEq(t, recorded, string(got), "answer %d has the shape the CLI accepted", i+1)
	}
}

func TestControlProto_AllowEchoesTheRequestInputByteForByte(t *testing.T) {
	publish, ok := parseControlRequest([]byte(readFixture(t, "claude_ai_can_use_tool.jsonl")[7]))
	require.True(t, ok)
	line, err := permissionAllowLine(publish.RequestID, publish.Input)
	require.NoError(t, err)
	var out struct {
		Response struct {
			Response struct {
				UpdatedInput json.RawMessage `json:"updatedInput"`
			} `json:"response"`
		} `json:"response"`
	}
	require.NoError(t, json.Unmarshal(line, &out))
	assert.Equal(t, string(publish.Input), string(out.Response.Response.UpdatedInput))

	// No HTML escaping: <, > and & stay as they are.
	in := json.RawMessage(`{"content":"<p>a & b</p>","__artifactX":{"sha256":"ab"}}`)
	line, err = permissionAllowLine("r1", in)
	require.NoError(t, err)
	assert.Contains(t, string(line), `"updatedInput":`+string(in))
}

func TestControlProto_AllowWithoutUpdatedInputRunsAsSent(t *testing.T) {
	line, err := permissionAllowLine("r1", nil)
	require.NoError(t, err)
	assert.Equal(t, `{"type":"control_response","response":{"subtype":"success","request_id":"r1","response":{"behavior":"allow"}}}`+"\n", string(line))
}

func TestControlProto_AllowRefusesAnInputThatIsNotAnObject(t *testing.T) {
	for _, in := range []string{``, ` `, `null`, `[]`, `"x"`, `{"a":`, `1`} {
		_, err := permissionAllowLine("r1", json.RawMessage(in))
		assert.Error(t, err, "%q", in)
	}
}

func TestControlProto_DenyCarriesTheMessageVerbatim(t *testing.T) {
	msg := "Write may only use files inside \"/tmp/x\" — <never> & \n second line"
	var out struct {
		Type     string `json:"type"`
		Response struct {
			Subtype   string `json:"subtype"`
			RequestID string `json:"request_id"`
			Response  struct {
				Behavior string `json:"behavior"`
				Message  string `json:"message"`
			} `json:"response"`
		} `json:"response"`
	}
	line := permissionDenyLine("r9", msg)
	assert.Equal(t, 1, strings.Count(string(line), "\n"), "the message's newline is escaped")
	require.NoError(t, json.Unmarshal(line, &out))
	assert.Equal(t, "control_response", out.Type)
	assert.Equal(t, "success", out.Response.Subtype)
	assert.Equal(t, "r9", out.Response.RequestID)
	assert.Equal(t, "deny", out.Response.Response.Behavior)
	assert.Equal(t, msg, out.Response.Response.Message)
}

// mcpStatusPairs maps each recorded mcp_status request id to the CLI's answer.
func mcpStatusPairs(t *testing.T) map[string]string {
	t.Helper()
	lines := readFixture(t, "claude_ai_mcp_status.jsonl")
	require.Zero(t, len(lines)%2, "request/answer pairs")
	out := map[string]string{}
	for i := 0; i < len(lines); i += 2 {
		var req controlLine
		require.NoError(t, json.Unmarshal([]byte(lines[i]), &req))
		assert.JSONEq(t, lines[i], strings.TrimSuffix(string(mcpStatusRequestLine(req.RequestID)), "\n"),
			"our request matches the recorded one")
		out[req.RequestID] = lines[i+1]
	}
	return out
}

func TestControlProto_MCPStatusAnnotations(t *testing.T) {
	pairs := mcpStatusPairs(t)

	for _, id := range []string{"status_0", "status_disallow_0", "status_off"} {
		servers, ok, err := parseMCPStatusResponse([]byte(pairs[id]), id)
		require.True(t, ok, id)
		require.NoError(t, err, id)
		assert.NotNil(t, servers, "%s: an empty answer is a non-nil empty list", id)
		assert.Empty(t, servers, id)
	}

	pending, ok, err := parseMCPStatusResponse([]byte(pairs["status_disallow_1"]), "status_disallow_1")
	require.True(t, ok)
	require.NoError(t, err)
	require.NotEmpty(t, pending)
	assert.Equal(t, MCPServerStatus{Name: "claude.ai Claude Docs", Status: "pending",
		Source: "claudeai", ConfigType: "claudeai-proxy"}, pending[0])

	servers, ok, err := parseMCPStatusResponse([]byte(pairs["status_1"]), "status_1")
	require.True(t, ok)
	require.NoError(t, err)
	byName := map[string]MCPServerStatus{}
	for _, s := range servers {
		byName[s.Name] = s
	}
	docs := byName["claude.ai Claude Docs"]
	assert.Equal(t, "connected", docs.Status)
	assert.Equal(t, "claudeai", docs.Source)
	assert.Equal(t, "claudeai-proxy", docs.ConfigType)
	yes := true
	tools := map[string]MCPToolInfo{}
	for _, tl := range docs.Tools {
		tools[tl.Name] = tl
	}
	assert.Len(t, tools, 8)
	for _, name := range []string{"create", "update", "batch"} {
		assert.Equal(t, MCPToolInfo{Name: name}, tools[name], "%s: no annotation → nil hints", name)
	}
	for _, name := range []string{"read", "query", "guide", "export"} {
		assert.Equal(t, MCPToolInfo{Name: name, ReadOnly: &yes}, tools[name], name)
	}
	assert.Equal(t, MCPToolInfo{Name: "delete", Destructive: &yes}, tools["delete"])

	a := byName["claude.ai Connector A"]
	assert.Equal(t, "needs-auth", a.Status)
	assert.Nil(t, a.Tools, "a server that is not connected lists no tools")
}

func TestControlProto_MCPStatusOtherLines(t *testing.T) {
	pairs := mcpStatusPairs(t)
	_, ok, err := parseMCPStatusResponse([]byte(pairs["status_1"]), "status_0")
	assert.False(t, ok, "another request's answer")
	assert.NoError(t, err)

	for _, line := range append(readFixture(t, "claude_ai_control_other.jsonl"), readFixture(t, "claude_ai_can_use_tool.jsonl")...) {
		_, ok, err := parseMCPStatusResponse([]byte(line), "status_1")
		assert.False(t, ok, "%.80s", line)
		assert.NoError(t, err)
	}
	_, ok, _ = parseMCPStatusResponse([]byte(pairs["status_1"]), "")
	assert.False(t, ok, "an empty request id matches nothing")

	_, ok, err = parseMCPStatusResponse([]byte(`{"type":"control_response","response":{"subtype":"error","request_id":"s1","error":"boom"}}`), "s1")
	assert.True(t, ok)
	assert.ErrorContains(t, err, "boom")

	_, ok, err = parseMCPStatusResponse([]byte(`{"type":"control_response","response":{"subtype":"success","request_id":"s1","response":{}}}`), "s1")
	assert.True(t, ok)
	assert.Error(t, err, "an answer without mcpServers is not an empty list")

	_, ok, err = parseMCPStatusResponse([]byte(`{"type":"control_response","response":{"subtype":"success","request_id":"s1","response":{"mcpServers":"x"}}}`), "s1")
	assert.True(t, ok, "our answer, even when it does not decode")
	assert.Error(t, err)
}

func TestControlProto_CancelRequest(t *testing.T) {
	other := readFixture(t, "claude_ai_control_other.jsonl")
	held, ok := parseControlRequest([]byte(readFixture(t, "claude_ai_can_use_tool.jsonl")[12]))
	require.True(t, ok)

	var cancelled []string
	for _, line := range other {
		if id, ok := parseControlCancel([]byte(line)); ok {
			cancelled = append(cancelled, id)
		}
	}
	assert.Equal(t, []string{held.RequestID}, cancelled, "the interrupt withdrew the held Write request")

	_, ok = parseControlCancel([]byte(`{"type":"control_cancel_request"}`))
	assert.False(t, ok, "no request id")
}

func TestControlProto_PermissionDenied(t *testing.T) {
	var got []permissionDenied
	for _, line := range readFixture(t, "claude_ai_control_other.jsonl") {
		if d, ok := parsePermissionDenied([]byte(line)); ok {
			got = append(got, d)
		}
	}
	require.Len(t, got, 1)
	d := got[0]
	assert.Equal(t, "Artifact", d.ToolName)
	assert.Equal(t, "toolu_0166Hf1n5PnoYrrhu8mS5Uza", d.ToolUseID)
	assert.Equal(t, "safetyCheck", d.ReasonType)
	assert.Equal(t, "No Artifact at that url that the user can see", d.Reason)
	assert.True(t, strings.HasPrefix(d.Message, "There is no Artifact at https://claude.ai/artifact/"))

	_, ok := parsePermissionDenied([]byte(readFixture(t, "claude_ai_init.jsonl")[0]))
	assert.False(t, ok, "system/init is not a denial")
}

// TestControlProto_PolicyCallMatchesConnectorPolicy pins the codec ↔
// connectorpolicy contract: the policy gets mcp_server.name of an account
// connector, and any other server fails closed.
func TestControlProto_PolicyCallMatchesConnectorPolicy(t *testing.T) {
	lines := readFixture(t, "claude_ai_can_use_tool.jsonl")
	inCwd := func(p string) error {
		if strings.HasPrefix(p, "/tmp/probe/cwd/") {
			return nil
		}
		return errors.New("outside")
	}
	policy := connectorpolicy.Policy{Disabled: map[string]bool{}, PathCheck: inCwd, PublishDir: "/tmp/probe/cwd"}
	decide := func(line string) connectorpolicy.Decision {
		req, ok := parseControlRequest([]byte(line))
		require.True(t, ok)
		return policy.Decide(req.policyCall())
	}

	assert.Equal(t, connectorpolicy.Allow, decide(lines[10]).Verdict, "Claude Docs guide")
	assert.Equal(t, connectorpolicy.Ask, decide(lines[11]).Verdict, "Claude Docs delete")
	assert.Equal(t, connectorpolicy.Allow, decide(lines[7]).Verdict, "publish from inside")
	assert.Equal(t, connectorpolicy.Allow, decide(lines[4]).Verdict, "Write inside")
	assert.Equal(t, connectorpolicy.Deny, decide(lines[6]).Verdict, "Write outside")
	assert.Equal(t, connectorpolicy.Ask, decide(lines[9]).Verdict, "Artifact pin")

	guide := lines[10]
	const recordedServer = `"mcp_server":{"name":"claude.ai Claude Docs","source":"claudeai"}`
	require.Contains(t, guide, recordedServer)
	for name, server := range map[string]string{
		"another source":        `"mcp_server":{"name":"claude.ai Claude Docs","source":"local"}`,
		"no source":             `"mcp_server":{"name":"claude.ai Claude Docs"}`,
		"a bare string":         `"mcp_server":"claude.ai Claude Docs"`,
		"no name":               `"mcp_server":{"source":"claudeai"}`,
		"not an object":         `"mcp_server":42`,
		"missing on a mcp tool": `"x":null`,
		"null on a mcp tool":    `"mcp_server":null`,
		"a renamed server":      `"mcp_server":{"name":"claude.ai Other","source":"claudeai"}`,
	} {
		d := decide(strings.Replace(guide, recordedServer, server, 1))
		assert.Equal(t, connectorpolicy.Deny, d.Verdict, name)
	}

	// A built-in name with an mcp_server is not the built-in.
	write := strings.Replace(lines[4], `"tool_name":"Write"`,
		`"tool_name":"Write","mcp_server":{"name":"local","source":"project"}`, 1)
	assert.Equal(t, connectorpolicy.Deny, decide(write).Verdict)
}

func TestControlProto_TranslatorIgnoresControlLines(t *testing.T) {
	tr := NewClaudeTranslator(func() string { return "u1" })
	var lines []string
	lines = append(lines, readFixture(t, "claude_ai_can_use_tool.jsonl")...)
	lines = append(lines, readFixture(t, "claude_ai_mcp_status.jsonl")...)
	for _, line := range lines {
		events, err := tr.Feed([]byte(line))
		require.NoError(t, err)
		assert.Empty(t, events, "%.80s", line)
	}
}

func TestEvents_ToolWaitEncodesActionID(t *testing.T) {
	golden := readFixture(t, "events_v2_tool_wait.jsonl")
	require.Len(t, golden, 1)
	b, err := json.Marshal(toolWaitEvent("u7", "toolu_012DAzxzTcKsUABYq7nUo3Hn", 42))
	require.NoError(t, err)
	assert.Equal(t, golden[0], string(b), "the Swift parser test reads this line")
}

func TestEvents_PublishedSourceEncoding(t *testing.T) {
	golden := readFixture(t, "events_v2_published_source.jsonl")
	require.Len(t, golden, 1)
	ok := true
	const url = "https://claude.ai/artifact/PrbbeQQQQQQQQQQQQQQQQQ"
	b, err := json.Marshal(Event{Type: EventToolEnd, TurnID: "u7", ID: "toolu_01Xn2Hi76kJ1KPMTGBqp7ixe",
		OK: &ok, Summary: "Published Quarterly plan", Sources: []Source{publishedSource(url, "Quarterly plan")}})
	require.NoError(t, err)
	assert.Equal(t, golden[0], string(b), "the Swift link-card test reads this line")
}
