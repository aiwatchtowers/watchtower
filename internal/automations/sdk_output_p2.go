package automations

import (
	"encoding/json"
	"errors"
	"fmt"

	"github.com/dop251/goja"

	"watchtower/internal/db"
	"watchtower/internal/tools"
)

// The output kinds P2 registers (spec §5).
const (
	outputKindBriefing = "briefing"
	outputKindTarget   = "target"
	outputKindSlack    = "slack"
)

// registerP2OutputKinds adds output.briefing, output.target and output.slack
// to m, closing over b for the two registry shortcuts.
func registerP2OutputKinds(m *OutputMod, b Backends) {
	m.RegisterOutputKind(outputKindBriefing, bufferedOutput(outputKindBriefing, false))
	for tool, kind := range outputTools {
		m.RegisterOutputKind(kind, toolOutput(b, kind, tool))
	}
}

// toolOutput is output.<kind>(args) for a kind that is sugar for a registry
// write (spec §5): outputs: [<kind>] is the gate (the manifest needs no
// tool:<tool> entry; output.slack also needs slack:write over the call's
// account, D28), then the call takes tool()'s write path — dry run,
// default reason, Registry.Propose with the run's binding — so trust and an
// auto grant on <tool> apply as to a tool() write. It takes exactly one
// argument and never waits.
func toolOutput(b Backends, kind, tool string) SDKFunc {
	return func(env *Env, call goja.FunctionCall, rt *goja.Runtime) (any, error) {
		fn := "output." + kind
		arg, _, argErr := argAt(env, rt, call, 0)
		return env.Call(StepKindOutput, kind, arg, func(step *Step) (any, error) {
			m, err := manifestOf(env)
			if err != nil {
				return nil, err
			}
			entry, err := m.AllowOutput(kind)
			if err != nil {
				return nil, err
			}
			step.SetPermission(entry)
			args, err := toolOutputArgs(fn, arg, argErr, len(call.Arguments))
			if err != nil {
				return nil, err
			}
			t, err := admitOutputTool(env, b, step, m, kind, tool, args)
			if err != nil {
				return nil, err
			}
			return writeTool(env, b, step, t, args, false)
		})
	}
}

// admitOutputTool resolves tool and runs the manifest's full shortcut check
// (AllowOutputTool: for output.slack also slack:write over the call's
// account, D28), recording the admitting entries on the step. It runs before
// writeTool, so a dry run refuses what a live run would. A denial whose scope
// lookup failed keeps its Cause on the step's error, as for tool().
func admitOutputTool(env *Env, b Backends, step *Step, m *Manifest, kind, tool string, args json.RawMessage) (*tools.Tool, error) {
	if b.Registry == nil {
		return nil, notAvailable("no tool registry is configured")
	}
	t, ok := b.Registry.Get(tool)
	if !ok || !t.VisibleOn(tools.AutomationSurface) {
		return nil, notAvailable("output." + kind + "(): the " + tool + " tool is not available to automations")
	}
	entry, err := m.AllowOutputTool(env.Ctx, b.DB, kind, t, args)
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

// toolOutputArgs validates the one object argument of a registry-backed
// output and encodes it for the registry.
func toolOutputArgs(fn string, arg any, argErr error, nArgs int) (json.RawMessage, error) {
	if argErr != nil {
		return nil, tooLargeAs(argErr, ErrNameValidation,
			fmt.Sprintf("%s(): the argument is larger than %d bytes", fn, maxSDKArgBytes))
	}
	if nArgs > 1 {
		return nil, validationf("%s() takes one argument and never waits; use tool() with {wait: true} to wait", fn)
	}
	fields, ok := arg.(map[string]any)
	if !ok {
		return nil, validationf("%s() takes an object of the tool's arguments", fn)
	}
	raw, err := json.Marshal(fields)
	if err != nil {
		return nil, validationf("%s(): %v", fn, err)
	}
	return raw, nil
}
