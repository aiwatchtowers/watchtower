package externalmcp

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// ToolError is a tool result the server flagged isError: the call reached
// the tool and the tool reported a failure (Message is its text).
type ToolError struct {
	Message string
}

func (e *ToolError) Error() string { return "tool error: " + e.Message }

// CallTool connects to the server, runs tools/call for tool with args (a
// JSON object, or empty) and returns the result: structuredContent when the
// server sent it, else {"text": <text contents joined by "\n">}. A result
// flagged isError is a *ToolError. ctx bounds the whole exchange; a stdio
// server is started for the call in its own process group, and the group is
// stopped before CallTool returns.
func CallTool(ctx context.Context, spec ServerSpec, tool string, args json.RawMessage) (json.RawMessage, error) {
	transport, stderr, err := discoveryTransport(ctx, spec)
	if err != nil {
		return nil, err
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "watchtower", Version: "1"}, nil)
	session, err := client.Connect(ctx, transport, nil)
	if err != nil {
		stopStdioServer(transport) // a server that started but failed the handshake
		return nil, withStderr(ctxOr(ctx, fmt.Errorf("connecting to the server: %w", err)), stderr)
	}
	defer func() { _ = session.Close() }()
	if ct, ok := transport.(*mcp.CommandTransport); ok {
		defer killProcessGroup(ct.Command)
	}

	var arguments any
	if len(args) > 0 {
		arguments = args
	}
	res, err := session.CallTool(ctx, &mcp.CallToolParams{Name: tool, Arguments: arguments})
	if err != nil {
		return nil, withStderr(ctxOr(ctx, fmt.Errorf("calling %s: %w", tool, err)), stderr)
	}

	var texts []string
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			texts = append(texts, tc.Text)
		}
	}
	text := strings.Join(texts, "\n")
	if res.IsError {
		return nil, &ToolError{Message: text}
	}
	if res.StructuredContent != nil {
		out, err := json.Marshal(res.StructuredContent)
		if err != nil {
			return nil, fmt.Errorf("encoding the structured result: %w", err)
		}
		return out, nil
	}
	return json.Marshal(map[string]string{"text": text})
}

// ctxOr makes a context expiry the error's cause, so callers can match
// context.DeadlineExceeded however the SDK worded the failure.
func ctxOr(ctx context.Context, err error) error {
	if cerr := ctx.Err(); cerr != nil {
		return fmt.Errorf("%w: %w", cerr, err)
	}
	return err
}
