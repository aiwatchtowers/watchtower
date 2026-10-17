package mcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// WithRegistry turns the server into the assistant's chat-mode server: the
// registry's tools visible on binding.Surface are mounted — reads dispatch
// through CallRead, writes become proposals stamped with binding — and
// get_action is registered. The developer-surface server passes no registry, so
// NewServer builds a read-only one (tools.NewReadRegistry) with mountWrites
// false: no write tools, no get_action (AGENT-02).
func WithRegistry(reg *tools.Registry, binding tools.Binding) ServerOption {
	return func(srv *Server) {
		srv.registry = reg
		srv.binding = binding
		srv.mountWrites = true
	}
}

type getActionArgs struct {
	ID int64 `json:"id" jsonschema:"the action id from a write tool's receipt"`
}

// registerRegistry mounts the registry's tools visible on binding.Surface. Read
// tools always mount (dispatched through CallRead, which records no proposal).
// Write tools and get_action mount only when mountWrites is set (chat mode) —
// dev mode passes false, so the developer surface never sees a write tool.
//
// hooks narrow the mounted set and gate each call (an automation agent()'s
// server); their zero value changes nothing.
func registerRegistry(s *mcpsdk.Server, database *db.DB, reg *tools.Registry, binding tools.Binding, mountWrites bool, hooks callHooks) {
	for _, t := range reg.List(binding.Surface) {
		tool := t
		if hooks.filter != nil && !hooks.filter(tool) {
			continue
		}
		listed := &mcpsdk.Tool{
			Name:        tool.Name,
			Description: tool.Description,
			InputSchema: tool.InputSchema,
		}
		if tool.Access == tools.AccessRead {
			s.AddTool(listed, readToolHandler(reg, tool, binding, hooks))
			continue
		}
		if !mountWrites {
			continue
		}
		s.AddTool(listed, writeToolHandler(reg, tool, binding, hooks))
	}

	if !mountWrites {
		return
	}
	registerGetAction(s, database, reg, binding)
}

// readToolHandler serves a read tool: the call gate, CallRead, then the
// result check.
func readToolHandler(reg *tools.Registry, tool *tools.Tool, binding tools.Binding, hooks callHooks) mcpsdk.ToolHandler {
	return func(ctx context.Context, req *mcpsdk.CallToolRequest) (*mcpsdk.CallToolResult, error) {
		args, refused := hooks.gateCall(ctx, tool, req.Params.Arguments)
		if refused != nil {
			return refused, nil
		}
		data, err := reg.CallRead(ctx, tool.Name, args, binding)
		if err != nil {
			var verr *tools.ValidationError
			if errors.As(err, &verr) {
				return errResult(verr.Msg), nil
			}
			return errResult(err.Error()), nil
		}
		return hooks.result(data)
	}
}

// writeToolHandler serves a write tool: the call gate, Propose, then the
// result check over the receipt.
func writeToolHandler(reg *tools.Registry, tool *tools.Tool, binding tools.Binding, hooks callHooks) mcpsdk.ToolHandler {
	return func(ctx context.Context, req *mcpsdk.CallToolRequest) (*mcpsdk.CallToolResult, error) {
		args, refused := hooks.gateCall(ctx, tool, req.Params.Arguments)
		if refused != nil {
			return refused, nil
		}
		rc, err := reg.Propose(ctx, tool.Name, args, binding)
		if err != nil {
			var verr *tools.ValidationError
			if errors.As(err, &verr) {
				return errResult(verr.Msg), nil
			}
			return errResult(fmt.Sprintf("recording proposal: %v", err)), nil
		}
		return hooks.result(rc)
	}
}

// registerGetAction mounts get_action (chat mode only): one proposal by id,
// visible only when binding may see it.
func registerGetAction(s *mcpsdk.Server, database *db.DB, reg *tools.Registry, binding tools.Binding) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name: "get_action",
		Description: "Look up one proposed action by id: its status (pending, approved, rejected, applied, " +
			"failed), result and error. Use it when the owner asks what happened to a proposal.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args getActionArgs) (*mcpsdk.CallToolResult, any, error) {
		if err := reg.WorkbenchAlive(ctx, binding); err != nil {
			return errResult(err.Error()), nil, nil
		}
		row, err := database.GetAgentAction(args.ID)
		if err != nil {
			return errResult("getting action: " + err.Error()), nil, nil
		}
		if row == nil || !actionVisible(*row, binding) {
			return errResult(fmt.Sprintf("no action #%d", args.ID)), nil, nil
		}
		view := newActionView(*row)
		// A row recorded before the Workbench rename reads under the
		// tool's current name, the one this session lists.
		view.Tool = tools.CanonicalToolName(row.Tool)
		return jsonResult(view)
	})
}

// callHooks are a chat-mode server's optional narrowing (WithToolFilter,
// WithCallGate, WithResultCheck).
type callHooks struct {
	filter      func(t *tools.Tool) bool
	gate        func(ctx context.Context, t *tools.Tool, args json.RawMessage) (json.RawMessage, error)
	resultCheck func(result []byte) error
}

// gateCall runs the call gate: the args to dispatch, or the error result of a
// refused call.
func (h callHooks) gateCall(ctx context.Context, t *tools.Tool, args json.RawMessage) (json.RawMessage, *mcpsdk.CallToolResult) {
	if h.gate == nil {
		return args, nil
	}
	gated, err := h.gate(ctx, t, args)
	if err != nil {
		return nil, errResult(err.Error())
	}
	return gated, nil
}

// result is jsonResult(v) passed through the result check.
func (h callHooks) result(v any) (*mcpsdk.CallToolResult, error) {
	res, _, err := jsonResult(v)
	if err != nil || res.IsError || h.resultCheck == nil {
		return res, err
	}
	text, ok := res.Content[0].(*mcpsdk.TextContent)
	if !ok {
		return errResult("the result is not text"), nil
	}
	if err := h.resultCheck([]byte(text.Text)); err != nil {
		return errResult(err.Error()), nil
	}
	return res, nil
}

// actionVisible decides whether get_action may show row to this session. An
// automation run's session (an agent() child) sees only its own run's rows —
// checked first, since a workbench automation's binding also carries the
// workbench. A workbench session sees only its own workbench's rows. A chat session sees
// only its own conversation's rows; a binding with no conversation
// (conversation_id 0: a CLI-only install, spec §12) sees only the
// conversation-less rows of its own surface — never a conversation's, a
// reaction's or a workbench's. Any other row answers the same not-found error
// as a missing row, so the model cannot learn that an id it invented belongs
// to someone else's chat.
func actionVisible(row db.AgentAction, binding tools.Binding) bool {
	if binding.AutomationRunID != 0 {
		return row.ContextType == tools.AutomationContextType && row.ContextID == strconv.FormatInt(binding.AutomationRunID, 10)
	}
	if binding.WorkbenchID != 0 {
		return row.ContextType == tools.WorkbenchContextType && row.ContextID == strconv.FormatInt(binding.WorkbenchID, 10)
	}
	if row.ConversationID != binding.ConversationID {
		return false
	}
	if binding.ConversationID != 0 {
		return true
	}
	return row.Surface == binding.Surface && row.ContextType != tools.WorkbenchContextType
}

// actionView is the model-facing shape of an agent_actions row.
type actionView struct {
	ID        int64           `json:"id"`
	Tool      string          `json:"tool"`
	Status    string          `json:"status"`
	Args      json.RawMessage `json:"args"`
	Reason    string          `json:"reason"`
	Result    json.RawMessage `json:"result,omitempty"`
	Error     string          `json:"error,omitempty"`
	CreatedAt string          `json:"created_at"`
	DecidedAt string          `json:"decided_at,omitempty"`
	AppliedAt string          `json:"applied_at,omitempty"`
}

// maxViewStringBytes caps one string value of the args get_action echoes.
// A write tool may pin bulky material into its stored args — the storage
// XHTML edit_confluence_page will write (up to 4 MiB), a rewritten section
// body in its changes — that the model needs only as "what was proposed",
// never verbatim. The rule is generic (every tool, every string at any
// depth) so a future tool cannot reopen the hole; the row itself is
// untouched, only the model-facing view is shortened.
const (
	maxViewStringBytes = 2048
	viewKeepRunes      = 500
)

// elideLargeStrings returns args with every string value over
// maxViewStringBytes cut to its first viewKeepRunes runes plus a marker
// naming its full size. Numbers keep their exact text (UseNumber: no
// float64 round trip turning an id into 1.2345e+19). Args that are not one
// valid JSON value pass through.
func elideLargeStrings(args string) json.RawMessage {
	dec := json.NewDecoder(strings.NewReader(args))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil || dec.Decode(new(any)) != io.EOF {
		return json.RawMessage(args)
	}
	out, err := json.Marshal(elideValue(v))
	if err != nil {
		return json.RawMessage(args)
	}
	return out
}

func elideValue(v any) any {
	switch x := v.(type) {
	case string:
		if len(x) <= maxViewStringBytes {
			return x
		}
		r := []rune(x)
		return fmt.Sprintf("%s… [elided: %d bytes]", string(r[:min(viewKeepRunes, len(r))]), len(x))
	case []any:
		for i := range x {
			x[i] = elideValue(x[i])
		}
	case map[string]any:
		for k := range x {
			x[k] = elideValue(x[k])
		}
	}
	return v
}

func newActionView(a db.AgentAction) actionView {
	v := actionView{ID: a.ID, Tool: a.Tool, Status: a.Status, Args: elideLargeStrings(a.ArgsJSON), Reason: a.Reason,
		Error: a.Error, CreatedAt: a.CreatedAt, DecidedAt: a.DecidedAt, AppliedAt: a.AppliedAt}
	if a.ResultJSON != "" {
		v.Result = json.RawMessage(a.ResultJSON)
	}
	return v
}
