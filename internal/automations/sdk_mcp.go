package automations

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/dop251/goja"

	"watchtower/internal/externalmcp"
)

// MCPModule defines mcp(server, tool, args?) (spec §5): the manifest check
// (AllowMCP) first, then the Quick Connection call, which applies QC-02's
// verdict itself. A dry run of a saved recipe calls for real: only tools QC-02
// allows (read-only or owner-named non-writes) are ever called. A draft's
// in-memory dry run (draft_automation, run id 0) calls nothing: its script is
// chat-written and unconfirmed, and even a read tool's arguments carry data to
// the server (ask #326). The result is the tool's JSON, held to the SDK
// result size boundary.
func MCPModule(b Backends) Module {
	return sdkModule{name: "mcp", fns: map[string]SDKFunc{"mcp": func(env *Env, call goja.FunctionCall, rt *goja.Runtime) (any, error) {
		req, reqErr := parseMCPCall(env, rt, call)
		name := req.server + "/" + req.tool
		if req.server == "" || req.tool == "" {
			name = "invalid" // a malformed call names no server/tool pair
		}
		return env.Call(StepKindMCP, name, req.args, func(step *Step) (any, error) {
			if reqErr != nil {
				return nil, reqErr
			}
			m, err := manifestOf(env)
			if err != nil {
				return nil, err
			}
			entry, err := m.AllowMCP(req.server, req.tool)
			if err != nil {
				return nil, err
			}
			step.SetPermission(entry)
			if env.DryRun && env.Run != nil && env.Run.ID == 0 {
				return dryRunResult(step, map[string]any{"note": mcpDraftNote}), nil
			}
			if b.MCP == nil {
				return nil, notAvailable("no Quick Connection caller is configured")
			}
			res, err := b.MCP.Call(env.Ctx, req.server, req.tool, req.args)
			if err != nil {
				return nil, mcpError(req, err)
			}
			if len(res) == 0 {
				return jsonValue(nil), nil
			}
			return res, nil
		})
	}}}
}

const mcpDraftNote = "mcp() is not called in a draft; dry-run the saved recipe from its card to see it"

// mcpCall is one mcp(server, tool, args) call's arguments.
type mcpCall struct {
	server, tool string
	args         json.RawMessage // a JSON object
}

// parseMCPCall reads mcp(server, tool, args?): two non-empty strings and an
// object (absent = {}). A bad call is reported inside the step.
func parseMCPCall(env *Env, rt *goja.Runtime, call goja.FunctionCall) (mcpCall, error) {
	req := mcpCall{args: json.RawMessage(`{}`)}
	var vals [2]string
	for i, what := range []string{"server", "tool"} {
		v, _, err := argAt(env, rt, call, i)
		if err != nil {
			return req, tooLargeAs(err, ErrNameValidation,
				fmt.Sprintf("mcp(): the %s name is larger than %d bytes", what, maxSDKArgBytes))
		}
		s, ok := v.(string)
		if !ok || s == "" {
			return req, validationf("mcp(server, tool, args): %s must be a non-empty string", what)
		}
		vals[i] = s
	}
	req.server, req.tool = vals[0], vals[1]
	args, present, err := argAt(env, rt, call, 2)
	if err != nil {
		return req, tooLargeAs(err, ErrNameValidation,
			fmt.Sprintf("mcp(%q, %q): the arguments are larger than %d bytes", req.server, req.tool, maxSDKArgBytes))
	}
	if !present || args == nil {
		return req, nil
	}
	if _, ok := args.(map[string]any); !ok {
		return req, validationf("mcp(%q, %q, args): args must be an object", req.server, req.tool)
	}
	if req.args, err = json.Marshal(args); err != nil {
		return req, validationf("mcp(%q, %q, args): %v", req.server, req.tool, err)
	}
	return req, nil
}

// mcpError maps a MCPCaller failure to the SDK error the script sees, the
// caller's cause (the refresh hint, the credential failure) kept in the
// message.
func mcpError(req mcpCall, err error) error {
	switch {
	case errors.Is(err, ErrMCPNotAvailable):
		msg := fmt.Sprintf("Quick Connection %q is not available", req.server)
		// The caller wraps the sentinel first: "<sentinel>: <cause>".
		if cause := strings.TrimPrefix(strings.TrimPrefix(err.Error(), ErrMCPNotAvailable.Error()), ": "); cause != "" {
			msg += ": " + cause
		}
		return notAvailable(msg)
	case errors.Is(err, ErrMCPToolNotAllowed):
		needed := "mcp:" + req.server + "/" + req.tool
		return &SDKError{Name: ErrNamePermissionDenied, Needed: needed,
			Message: fmt.Sprintf("%s is not allowed: Quick Connections only run read-only tools or tools the owner named (QC-02)", needed)}
	}
	var te *externalmcp.ToolError
	if errors.As(err, &te) {
		return &SDKError{Name: ErrNameTool, Message: fmt.Sprintf("%s/%s: %s", req.server, req.tool, te.Message)}
	}
	return &SDKError{Name: ErrNameTool, Message: fmt.Sprintf("%s/%s: %v", req.server, req.tool, err)}
}
