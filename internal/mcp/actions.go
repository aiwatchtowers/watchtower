package mcp

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// WithRegistry turns the server into the assistant's chat-mode server: the
// registry's tools visible on binding.Surface are mounted, write calls become
// proposals stamped with binding, and get_action is registered. The
// developer-surface server never passes this option (AGENT-02).
func WithRegistry(reg *tools.Registry, binding tools.Binding) ServerOption {
	return func(srv *Server) {
		srv.registry = reg
		srv.binding = binding
	}
}

type getActionArgs struct {
	ID int64 `json:"id" jsonschema:"the action id from a write tool's receipt"`
}

func registerRegistry(s *mcpsdk.Server, database *db.DB, reg *tools.Registry, binding tools.Binding) {
	for _, t := range reg.List(binding.Surface) {
		tool := t
		s.AddTool(&mcpsdk.Tool{
			Name:        tool.Name,
			Description: tool.Description,
			InputSchema: tool.InputSchema,
		}, func(ctx context.Context, req *mcpsdk.CallToolRequest) (*mcpsdk.CallToolResult, error) {
			raw := json.RawMessage(req.Params.Arguments)
			if tool.Access != tools.AccessWrite {
				out, err := tool.Execute(ctx, database, tools.Call{Args: raw, Binding: binding})
				if err != nil {
					return errResult(err.Error()), nil
				}
				res, _, err := jsonResult(out)
				return res, err
			}
			rc, err := reg.Propose(ctx, tool.Name, raw, binding)
			if err != nil {
				var verr *tools.ValidationError
				if errors.As(err, &verr) {
					return errResult(verr.Msg), nil
				}
				return errResult(fmt.Sprintf("recording proposal: %v", err)), nil
			}
			res, _, err := jsonResult(rc)
			return res, err
		})
	}

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name: "get_action",
		Description: "Look up one proposed action by id: its status (pending, approved, rejected, applied, " +
			"failed), result and error. Use it when the owner asks what happened to a proposal.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args getActionArgs) (*mcpsdk.CallToolResult, any, error) {
		row, err := database.GetAgentAction(args.ID)
		if err != nil {
			return errResult("getting action: " + err.Error()), nil, nil
		}
		if row == nil {
			return errResult(fmt.Sprintf("no action #%d", args.ID)), nil, nil
		}
		return jsonResult(newActionView(*row))
	})
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

func newActionView(a db.AgentAction) actionView {
	v := actionView{ID: a.ID, Tool: a.Tool, Status: a.Status, Args: json.RawMessage(a.ArgsJSON), Reason: a.Reason,
		Error: a.Error, CreatedAt: a.CreatedAt, DecidedAt: a.DecidedAt, AppliedAt: a.AppliedAt}
	if a.ResultJSON != "" {
		v.Result = json.RawMessage(a.ResultJSON)
	}
	return v
}
