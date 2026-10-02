package mcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"

	"github.com/google/jsonschema-go/jsonschema"
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
// A legacy workbench session (binding.LegacyNames, `mcp --project N`) lists
// the renamed workbench tools under their pre-rename names and reads every
// description, refusal and receipt in that vocabulary (Binding.Spell); the
// call itself dispatches by the tool's current name, the one agent_actions
// records.
func registerRegistry(s *mcpsdk.Server, database *db.DB, reg *tools.Registry, binding tools.Binding, mountWrites bool) {
	for _, t := range reg.List(binding.Surface) {
		tool := t
		listed := &mcpsdk.Tool{
			Name:        binding.Spell(tool.Name),
			Description: binding.Spell(tool.Description),
			InputSchema: spellSchema(binding, tool.InputSchema),
		}
		if tool.Access == tools.AccessRead {
			s.AddTool(listed, func(ctx context.Context, req *mcpsdk.CallToolRequest) (*mcpsdk.CallToolResult, error) {
				data, err := reg.CallRead(ctx, tool.Name, req.Params.Arguments, binding)
				if err != nil {
					var verr *tools.ValidationError
					if errors.As(err, &verr) {
						return errResult(binding.Spell(verr.Msg)), nil
					}
					return errResult(binding.Spell(err.Error())), nil
				}
				res, _, jerr := jsonResult(data)
				return res, jerr
			})
			continue
		}
		if !mountWrites {
			continue
		}
		s.AddTool(listed, func(ctx context.Context, req *mcpsdk.CallToolRequest) (*mcpsdk.CallToolResult, error) {
			rc, err := reg.Propose(ctx, tool.Name, req.Params.Arguments, binding)
			if err != nil {
				var verr *tools.ValidationError
				if errors.As(err, &verr) {
					return errResult(binding.Spell(verr.Msg)), nil
				}
				return errResult(binding.Spell(fmt.Sprintf("recording proposal: %v", err))), nil
			}
			rc.Tool, rc.Message, rc.Error = binding.Spell(rc.Tool), binding.Spell(rc.Message), binding.Spell(rc.Error)
			res, _, err := jsonResult(rc)
			return res, err
		})
	}

	if !mountWrites {
		return
	}

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
		return jsonResult(newActionView(*row))
	})
}

// spellSchema is a tool's input schema as binding's session lists it: the
// registry's own schema, or, for a legacy session, a copy whose texts name
// the renamed tools by their old names (Binding.Spell). The registry's
// schema is shared by every session and is never changed.
func spellSchema(binding tools.Binding, schema *jsonschema.Schema) any {
	if !binding.LegacyNames || schema == nil {
		return schema
	}
	raw, err := json.Marshal(schema)
	if err != nil {
		return schema
	}
	var spelled map[string]any
	if err := json.Unmarshal([]byte(binding.Spell(string(raw))), &spelled); err != nil {
		return schema
	}
	return spelled
}

// actionVisible decides whether get_action may show row to this session. A
// workbench session sees only its own workbench's rows. A binding with no
// conversation (conversation_id 0: a CLI-only install, spec §12, or a
// dev/test session with none bound) sees every other row; otherwise a row
// from a different conversation answers the same not-found error as a
// missing row, so the model cannot learn that an id it invented belongs to
// someone else's chat.
func actionVisible(row db.AgentAction, binding tools.Binding) bool {
	if binding.WorkbenchID != 0 {
		return row.ContextType == tools.WorkbenchContextType && row.ContextID == strconv.FormatInt(binding.WorkbenchID, 10)
	}
	return binding.ConversationID == 0 || row.ConversationID == binding.ConversationID
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
