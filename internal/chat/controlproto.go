package chat

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"

	"watchtower/internal/chat/connectorpolicy"
)

// Control protocol codec for the claude.ai-mode session (#737). With
// --permission-prompt-tool stdio the CLI asks the host about every call that
// is not pre-allowed (can_use_tool) and answers the host's mcp_status. The
// shapes are the ones recorded with Claude Code 2.1.302 in
// testdata/claude_ai_*.jsonl (testdata/claude_ai_probe.md); the golden tests
// in controlproto_test.go fail when a CLI upgrade changes them.
//
// Every key is read exactly (a Go struct would also bind "Tool_Name" or
// "Destructive"): the codec must see what the CLI, which reads exact keys,
// acts on — the same rule the connector policy applies to the input.

// mcpServerSourceClaudeAI is the mcp_server source of an account connector.
const mcpServerSourceClaudeAI = "claudeai"

// permissionRequest is one can_use_tool control request.
type permissionRequest struct {
	RequestID string
	ToolName  string // raw CLI name: Write, Artifact, mcp__claude_ai_Claude_Docs__delete
	ToolUseID string
	// DisplayName is the CLI's human label ("Delete", "Write"); the protocol
	// has no title field.
	DisplayName string
	// Description and DecisionReason are the CLI's own explanation (built-ins
	// only; e.g. "Claude wants to publish …" for an Artifact publish).
	Description    string
	DecisionReason string
	// MCPServer is mcp_server.name ("claude.ai Claude Docs"), MCPServerSource
	// its source ("claudeai"); both "" for a built-in.
	MCPServer       string
	MCPServerSource string
	// Input is request.input exactly as received. An allow that keeps the
	// call as sent echoes these bytes: an Artifact publish input carries
	// CLI-internal __artifact* keys (a sha256 pin of the source) that a
	// rebuilt input would drop.
	Input json.RawMessage
	// Malformed, when set, says why the request cannot be judged (no
	// tool_name or tool_use_id, input not an object). The gate denies it
	// with this reason; policyCall yields a call the policy denies.
	Malformed string

	// hasMCPServer: the request carried an mcp_server, even a malformed one.
	hasMCPServer bool
}

// parseControlRequest decodes a can_use_tool control request; false for any
// other line (another control subtype, a control_response, a
// control_cancel_request, stream output) and for a request without a
// request_id, which cannot be answered. A can_use_tool that has a request_id
// but lacks what the gate needs is returned with Malformed set, so it is
// still answered (denied).
func parseControlRequest(line []byte) (permissionRequest, bool) {
	env, ok := decodeObject(line)
	if !ok || env.str("type") != "control_request" || env.str("request_id") == "" {
		return permissionRequest{}, false
	}
	req, ok := decodeObject(env["request"])
	if !ok || req.str("subtype") != "can_use_tool" {
		return permissionRequest{}, false
	}
	r := permissionRequest{
		RequestID:      env.str("request_id"),
		ToolName:       req.str("tool_name"),
		ToolUseID:      req.str("tool_use_id"),
		DisplayName:    req.str("display_name"),
		Description:    req.str("description"),
		DecisionReason: req.str("decision_reason"),
		Input:          req["input"],
	}
	if raw, ok := req["mcp_server"]; ok && !bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		r.hasMCPServer = true
		if srv, ok := decodeObject(raw); ok {
			r.MCPServer = srv.str("name")
			r.MCPServerSource = srv.str("source")
		}
	}
	switch {
	case r.ToolName == "":
		r.Malformed = "the permission request names no tool"
	case r.ToolUseID == "":
		r.Malformed = "the permission request has no tool_use_id"
	case !isJSONObject(r.Input):
		r.Malformed = "the permission request's input is not a JSON object"
	}
	return r, true
}

// policyCall is the connector policy's view of the request. Only an account
// connector (source "claudeai") passes its server name through; any other
// mcp_server — a local server, a malformed or nameless one — gets a name
// that never carries the "claude.ai " prefix, so the policy denies it
// (spec D1: a stray server fails closed) and never treats it as a built-in.
// A Malformed request becomes a call with no tool, which the policy denies.
func (r permissionRequest) policyCall() connectorpolicy.Call {
	if r.Malformed != "" {
		return connectorpolicy.Call{}
	}
	c := connectorpolicy.Call{Tool: r.ToolName, Input: r.Input}
	switch {
	case !r.hasMCPServer: // a built-in
	case r.MCPServerSource == mcpServerSourceClaudeAI && r.MCPServer != "":
		c.Server = r.MCPServer
	default:
		c.Server = fmt.Sprintf("untrusted server %q (source %q)", r.MCPServer, r.MCPServerSource)
	}
	return c
}

// permissionAllowLine answers a can_use_tool with allow. input REPLACES the
// call's input and must be a JSON object: pass permissionRequest.Input to run
// the call as the policy checked it, or the owner-approved input. There is
// deliberately no "run as sent" form (an allow without updatedInput), so a
// lost input is an error, never a call run with bytes nobody checked.
func permissionAllowLine(requestID string, input json.RawMessage) ([]byte, error) {
	trimmed := bytes.TrimSpace(input)
	if !isJSONObject(trimmed) {
		return nil, errors.New("updatedInput is not a JSON object")
	}
	return controlResponseLine(requestID, struct {
		Behavior     string          `json:"behavior"`
		UpdatedInput json.RawMessage `json:"updatedInput"`
	}{"allow", trimmed})
}

// permissionDenyLine answers a can_use_tool with deny. The model receives
// message verbatim as the call's error tool_result; the key is always sent.
func permissionDenyLine(requestID, message string) []byte {
	b, err := controlResponseLine(requestID, struct {
		Behavior string `json:"behavior"`
		Message  string `json:"message"`
	}{"deny", message})
	if err != nil {
		// Only strings: encoding/json cannot fail on them (invalid UTF-8 is
		// replaced, not refused).
		panic(fmt.Sprintf("encoding a deny line: %v", err))
	}
	return b
}

// controlResponseLine encodes a successful control_response to the CLI,
// newline-terminated. HTML escaping is off so an echoed input keeps its bytes
// (only insignificant whitespace is compacted).
func controlResponseLine(requestID string, response any) ([]byte, error) {
	type body struct {
		Subtype   string `json:"subtype"`
		RequestID string `json:"request_id"`
		Response  any    `json:"response"`
	}
	line := struct {
		Type     string `json:"type"`
		Response body   `json:"response"`
	}{"control_response", body{"success", requestID, response}}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(line); err != nil {
		return nil, fmt.Errorf("encoding control_response: %w", err)
	}
	return buf.Bytes(), nil // Encode appends the newline
}

// mcpStatusRequestLine asks the CLI for its MCP servers and their tools.
func mcpStatusRequestLine(requestID string) []byte {
	b, err := json.Marshal(map[string]any{
		"type": "control_request", "request_id": requestID,
		"request": map[string]string{"subtype": "mcp_status"},
	})
	if err != nil {
		panic(fmt.Sprintf("encoding mcp_status: %v", err)) // only strings: cannot fail
	}
	return append(b, '\n')
}

// MCPServerStatus is one server of an mcp_status answer. Right after spawn
// the list is empty: the account's connectors are fetched asynchronously and
// settle within a few seconds.
type MCPServerStatus struct {
	Name   string // "claude.ai Claude Docs"
	Status string // connected, needs-auth, pending (other values may appear)
	// Source is "claudeai" and ConfigType "claudeai-proxy" for an account
	// connector.
	Source     string
	ConfigType string
	// Tools is kept only for a connected server (nil otherwise), so a
	// catalog never classifies a tool of a server that cannot run it.
	Tools []MCPToolInfo
}

// MCPToolInfo is one tool and its own MCP annotations; nil = not declared
// (absent, or not a bool).
type MCPToolInfo struct {
	Name        string
	ReadOnly    *bool
	Destructive *bool
}

// parseMCPStatusResponse decodes the CLI's answer to mcpStatusRequestLine.
// ok is false when line is not the control_response for requestID; once it
// is, any error answer or unexpected shape is (nil, true, err). A
// settled-but-empty answer is a non-nil empty slice.
func parseMCPStatusResponse(line []byte, requestID string) ([]MCPServerStatus, bool, error) {
	body, ok := controlResponseFor(line, requestID)
	if !ok {
		return nil, false, nil
	}
	if subtype := body.str("subtype"); subtype != "success" {
		return nil, true, fmt.Errorf("mcp_status failed: %s %s", subtype, bytes.TrimSpace(body["error"]))
	}
	resp, ok := decodeObject(body["response"])
	if !ok {
		return nil, true, errors.New("mcp_status answer has no response object")
	}
	var list []json.RawMessage
	if raw := resp["mcpServers"]; raw == nil || json.Unmarshal(raw, &list) != nil || list == nil {
		return nil, true, errors.New("mcp_status answer has no mcpServers list")
	}
	servers := make([]MCPServerStatus, 0, len(list))
	for i, raw := range list {
		s, ok := decodeObject(raw)
		if !ok {
			return nil, true, fmt.Errorf("mcp_status server %d is not an object", i)
		}
		config, _ := decodeObject(s["config"])
		st := MCPServerStatus{Name: s.str("name"), Status: s.str("status"),
			Source: s.str("source"), ConfigType: config.str("type")}
		if st.Status == "connected" {
			tools, err := decodeTools(s["tools"])
			if err != nil {
				return nil, true, fmt.Errorf("mcp_status server %q: %w", st.Name, err)
			}
			st.Tools = tools
		}
		servers = append(servers, st)
	}
	return servers, true, nil
}

// decodeTools decodes a server's tools list (absent = none).
func decodeTools(raw json.RawMessage) ([]MCPToolInfo, error) {
	if raw == nil {
		return nil, nil
	}
	var list []json.RawMessage
	if json.Unmarshal(raw, &list) != nil {
		return nil, errors.New("tools is not a list")
	}
	var out []MCPToolInfo
	for i, rawTool := range list {
		tool, ok := decodeObject(rawTool)
		if !ok {
			return nil, fmt.Errorf("tool %d is not an object", i)
		}
		ann, _ := decodeObject(tool["annotations"])
		out = append(out, MCPToolInfo{Name: tool.str("name"),
			ReadOnly: ann.boolPtr("readOnly"), Destructive: ann.boolPtr("destructive")})
	}
	return out, nil
}

// controlResponseFor returns the response body of line when it is the CLI's
// control_response to requestID.
func controlResponseFor(line []byte, requestID string) (jsonObject, bool) {
	env, ok := decodeObject(line)
	if !ok || requestID == "" || env.str("type") != "control_response" {
		return nil, false
	}
	body, ok := decodeObject(env["response"])
	if !ok || body.str("request_id") != requestID {
		return nil, false
	}
	return body, true
}

// parseControlCancel decodes a control_cancel_request: the CLI withdrew the
// can_use_tool with that request id (an interrupt arrived while it waited).
// The tool never runs; a late answer for the id is ignored by the CLI.
func parseControlCancel(line []byte) (requestID string, ok bool) {
	env, ok := decodeObject(line)
	if !ok || env.str("type") != "control_cancel_request" || env.str("request_id") == "" {
		return "", false
	}
	return env.str("request_id"), true
}

// permissionDenied is a system/permission_denied line: the CLI refused a
// call on its own, without a can_use_tool (e.g. an Artifact delete of a URL
// the account cannot see). An error tool_result carrying Message follows.
type permissionDenied struct {
	ToolName, ToolUseID string
	ReasonType          string // decision_reason_type: safetyCheck, workingDir, other
	Reason              string // decision_reason
	Message             string // what the model is told
}

// parsePermissionDenied decodes a system/permission_denied line.
func parsePermissionDenied(line []byte) (permissionDenied, bool) {
	l, ok := decodeObject(line)
	if !ok || l.str("type") != "system" || l.str("subtype") != "permission_denied" {
		return permissionDenied{}, false
	}
	return permissionDenied{
		ToolName: l.str("tool_name"), ToolUseID: l.str("tool_use_id"),
		ReasonType: l.str("decision_reason_type"), Reason: l.str("decision_reason"), Message: l.str("message"),
	}, true
}

// jsonObject is a JSON object read by exact key.
type jsonObject map[string]json.RawMessage

// decodeObject decodes raw as a JSON object; false for anything else.
func decodeObject(raw []byte) (jsonObject, bool) {
	var m jsonObject
	if json.Unmarshal(raw, &m) != nil || m == nil {
		return nil, false
	}
	return m, true
}

// str reads a string field; "" when absent or not a string.
func (m jsonObject) str(key string) string {
	var s string
	if json.Unmarshal(m[key], &s) != nil {
		return ""
	}
	return s
}

// boolPtr reads a bool field; nil when absent, null or not a bool.
func (m jsonObject) boolPtr(key string) *bool {
	var b bool
	raw := bytes.TrimSpace(m[key])
	if bytes.Equal(raw, []byte("null")) || json.Unmarshal(raw, &b) != nil {
		return nil
	}
	return &b
}

func isJSONObject(raw json.RawMessage) bool {
	_, ok := decodeObject(raw)
	return ok
}
