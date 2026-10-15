package automations

import (
	"encoding/json"
	"errors"
	"fmt"

	"github.com/dop251/goja"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// ToolModule defines tool(name, args) (spec §5): the manifest check
// (AllowTool), then for a read tool Registry.CallRead with the run's
// binding and the list limit injected or clamped (ClampListLimit). A write
// tool throws NotAvailable in P1; P2's ToolWriteModule replaces the path and
// delegates reads to readTool.
func ToolModule(b Backends) Module {
	return sdkModule{name: "tool", fns: map[string]SDKFunc{"tool": func(env *Env, call goja.FunctionCall, rt *goja.Runtime) (any, error) {
		req, reqErr := parseToolCall(env, rt, call)
		return env.Call(StepKindTool, req.name, req.args, func(step *Step) (any, error) {
			if reqErr != nil {
				return nil, reqErr
			}
			t, err := admitTool(env, b, step, req)
			if err != nil {
				return nil, err
			}
			if t.Access != tools.AccessRead {
				return nil, notAvailable(t.Name + " is a write tool; writes arrive in a later phase")
			}
			return readTool(env, b, t, req.args)
		})
	}}}
}

// toolCall is one tool(name, args) call's arguments.
type toolCall struct {
	name string
	args json.RawMessage // a JSON object
}

// parseToolCall reads tool(name, args?): name a string, args an object
// (absent = {}). It runs before the step begins; a bad call is reported
// inside the step.
func parseToolCall(env *Env, rt *goja.Runtime, call goja.FunctionCall) (toolCall, error) {
	req := toolCall{args: json.RawMessage(`{}`)}
	name, _, err := argAt(env, rt, call, 0)
	if err != nil {
		return req, tooLargeAs(err, ErrNameValidation,
			fmt.Sprintf("tool(): the tool name is larger than %d bytes", maxSDKArgBytes))
	}
	var ok bool
	if req.name, ok = name.(string); !ok || req.name == "" {
		return req, validationf("tool(name, args): name must be a non-empty string")
	}
	args, present, err := argAt(env, rt, call, 1)
	if err != nil {
		return req, tooLargeAs(err, ErrNameValidation,
			fmt.Sprintf("tool(%q): the arguments are larger than %d bytes", req.name, maxSDKArgBytes))
	}
	if !present || args == nil {
		return req, nil
	}
	if _, ok := args.(map[string]any); !ok {
		return req, validationf("tool(%q, args): args must be an object", req.name)
	}
	if req.args, err = json.Marshal(args); err != nil {
		return req, validationf("tool(%q, args): %v", req.name, err)
	}
	return req, nil
}

// admitTool resolves the tool and checks the manifest; the admitting entry
// is recorded on the step. A denial whose scope lookup failed keeps its
// Cause on the step's error (the script sees only what was needed).
func admitTool(env *Env, b Backends, step *Step, req toolCall) (*tools.Tool, error) {
	if b.Registry == nil {
		return nil, notAvailable("no tool registry is configured")
	}
	t, ok := b.Registry.Get(req.name)
	if !ok {
		return nil, validationf("unknown tool %q", req.name)
	}
	m, err := manifestOf(env)
	if err != nil {
		return nil, err
	}
	entry, err := m.AllowTool(env.Ctx, b.DB, t, req.args)
	if err != nil {
		var pd *PermissionDenied
		if errors.As(err, &pd) && pd.Cause != nil {
			step.Finish(db.StepFinish{Status: StepDenied, Permission: pd.Needed, Error: pd.Error()})
		}
		return nil, err
	}
	step.SetPermission(entry)
	return t, nil
}

// readTool calls a read tool through the registry with the run's binding,
// after ClampListLimit. A registry ValidationError is a ValidationError to
// the script; every other failure is a ToolError.
func readTool(env *Env, b Backends, t *tools.Tool, args json.RawMessage) (any, error) {
	res, err := b.Registry.CallRead(env.Ctx, t.Name, ClampListLimit(t, args), env.Binding())
	if err == nil {
		return jsonValue(res), nil
	}
	var ve *tools.ValidationError
	if errors.As(err, &ve) {
		return nil, &SDKError{Name: ErrNameValidation, Message: ve.Msg}
	}
	return nil, &SDKError{Name: ErrNameTool, Message: fmt.Sprintf("%s: %v", t.Name, err)}
}
