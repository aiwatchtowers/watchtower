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
// The request object is read by exact key (a Go struct would also accept
// "Tool_Name"), the same rule the connector policy applies to the input.

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

	// hasMCPServer: the request carried an mcp_server, even a malformed one.
	hasMCPServer bool
}

// controlLine is the envelope every control line shares.
type controlLine struct {
	Type      string          `json:"type"`
	RequestID string          `json:"request_id"`
	Request   json.RawMessage `json:"request"`
	Response  json.RawMessage `json:"response"`
}

// parseControlRequest decodes a can_use_tool control request; false for any
// other line (another control subtype, a control_response, a
// control_cancel_request, stream output) and for a request without a
// request_id, which cannot be answered.
func parseControlRequest(line []byte) (permissionRequest, bool) {
	var l controlLine
	if json.Unmarshal(line, &l) != nil || l.Type != "control_request" || l.RequestID == "" {
		return permissionRequest{}, false
	}
	var req map[string]json.RawMessage
	if json.Unmarshal(l.Request, &req) != nil || exactString(req, "subtype") != "can_use_tool" {
		return permissionRequest{}, false
	}
	r := permissionRequest{
		RequestID:      l.RequestID,
		ToolName:       exactString(req, "tool_name"),
		ToolUseID:      exactString(req, "tool_use_id"),
		DisplayName:    exactString(req, "display_name"),
		Description:    exactString(req, "description"),
		DecisionReason: exactString(req, "decision_reason"),
		Input:          req["input"],
	}
	if raw, ok := req["mcp_server"]; ok && !isJSONNull(raw) {
		r.hasMCPServer = true
		var srv map[string]json.RawMessage
		if json.Unmarshal(raw, &srv) == nil {
			r.MCPServer = exactString(srv, "name")
			r.MCPServerSource = exactString(srv, "source")
		}
	}
	return r, true
}

// policyCall is the connector policy's view of the request. Only an account
// connector (source "claudeai") passes its server name through; any other
// mcp_server — a local server, a malformed or nameless one — gets a name
// that never carries the "claude.ai " prefix, so the policy denies it
// (spec D1: a stray server fails closed) and never treats it as a built-in.
func (r permissionRequest) policyCall() connectorpolicy.Call {
	c := connectorpolicy.Call{Tool: r.ToolName, Input: r.Input}
	switch {
	case !r.hasMCPServer:
	case r.MCPServerSource == mcpServerSourceClaudeAI && r.MCPServer != "":
		c.Server = r.MCPServer
	default:
		c.Server = fmt.Sprintf("untrusted server %q (source %q)", r.MCPServer, r.MCPServerSource)
	}
	return c
}

// permissionAllowLine answers a can_use_tool with allow. updatedInput nil
// runs the call as sent; otherwise it REPLACES the input and must be a JSON
// object — echo permissionRequest.Input to keep the call unchanged.
func permissionAllowLine(requestID string, updatedInput json.RawMessage) ([]byte, error) {
	if updatedInput != nil {
		trimmed := bytes.TrimSpace(updatedInput)
		if !json.Valid(trimmed) || len(trimmed) == 0 || trimmed[0] != '{' {
			return nil, errors.New("updatedInput is not a JSON object")
		}
		updatedInput = trimmed
	}
	return controlResponseLine(requestID, permissionAnswer{Behavior: "allow", UpdatedInput: updatedInput})
}

// permissionDenyLine answers a can_use_tool with deny. The model receives
// message verbatim as the call's error tool_result.
func permissionDenyLine(requestID, message string) []byte {
	b, err := controlResponseLine(requestID, permissionAnswer{Behavior: "deny", Message: message})
	if err != nil {
		panic(fmt.Sprintf("encoding a deny line: %v", err)) // only strings: cannot fail
	}
	return b
}

type permissionAnswer struct {
	Behavior     string          `json:"behavior"`
	UpdatedInput json.RawMessage `json:"updatedInput,omitempty"`
	Message      string          `json:"message,omitempty"`
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

// MCPServerStatus is one server of an mcp_status answer. Tools is nil unless
// the server is connected. Right after spawn the list is empty: the account's
// connectors are fetched asynchronously and settle within a few seconds.
type MCPServerStatus struct {
	Name   string // "claude.ai Claude Docs"
	Status string // connected, needs-auth, pending (other values may appear)
	// Source is "claudeai" and ConfigType "claudeai-proxy" for an account
	// connector.
	Source     string
	ConfigType string
	Tools      []MCPToolInfo
}

// MCPToolInfo is one tool and its own MCP annotations; nil = not declared.
type MCPToolInfo struct {
	Name        string
	ReadOnly    *bool
	Destructive *bool
}

// parseMCPStatusResponse decodes the CLI's answer to mcpStatusRequestLine.
// ok is false when line is not the control_response for requestID; err is
// set when it is, but the CLI answered with an error or an unexpected shape.
// A settled-but-empty answer is a non-nil empty slice.
func parseMCPStatusResponse(line []byte, requestID string) ([]MCPServerStatus, bool, error) {
	head, ok := controlResponseFor(line, requestID)
	if !ok {
		return nil, false, nil
	}
	if head.Subtype != "success" {
		return nil, true, fmt.Errorf("mcp_status failed: %s %s", head.Subtype, head.Error)
	}
	var resp struct {
		MCPServers *[]struct {
			Name   string `json:"name"`
			Status string `json:"status"`
			Source string `json:"source"`
			Config struct {
				Type string `json:"type"`
			} `json:"config"`
			Tools []struct {
				Name        string `json:"name"`
				Annotations struct {
					ReadOnly    *bool `json:"readOnly"`
					Destructive *bool `json:"destructive"`
				} `json:"annotations"`
			} `json:"tools"`
		} `json:"mcpServers"`
	}
	if err := json.Unmarshal(head.Response, &resp); err != nil {
		return nil, true, fmt.Errorf("decoding the mcp_status answer: %w", err)
	}
	if resp.MCPServers == nil {
		return nil, true, errors.New("mcp_status answer has no mcpServers")
	}
	servers := make([]MCPServerStatus, 0, len(*resp.MCPServers))
	for _, s := range *resp.MCPServers {
		st := MCPServerStatus{Name: s.Name, Status: s.Status, Source: s.Source, ConfigType: s.Config.Type}
		for _, tl := range s.Tools {
			st.Tools = append(st.Tools, MCPToolInfo{
				Name: tl.Name, ReadOnly: tl.Annotations.ReadOnly, Destructive: tl.Annotations.Destructive,
			})
		}
		servers = append(servers, st)
	}
	return servers, true, nil
}

// controlResponseBody is the response object of a control_response.
type controlResponseBody struct {
	Subtype   string          `json:"subtype"`
	RequestID string          `json:"request_id"`
	Error     string          `json:"error"`
	Response  json.RawMessage `json:"response"`
}

// controlResponseFor returns the body of line when it is the CLI's
// control_response to requestID.
func controlResponseFor(line []byte, requestID string) (controlResponseBody, bool) {
	var l controlLine
	var body controlResponseBody
	if requestID == "" || json.Unmarshal(line, &l) != nil || l.Type != "control_response" ||
		json.Unmarshal(l.Response, &body) != nil || body.RequestID != requestID {
		return controlResponseBody{}, false
	}
	return body, true
}

// parseControlCancel decodes a control_cancel_request: the CLI withdrew the
// can_use_tool with that request id (an interrupt arrived while it waited).
// The tool never runs; a late answer for the id is ignored by the CLI.
func parseControlCancel(line []byte) (requestID string, ok bool) {
	var l controlLine
	if json.Unmarshal(line, &l) != nil || l.Type != "control_cancel_request" || l.RequestID == "" {
		return "", false
	}
	return l.RequestID, true
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
	var l struct {
		Type               string `json:"type"`
		Subtype            string `json:"subtype"`
		ToolName           string `json:"tool_name"`
		ToolUseID          string `json:"tool_use_id"`
		DecisionReasonType string `json:"decision_reason_type"`
		DecisionReason     string `json:"decision_reason"`
		Message            string `json:"message"`
	}
	if json.Unmarshal(line, &l) != nil || l.Type != "system" || l.Subtype != "permission_denied" {
		return permissionDenied{}, false
	}
	return permissionDenied{
		ToolName: l.ToolName, ToolUseID: l.ToolUseID,
		ReasonType: l.DecisionReasonType, Reason: l.DecisionReason, Message: l.Message,
	}, true
}

// exactString reads a string field by its exact key; "" when absent or not a
// string.
func exactString(m map[string]json.RawMessage, key string) string {
	var s string
	if json.Unmarshal(m[key], &s) != nil {
		return ""
	}
	return s
}

func isJSONNull(raw json.RawMessage) bool {
	return bytes.Equal(bytes.TrimSpace(raw), []byte("null"))
}
