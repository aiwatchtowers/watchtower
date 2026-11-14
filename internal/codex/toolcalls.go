package codex

import (
	"bytes"
	"encoding/json"
	"strings"
)

// ToolCall is one finished mcp_tool_call item of a `codex exec --json` run:
// its server (codex_apps for an app/connector tool), its tool name, whether
// it failed, and its result or error text.
type ToolCall struct {
	Server, Tool string
	Failed       bool
	Text         string
}

// SetToolCallObserver makes QuerySync hand every finished MCP/app tool call
// of the run to observe once the child exited, failed runs included (an
// automation agent() child's Live Slack bookkeeping, #1709).
func (c *Client) SetToolCallObserver(observe func(ToolCall)) { c.onToolCall = observe }

// observeToolCalls hands the item.completed mcp_tool_call events of output
// to the observer.
func (c *Client) observeToolCalls(output []byte) {
	if c.onToolCall == nil {
		return
	}
	for line := range bytes.SplitSeq(output, []byte("\n")) {
		var ev CodexEvent
		if json.Unmarshal(bytes.TrimSpace(line), &ev) != nil || ev.Type != "item.completed" ||
			ev.Item == nil || ev.Item.Type != "mcp_tool_call" {
			continue
		}
		call := ToolCall{Server: ev.Item.Server, Tool: ev.Item.Tool, Failed: ev.Item.Status != "completed"}
		switch {
		case ev.Item.ToolError != nil:
			call.Text = ev.Item.ToolError.Message
		case ev.Item.Result != nil:
			var b strings.Builder
			for _, p := range ev.Item.Result.Content {
				b.WriteString(p.Text)
			}
			call.Text = b.String()
		}
		c.onToolCall(call)
	}
}
